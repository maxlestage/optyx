import AVFoundation
import CoreImage
import Photos
import UIKit

/// Gère la session de capture : flux vidéo filtré en temps réel
/// par le moteur de rendu, profondeur en direct (LiDAR / double capteur),
/// prise de photo plein format avec Apple ProRAW / RAW (DNG), et
/// enregistrement vidéo avec la simulation appliquée.
final class CameraController: NSObject, ObservableObject {

    enum Status {
        case idle
        case running
        case denied
        case unavailable
    }

    enum CaptureMode {
        case photo
        case video
    }

    @Published var status: Status = .idle
    @Published var lastCaptureSaved = false
    /// Passe à vrai dès que la première trame filtrée est affichée.
    @Published var hasFrame = false

    /// Photo ou vidéo (change le rôle du déclencheur).
    @Published var mode: CaptureMode = .photo {
        didSet {
            updateFrameRate()
            updateLetterbox()
            updateFourK()
        }
    }
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    /// Mode cinéma : capteur calé à 24 i/s en vidéo, pour le rendu de
    /// mouvement des zooms Angénieux et consorts.
    @Published var cineMode = false
    /// Letterbox CinemaScope : le flux vidéo est recadré au format 2.39:1.
    @Published var letterboxEnabled = false
    /// Mode 4K : enregistrement à 3840 px de plus grand côté avec
    /// stabilisation cinématique. Fonctionne avec tous les profils.
    @Published var fourKEnabled = false

    /// Affichage Metal du viseur : reçoit les trames déjà rendues.
    let previewRenderer = PreviewRenderer()

    /// La capture RAW est-elle disponible sur cet appareil ?
    @Published var rawSupported = false
    /// Le format disponible est-il Apple ProRAW (sinon RAW Bayer classique) ?
    @Published var isProRAW = false
    /// Capture RAW activée par l'utilisateur.
    @Published var rawEnabled = false

    /// La caméra fournit-elle une carte de profondeur en direct ?
    @Published var depthAvailable = false
    /// Bokeh guidé par la profondeur activé par l'utilisateur.
    @Published var depthEnabled = true

