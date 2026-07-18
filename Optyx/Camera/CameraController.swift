import AVFoundation
import CoreImage
import Photos
import UIKit

/// Gère la session de capture : flux vidéo filtré en temps réel
/// par le moteur de rendu, et prise de photo plein format —
/// avec capture Apple ProRAW / RAW (DNG) quand l'appareil le permet.
final class CameraController: NSObject, ObservableObject {

    enum Status {
        case idle
        case running
        case denied
        case unavailable
    }

    @Published var previewFrame: UIImage?
    @Published var status: Status = .idle
    @Published var lastCaptureSaved = false

    /// La capture RAW est-elle disponible sur cet appareil ?
    @Published var rawSupported = false
    /// Le format disponible est-il Apple ProRAW (sinon RAW Bayer classique) ?
    @Published var isProRAW = false
    /// Capture RAW activée par l'utilisateur.
    @Published var rawEnabled = false

    /// Profil et intensité appliqués au flux (modifiables depuis l'UI).
    var lens: LensProfile = .catalog[1]
    var intensity: Double = 1.0

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "optyx.camera.session")
    private let videoQueue = DispatchQueue(label: "optyx.camera.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private var isProcessingFrame = false

    /// Données accumulées pendant une capture (le RAW et le développé
    /// arrivent dans deux callbacks séparés).
    private var pendingRawData: Data?
    private var pendingProcessedData: Data?

    /// Plus grand côté des images de prévisualisation (compromis fluidité/qualité).
    private let previewMaxDimension: CGFloat = 900

    // MARK: - Cycle de vie

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configureAndRun() : (self?.status = .denied)
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        DispatchQueue.main.async { self.status = .idle }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                guard self.configureSession() else {
                    DispatchQueue.main.async { self.status = .unavailable }
                    return
                }
                self.isConfigured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.status = .running }
        }
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)

        videoOutput.videoSettings =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { return false }
        session.addOutput(videoOutput)

        guard session.canAddOutput(photoOutput) else { return false }
        session.addOutput(photoOutput)

        // Active Apple ProRAW quand le matériel le propose (iPhone 12 Pro+),
        // sinon on retombe sur le RAW Bayer si disponible.
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let hasProRAW = rawTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        DispatchQueue.main.async {
            self.rawSupported = !rawTypes.isEmpty
            self.isProRAW = hasProRAW
        }

        return true
    }

    // MARK: - Capture photo

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.pendingRawData = nil
            self.pendingProcessedData = nil
            self.photoOutput.capturePhoto(with: self.makePhotoSettings(), delegate: self)
        }
    }

    /// RAW activé : capture DNG (ProRAW de préférence) + version développée
    /// qui sert de base au rendu vintage. Sinon, capture classique.
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        guard rawEnabled, !rawTypes.isEmpty else { return AVCapturePhotoSettings() }

        let rawFormat = rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
            ?? rawTypes[0]
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            return AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        return AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
    }
}

// MARK: - Flux vidéo

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isProcessingFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        // Le capteur livre des images en paysage : rotation portrait.
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)

        let largest = max(image.extent.width, image.extent.height)
        if largest > previewMaxDimension {
            let scale = previewMaxDimension / largest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let processed = LensEngine.shared.render(image, lens: lens, intensity: intensity)
        guard let cgImage = LensEngine.shared.context
            .createCGImage(processed, from: processed.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)

        DispatchQueue.main.async { [weak self] in
            self?.previewFrame = uiImage
        }
    }
}

// MARK: - Photo plein format

extension CameraController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            pendingRawData = data
        } else {
            pendingProcessedData = data
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let rawData = pendingRawData
        let processedData = pendingProcessedData
        pendingRawData = nil
        pendingProcessedData = nil
        guard error == nil, rawData != nil || processedData != nil else { return }

        let lens = self.lens
        let intensity = self.intensity

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Le rendu vintage est "développé" à partir de la version traitée ;
            // le DNG reste, par définition, les données brutes du capteur.
            var vintageData: Data?
            if let processedData, let source = UIImage(data: processedData) {
                let normalized = source.normalized(maxDimension: 3200)
                if let ciImage = CIImage(image: normalized),
                   let rendered = LensEngine.shared.renderUIImage(ciImage,
                                                                  lens: lens,
                                                                  intensity: intensity) {
                    vintageData = rendered.jpegData(compressionQuality: 0.92)
                }
            }
            self?.save(vintage: vintageData, raw: rawData)
        }
    }

    /// Enregistre dans Photos : le rendu vintage comme image principale,
    /// le DNG original attaché en ressource alternative (badge RAW dans Photos).
    private func save(vintage: Data?, raw: Data?) {
        guard vintage != nil || raw != nil else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authStatus in
            guard authStatus == .authorized || authStatus == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = "Optyx.dng"
                if let vintage {
                    request.addResource(with: .photo, data: vintage, options: nil)
                    if let raw {
                        request.addResource(with: .alternatePhoto, data: raw, options: rawOptions)
                    }
                } else if let raw {
                    request.addResource(with: .photo, data: raw, options: rawOptions)
                }
            } completionHandler: { success, _ in
                guard success else { return }
                DispatchQueue.main.async {
                    self?.lastCaptureSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        self?.lastCaptureSaved = false
                    }
                }
            }
        }
    }
}
