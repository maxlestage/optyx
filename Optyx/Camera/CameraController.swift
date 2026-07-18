import AVFoundation
import CoreImage
import UIKit

/// Gère la session de capture : flux vidéo filtré en temps réel
/// par le moteur de rendu, et prise de photo plein format.
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

        return true
    }

    // MARK: - Capture photo

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
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
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let raw = UIImage(data: data) else { return }

        let lens = self.lens
        let intensity = self.intensity

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let normalized = raw.normalized(maxDimension: 3200)
            guard let ciImage = CIImage(image: normalized),
                  let result = LensEngine.shared.renderUIImage(ciImage,
                                                               lens: lens,
                                                               intensity: intensity)
            else { return }
            UIImageWriteToSavedPhotosAlbum(result, nil, nil, nil)
            DispatchQueue.main.async {
                self?.lastCaptureSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    self?.lastCaptureSaved = false
                }
            }
        }
    }
}