    /// Profil et intensité appliqués au flux (modifiables depuis l'UI).
    var lens: LensProfile = .catalog[1]
    var intensity: Double = 1.0

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "optyx.camera.session")
    private let videoQueue = DispatchQueue(label: "optyx.camera.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    /// Synchronise vidéo + profondeur quand la caméra fournit les deux.
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    /// Caméra active, conservée pour piloter la cadence (mode cinéma).
    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false
    private var isProcessingFrame = false

    /// Données accumulées pendant une capture (le RAW et le développé
    /// arrivent dans des callbacks séparés).
    private var pendingRawData: Data?
    private var pendingProcessedData: Data?
    private var pendingDepthData: AVDepthData?

    /// Plus grand côté du flux traité : 900 px pour la prévisualisation,
    /// 1440 px pendant un enregistrement vidéo, 3840 px en mode 4K.
    private var processingMaxDimension: CGFloat {
        guard recordingActive else { return 900 }
        return fourKActive ? 3840 : 1440
    }

    /// Enregistrement vidéo. `recordingActive` est le miroir de `isRecording`
    /// côté `videoQueue` ; le recorder est créé à la première trame.
    private var recorder: VideoRecorder?
    private var recordingActive = false
    private var recordingTimer: Timer?
    /// Miroir de `letterboxEnabled && mode == .video` côté `videoQueue`.
    private var letterboxActive = false
    /// Rapport largeur/hauteur du recadrage CinemaScope.
    private let letterboxRatio: CGFloat = 2.39
    /// Miroir de `fourKEnabled && mode == .video` côté `videoQueue`.
    private var fourKActive = false

    /// Cache de la plage de profondeur du flux direct : la mesure min/max
    /// (aller-retour GPU→CPU) n'est refaite qu'une image sur
    /// `depthRangeRefreshInterval`, la plage d'une scène évoluant lentement.
    /// Accédé uniquement depuis `videoQueue`.
    private var cachedDepthRange: DepthExtractor.DepthRange?
    private var depthFrameCounter = 0
    private let depthRangeRefreshInterval = 5

    /// Pool de pixel buffers dans lesquels la chaîne de filtres est rendue
    /// une seule fois par trame ; le renderer Metal ne fait que les afficher.
    /// Accédé uniquement depuis `videoQueue`.
    private var previewBufferPool: CVPixelBufferPool?
    private var previewBufferSize = CGSize.zero
    private var didPublishFirstFrame = false

    // MARK: - Cycle de vie

    func start() {
        videoQueue.async { [weak self] in
            self?.cachedDepthRange = nil
            self?.depthFrameCounter = 0
        }
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
        if isRecording { stopRecording() }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        videoQueue.async { [weak self] in self?.didPublishFirstFrame = false }
        DispatchQueue.main.async {
            self.status = .idle
            self.hasFrame = false
        }
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

        // Choisit en priorité une caméra capable de fournir la profondeur.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInLiDARDepthCamera, .builtInDualWideCamera,
                          .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        guard let device = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        videoDevice = device

        videoOutput.videoSettings =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { return false }
        session.addOutput(videoOutput)

        guard session.canAddOutput(photoOutput) else { return false }
        session.addOutput(photoOutput)

        // Micro pour le mode vidéo ; l'app fonctionne sans si l'accès
        // est refusé (vidéo muette).
        if let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        }

        // Profondeur en direct : sortie dédiée synchronisée avec la vidéo.
        var depthConfigured = false
        if !device.activeFormat.supportedDepthDataFormats.isEmpty,
           session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true
            depthOutput.connection(with: .depthData)?.isEnabled = true

            // Format float16 le plus fin proposé par la caméra.
            let preferred = device.activeFormat.supportedDepthDataFormats.last {
                let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return subtype == kCVPixelFormatType_DisparityFloat16
                    || subtype == kCVPixelFormatType_DepthFloat16
            }
            if let preferred, (try? device.lockForConfiguration()) != nil {
                device.activeDepthDataFormat = preferred
                device.unlockForConfiguration()
            }

            let synchronizer = AVCaptureDataOutputSynchronizer(
                dataOutputs: [videoOutput, depthOutput])
            synchronizer.setDelegate(self, queue: videoQueue)
            outputSynchronizer = synchronizer
            depthConfigured = true
        } else {
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        }

        // Active Apple ProRAW quand le matériel le propose (iPhone 12 Pro+),
        // sinon on retombe sur le RAW Bayer si disponible.
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
        }
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let hasProRAW = rawTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        let hasDepth = depthConfigured
        DispatchQueue.main.async {
            self.rawSupported = !rawTypes.isEmpty
            self.isProRAW = hasProRAW
            self.depthAvailable = hasDepth
        }

        return true
    }

    // MARK: - Traitement d'une image du flux

    private func processVideoFrame(_ sampleBuffer: CMSampleBuffer, depthMask: CIImage?) {
        guard !isProcessingFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        // Le capteur livre des images en paysage : rotation portrait.
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)

        let largest = max(image.extent.width, image.extent.height)
        if largest > processingMaxDimension {
            let scale = processingMaxDimension / largest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        var processed = LensEngine.shared.render(image, lens: lens, intensity: intensity,
                                                 backgroundMask: depthMask)

        // Letterbox CinemaScope : recadrage centré à 2.39:1, gravé dans le
        // fichier ; le viseur montre naturellement les bandes noires.
        if letterboxActive {
            let extent = processed.extent
            let targetHeight = extent.width / letterboxRatio
            if targetHeight < extent.height {
                processed = processed.cropped(to: CGRect(
                    x: extent.minX,
                    y: extent.midY - targetHeight / 2,
                    width: extent.width,
                    height: targetHeight))
            }
        }

        // Exécute la chaîne de filtres une seule fois, dans un pixel buffer ;
        // l'affichage Metal ne fera que recopier cette texture.
        guard let buffer = makePreviewBuffer(for: processed.extent) else { return }
        LensEngine.shared.context.render(processed, to: buffer,
                                         bounds: processed.extent,
                                         colorSpace: CGColorSpaceCreateDeviceRGB())
        previewRenderer.present(CIImage(cvPixelBuffer: buffer))

        // Le même buffer déjà rendu alimente l'enregistrement vidéo :
        // aucun rendu supplémentaire.
        if recordingActive {
            if recorder == nil {
                recorder = VideoRecorder(size: CGSize(
                    width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer)))
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recorder?.appendVideo(buffer, at: time)
        }

        if !didPublishFirstFrame {
            didPublishFirstFrame = true
            DispatchQueue.main.async { [weak self] in self?.hasFrame = true }
        }
    }

    /// Fournit un pixel buffer compatible Metal à la taille de l'aperçu,
    /// en recréant le pool si la taille change.
    private func makePreviewBuffer(for extent: CGRect) -> CVPixelBuffer? {
        // Dimensions paires : requis par l'encodeur HEVC du mode vidéo.
        let width = Int(extent.width.rounded()) & ~1
        let height = Int(extent.height.rounded()) & ~1
        guard width > 0, height > 0 else { return nil }

        let size = CGSize(width: width, height: height)
        if previewBufferPool == nil || previewBufferSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary,
                                    attributes as CFDictionary, &pool)
            previewBufferPool = pool
            previewBufferSize = size
        }

        guard let pool = previewBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreateBuffer(nil, pool, &buffer)
        return buffer
    }

    /// Convertit une carte de profondeur AVFoundation en masque
    /// d'arrière-plan (blanc = loin) orienté comme la prévisualisation.
    /// Version complète (mesure de plage incluse), pour la capture photo.
    private static func backgroundMask(from depthData: AVDepthData) -> CIImage? {
        let disparity = depthData.converting(
            toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = CIImage(cvPixelBuffer: disparity.depthDataMap).oriented(.right)
        return DepthExtractor.normalizedFarMask(map, farIsSmall: true)
    }

    /// Version pour le flux direct : réutilise la plage min/max mise en
    /// cache et ne la rafraîchit que périodiquement. Appelée sur `videoQueue`.
    private func liveBackgroundMask(from depthData: AVDepthData) -> CIImage? {
        let disparity = depthData.converting(
            toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = CIImage(cvPixelBuffer: disparity.depthDataMap).oriented(.right)

        depthFrameCounter += 1
        if cachedDepthRange == nil
            || depthFrameCounter % depthRangeRefreshInterval == 1 {
            if let fresh = DepthExtractor.range(of: map) {
                cachedDepthRange = fresh
            }
        }
        guard let range = cachedDepthRange else { return nil }
        return DepthExtractor.farMask(map, range: range, farIsSmall: true)
    }

    // MARK: - Capture photo

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.pendingRawData = nil
            self.pendingProcessedData = nil
            self.pendingDepthData = nil
            self.photoOutput.capturePhoto(with: self.makePhotoSettings(), delegate: self)
        }
    }

    /// RAW activé : capture DNG (ProRAW de préférence) + version développée
    /// qui sert de base au rendu vintage. Sinon, capture classique avec
    /// profondeur jointe quand la caméra la fournit.
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        if rawEnabled, !rawTypes.isEmpty {
            let rawFormat = rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
                ?? rawTypes[0]
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                return AVCapturePhotoSettings(
                    rawPixelFormatType: rawFormat,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
            return AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        }

        let settings = AVCapturePhotoSettings()
        settings.isDepthDataDeliveryEnabled =
            photoOutput.isDepthDataDeliveryEnabled && depthEnabled
        return settings
    }

    // MARK: - Enregistrement vidéo

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    /// Bascule le mode cinéma 24 i/s (verrouillé pendant un enregistrement).
    func toggleCineMode() {
        guard !isRecording else { return }
        cineMode.toggle()
        updateFrameRate()
    }

    /// Bascule le letterbox 2.39:1 (verrouillé pendant un enregistrement :
    /// changer les dimensions en cours de fichier casserait l'encodeur).
    func toggleLetterbox() {
        guard !isRecording else { return }
        letterboxEnabled.toggle()
        updateLetterbox()
    }

    private func updateLetterbox() {
        let active = letterboxEnabled && mode == .video
        videoQueue.async { [weak self] in
            self?.letterboxActive = active
        }
    }

    /// Bascule le mode 4K + stabilisation cinématique (verrouillé pendant
    /// un enregistrement : les dimensions ne peuvent pas changer en cours
    /// de fichier).
    func toggleFourK() {
        guard !isRecording else { return }
        fourKEnabled.toggle()
        updateFourK()
    }

    private func updateFourK() {
        let active = fourKEnabled && mode == .video
        videoQueue.async { [weak self] in
            self?.fourKActive = active
        }
        // La stabilisation cinématique s'applique à la connexion vidéo :
        // elle lisse aussi la prévisualisation, pour tous les profils.
        sessionQueue.async { [weak self] in
            guard let self,
                  let connection = self.videoOutput.connection(with: .video),
                  connection.isVideoStabilizationSupported else { return }
            connection.preferredVideoStabilizationMode = active ? .cinematic : .off
        }
    }

    /// Cale le capteur sur 24 i/s quand le mode cinéma est actif en vidéo ;
    /// sinon, rend la main à la cadence automatique de l'appareil.
    private func updateFrameRate() {
        let use24 = cineMode && mode == .video
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice,
                  (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }

            let supports24 = device.activeFormat.videoSupportedFrameRateRanges
                .contains { $0.minFrameRate <= 24 && 24 <= $0.maxFrameRate }
            if use24 && supports24 {
                let frameDuration = CMTime(value: 1, timescale: 24)
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            } else {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            }
        }
    }

    private func startRecording() {
        guard status == .running, !isRecording else { return }
        videoQueue.async { [weak self] in
            self?.recordingActive = true
        }
        isRecording = true
        recordingSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingSeconds += 1
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.recordingActive = false
            let recorder = self.recorder
            self.recorder = nil
            recorder?.finish { [weak self] url in
                guard let url else { return }
                self?.saveVideo(at: url)
            }
        }
    }

    /// Enregistre la vidéo filtrée dans Photos puis supprime le temporaire.
    private func saveVideo(at url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authStatus in
            guard authStatus == .authorized || authStatus == .limited else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                try? FileManager.default.removeItem(at: url)
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

// MARK: - Flux synchronisé vidéo + profondeur

extension CameraController: AVCaptureDataOutputSynchronizerDelegate {

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let syncedVideo = synchronizedDataCollection
            .synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped else { return }

        var depthMask: CIImage?
        if depthEnabled,
           let syncedDepth = synchronizedDataCollection
               .synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepth.depthDataWasDropped {
            depthMask = liveBackgroundMask(from: syncedDepth.depthData)
        }

        processVideoFrame(syncedVideo.sampleBuffer, depthMask: depthMask)
    }
}

// MARK: - Flux vidéo seul (caméra sans profondeur) et micro

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        processVideoFrame(sampleBuffer, depthMask: nil)
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
            pendingDepthData = photo.depthData
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let rawData = pendingRawData
        let processedData = pendingProcessedData
        let depthData = pendingDepthData
        pendingRawData = nil
        pendingProcessedData = nil
        pendingDepthData = nil
        guard error == nil, rawData != nil || processedData != nil else { return }

        let lens = self.lens
        let intensity = self.intensity

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Le rendu vintage est "développé" à partir de la version traitée ;
            // le DNG reste, par définition, les données brutes du capteur.
            var vintageData: Data?
            if let processedData, let source = UIImage(data: processedData) {
                let mask = depthData.flatMap { Self.backgroundMask(from: $0) }
                let normalized = source.normalized(maxDimension: 3200)
                if let ciImage = CIImage(image: normalized),
                   let rendered = LensEngine.shared.renderUIImage(ciImage,
                                                                  lens: lens,
                                                                  intensity: intensity,
                                                                  backgroundMask: mask) {
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
