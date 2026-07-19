import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Photos
import UIKit
import UniformTypeIdentifiers

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

    /// Histogramme RVB du rendu affiché (valeurs normalisées 0…1 par canal).
    struct HistogramData: Equatable {
        let red: [Float]
        let green: [Float]
        let blue: [Float]
    }

    /// Retardateur du déclencheur.
    enum TimerSetting: Int, CaseIterable {
        case off = 0
        case three = 3
        case five = 5
        case ten = 10

        var next: TimerSetting {
            let all = TimerSetting.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    /// Formats de cadrage photo, hérités des grands classiques argentiques.
    enum PhotoFormat: String, CaseIterable {
        case fourThree = "4:3"
        case threeTwo = "3:2"
        case oneOne = "1:1"
        case sixteenNine = "16:9"
        case xpan = "65:24"

        /// Rapport grand côté / petit côté (nil = format natif du capteur).
        var longOverShort: CGFloat? {
            switch self {
            case .fourThree: return nil
            case .threeTwo: return 3.0 / 2.0
            case .oneOne: return 1
            case .sixteenNine: return 16.0 / 9.0
            case .xpan: return 65.0 / 24.0
            }
        }

        /// Libellé du menu, avec l'héritage argentique du format.
        var title: String {
            switch self {
            case .fourThree: return "4:3 · natif"
            case .threeTwo: return "3:2 · film 135"
            case .oneOne: return "1:1 · 6×6"
            case .sixteenNine: return "16:9"
            case .xpan: return "65:24 · XPan"
            }
        }
    }

    @Published var status: Status = .idle
    @Published var lastCaptureSaved = false
    /// Passe à vrai dès que la première trame filtrée est affichée.
    @Published var hasFrame = false

    /// Photo ou vidéo (change le rôle du déclencheur).
    @Published var mode: CaptureMode = .photo {
        didSet {
            cancelCountdown()
            updateFrameRate()
            updateLetterbox()
            updateFourK()
            updateHDR()
            updatePhotoFormat()
        }
    }

    /// Retardateur : réglage choisi et compte à rebours en cours (nil sinon).
    @Published var timerSetting: TimerSetting = .off
    @Published var countdown: Int?

    /// Mode rafale : le déclencheur enchaîne `burstSize` captures pleine
    /// qualité. `burstCountRemaining` > 0 pendant une rafale.
    @Published var burstEnabled = false
    @Published var burstCountRemaining = 0
    let burstSize = 8

    /// Format de cadrage photo (recadrage centré appliqué avant les filtres).
    @Published var photoFormat: PhotoFormat = .fourThree {
        didSet { updatePhotoFormat() }
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
    /// HDR : capture 10 bits et encodage HEVC Main10 en HLG BT.2020.
    @Published var hdrEnabled = false
    /// Verrouillage exposition + mise au point.
    @Published var exposureFocusLocked = false
    /// Facteur de zoom courant (1 = grand-angle natif).
    @Published var zoomFactor: CGFloat = 1
    /// Caméra frontale active ?
    @Published var isFrontCamera = false
    /// Histogramme temps réel affiché dans le viseur.
    @Published var histogramEnabled = true
    /// Dernier histogramme calculé (sur le rendu vintage, pas la scène brute).
    @Published var histogram: HistogramData?
    /// Zébras : hachures sur les zones surexposées (viseur uniquement).
    @Published var zebrasEnabled = false
    /// Focus peaking : contours nets surlignés en vert (viseur uniquement).
    @Published var peakingEnabled = false
    /// Grille des tiers (viseur uniquement).
    @Published var gridEnabled = false

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
    /// File série des développements photo : borne la mémoire pendant
    /// une rafale (un rendu pleine résolution à la fois).
    private let renderQueue = DispatchQueue(label: "optyx.camera.render", qos: .userInitiated)
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
    /// Miroir du format photo côté `videoQueue` (nil = natif ou mode vidéo).
    private var photoFormatRatio: CGFloat?
    /// Minuteur du retardateur (fil principal).
    private var countdownTimer: Timer?
    /// Miroir de `hdrEnabled && mode == .video` côté `videoQueue`.
    private var hdrActive = false
    /// Format 10 bits du pool en cours (pour le recréer au changement).
    private var previewBufferHDR = false
    /// Position de la caméra et orientation à appliquer aux trames
    /// (miroir pour la caméra frontale, façon selfie).
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var sensorOrientation: CGImagePropertyOrientation = .right

    /// Histogramme : calculé une trame sur `histogramInterval` (lecture
    /// GPU→CPU de 64 bins seulement). Compteur confiné à `videoQueue`.
    private var histogramFrameCounter = 0
    private let histogramInterval = 3
    private let histogramBins = 64

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
        cancelCountdown()
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
            // Stéréo quand le matériel le permet (sinon reste en mono).
            try? AVAudioSession.sharedInstance().setPreferredInputNumberOfChannels(2)
            DispatchQueue.main.async { self.status = .running }
        }
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Repart de zéro (nécessaire lors d'un changement de caméra).
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        outputSynchronizer = nil

        session.sessionPreset = .photo

        // Choisit en priorité une caméra capable de fournir la profondeur.
        let deviceTypes: [AVCaptureDevice.DeviceType] = cameraPosition == .back
            ? [.builtInLiDARDepthCamera, .builtInDualWideCamera,
               .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .video, position: cameraPosition)
        guard let device = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        videoDevice = device
        sensorOrientation = cameraPosition == .front ? .leftMirrored : .right

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

        // Le capteur livre des images en paysage : rotation portrait
        // (avec miroir pour la caméra frontale).
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(sensorOrientation)

        let largest = max(image.extent.width, image.extent.height)
        if largest > processingMaxDimension {
            let scale = processingMaxDimension / largest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        // Format photo : recadrage centré AVANT les filtres, pour que le
        // vignettage et les masques radiaux épousent le cadre choisi.
        // Le masque de profondeur subit le même recadrage pour rester aligné.
        var depthMask = depthMask
        if let ratio = photoFormatRatio {
            image = Self.centerCrop(image, longOverShort: ratio)
            depthMask = depthMask.map { Self.centerCrop($0, longOverShort: ratio) }
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
        let colorSpace = hdrActive
            ? (CGColorSpace(name: CGColorSpace.itur_2100_HLG) ?? CGColorSpaceCreateDeviceRGB())
            : CGColorSpaceCreateDeviceRGB()
        LensEngine.shared.context.render(processed, to: buffer,
                                         bounds: processed.extent,
                                         colorSpace: colorSpace)
        // Les aides visuelles (zébras, peaking) ne touchent que l'affichage :
        // le buffer enregistré et les photos restent vierges.
        previewRenderer.present(assistOverlays(on: CIImage(cvPixelBuffer: buffer)))

        // Le même buffer déjà rendu alimente l'enregistrement vidéo :
        // aucun rendu supplémentaire.
        if recordingActive {
            if recorder == nil {
                recorder = VideoRecorder(
                    size: CGSize(width: CVPixelBufferGetWidth(buffer),
                                 height: CVPixelBufferGetHeight(buffer)),
                    frameRate: cineMode ? 24 : 30,
                    hdr: hdrActive)
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recorder?.appendVideo(buffer, at: time)
        }

        if !didPublishFirstFrame {
            didPublishFirstFrame = true
            DispatchQueue.main.async { [weak self] in self?.hasFrame = true }
        }

        // Histogramme du rendu affiché (buffer déjà rendu : aucun filtre
        // re-exécuté), à cadence réduite.
        if histogramEnabled {
            histogramFrameCounter += 1
            if histogramFrameCounter % histogramInterval == 0 {
                computeHistogram(from: CIImage(cvPixelBuffer: buffer))
            }
        }
    }

    /// Aides visuelles du viseur, appliquées par-dessus le rendu déjà écrit :
    /// zébras (hachures blanches sur les hautes lumières ≥ 95 %), focus
    /// peaking (contours nets surlignés en vert) et grille des tiers.
    /// Filtres légers exécutés au blit Metal uniquement — jamais dans les
    /// fichiers capturés.
    private func assistOverlays(on image: CIImage) -> CIImage {
        guard zebrasEnabled || peakingEnabled || gridEnabled else { return image }
        let extent = image.extent
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        var out = image

        if zebrasEnabled {
            let mono = image.applyingFilter("CIColorControls",
                                            parameters: [kCIInputSaturationKey: 0])
            let highlights = mono.applyingFilter("CIColorThreshold",
                                                 parameters: ["inputThreshold": 0.95])
            let stripesGen = CIFilter.stripesGenerator()
            stripesGen.center = .zero
            stripesGen.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)
            stripesGen.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            stripesGen.width = 4
            stripesGen.sharpness = 1
            if let stripes = stripesGen.outputImage?
                .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
                .cropped(to: extent) {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = stripes
                blend.backgroundImage = clear
                blend.maskImage = highlights
                if let zebra = blend.outputImage {
                    out = zebra.composited(over: out)
                }
            }
        }

        if peakingEnabled {
            let edges = image.applyingFilter("CIEdges",
                                             parameters: [kCIInputIntensityKey: 4])
            let edgeMask = edges
                .applyingFilter("CIColorControls",
                                parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorThreshold",
                                parameters: ["inputThreshold": 0.3])
            let green = CIImage(color: CIColor(red: 0.25, green: 1, blue: 0.3, alpha: 0.85))
                .cropped(to: extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = green
            blend.backgroundImage = clear
            blend.maskImage = edgeMask
            if let peaking = blend.outputImage {
                out = peaking.composited(over: out)
            }
        }

        if gridEnabled {
            // Grille des tiers : lignes fines alignées sur l'image rendue
            // (letterbox compris), en surimpression discrète.
            let lineColor = CIColor(red: 1, green: 1, blue: 1, alpha: 0.4)
            let thickness = max(1, min(extent.width, extent.height) * 0.0015)
            for third in 1...2 {
                let x = extent.minX + extent.width * CGFloat(third) / 3 - thickness / 2
                let vertical = CGRect(x: x, y: extent.minY,
                                      width: thickness, height: extent.height)
                out = CIImage(color: lineColor).cropped(to: vertical).composited(over: out)

                let y = extent.minY + extent.height * CGFloat(third) / 3 - thickness / 2
                let horizontal = CGRect(x: extent.minX, y: y,
                                        width: extent.width, height: thickness)
                out = CIImage(color: lineColor).cropped(to: horizontal).composited(over: out)
            }
        }

        return out
    }

    /// Histogramme RVB via CIAreaHistogram (64 bins), normalisé par canal
    /// pour l'affichage.
    private func computeHistogram(from image: CIImage) {
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = image.extent
        filter.count = histogramBins
        filter.scale = 1
        guard let output = filter.outputImage else { return }

        var values = [Float](repeating: 0, count: histogramBins * 4)
        LensEngine.shared.context.render(output,
                                         toBitmap: &values,
                                         rowBytes: histogramBins * 16,
                                         bounds: CGRect(x: 0, y: 0,
                                                        width: histogramBins, height: 1),
                                         format: .RGBAf,
                                         colorSpace: nil)

        var red = [Float](repeating: 0, count: histogramBins)
        var green = red
        var blue = red
        for bin in 0..<histogramBins {
            red[bin] = values[bin * 4]
            green[bin] = values[bin * 4 + 1]
            blue[bin] = values[bin * 4 + 2]
        }
        let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
        guard peak > 0 else { return }
        let data = HistogramData(red: red.map { $0 / peak },
                                 green: green.map { $0 / peak },
                                 blue: blue.map { $0 / peak })

        DispatchQueue.main.async { [weak self] in
            self?.histogram = data
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
        if previewBufferPool == nil || previewBufferSize != size
            || previewBufferHDR != hdrActive {
            // 10 bits en HDR, BGRA 8 bits sinon.
            let pixelFormat = hdrActive
                ? kCVPixelFormatType_ARGB2101010LEPacked
                : kCVPixelFormatType_32BGRA
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            previewBufferHDR = hdrActive
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
    private static func backgroundMask(from depthData: AVDepthData,
                                       orientation: CGImagePropertyOrientation) -> CIImage? {
        let disparity = depthData.converting(
            toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = CIImage(cvPixelBuffer: disparity.depthDataMap).oriented(orientation)
        return DepthExtractor.normalizedFarMask(map, farIsSmall: true)
    }

    /// Version pour le flux direct : réutilise la plage min/max mise en
    /// cache et ne la rafraîchit que périodiquement. Appelée sur `videoQueue`.
    private func liveBackgroundMask(from depthData: AVDepthData) -> CIImage? {
        let disparity = depthData.converting(
            toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = CIImage(cvPixelBuffer: disparity.depthDataMap).oriented(sensorOrientation)

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

    // MARK: - Déclencheur et retardateur

    /// Action du déclencheur : immédiate, ou différée par le retardateur.
    /// Pendant un compte à rebours, un nouvel appui l'annule ; pendant un
    /// enregistrement vidéo, l'appui arrête immédiatement (jamais différé).
    func triggerShutter() {
        if countdown != nil {
            cancelCountdown()
            return
        }
        if burstCountRemaining > 0 {
            // Un appui pendant une rafale l'interrompt.
            burstCountRemaining = 0
            return
        }
        if mode == .video && isRecording {
            toggleRecording()
            return
        }
        guard timerSetting != .off else {
            performShutter()
            return
        }
        countdown = timerSetting.rawValue
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1,
                                              repeats: true) { [weak self] _ in
            guard let self, let remaining = self.countdown else { return }
            if remaining <= 1 {
                self.cancelCountdown()
                self.performShutter()
            } else {
                self.countdown = remaining - 1
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    private func performShutter() {
        if mode == .photo {
            if burstEnabled {
                burstCountRemaining = burstSize
            }
            capturePhoto()
        } else {
            toggleRecording()
        }
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
        // Le RAW est ignoré pendant une rafale pour tenir la cadence.
        if rawEnabled, burstCountRemaining == 0, !rawTypes.isEmpty {
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

    private func updatePhotoFormat() {
        let ratio = mode == .photo ? photoFormat.longOverShort : nil
        videoQueue.async { [weak self] in
            self?.photoFormatRatio = ratio
        }
    }

    /// Recadrage centré au rapport grand côté / petit côté donné,
    /// valable en portrait comme en paysage.
    private static func centerCrop(_ image: CIImage, longOverShort ratio: CGFloat) -> CIImage {
        let extent = image.extent
        guard ratio >= 1, !extent.isEmpty else { return image }
        let width: CGFloat
        let height: CGFloat
        if extent.height >= extent.width {
            width = min(extent.width, extent.height / ratio)
            height = min(extent.height, extent.width * ratio)
        } else {
            width = min(extent.width, extent.height * ratio)
            height = min(extent.height, extent.width / ratio)
        }
        return image.cropped(to: CGRect(x: extent.midX - width / 2,
                                        y: extent.midY - height / 2,
                                        width: width,
                                        height: height))
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

    /// Bascule le HDR (HLG 10 bits) — verrouillé pendant un enregistrement.
    func toggleHDR() {
        guard !isRecording else { return }
        hdrEnabled.toggle()
        updateHDR()
    }

    /// En HDR : trames capteur 10 bits (si disponibles), HDR vidéo du
    /// capteur activé, pool et encodage 10 bits. Sinon, retour au BGRA 8 bits.
    private func updateHDR() {
        let active = hdrEnabled && mode == .video
        videoQueue.async { [weak self] in
            self?.hdrActive = active
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            let tenBit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            let format: OSType = (active && self.videoOutput
                .availableVideoPixelFormatTypes.contains(tenBit))
                ? tenBit : kCVPixelFormatType_32BGRA
            self.videoOutput.videoSettings =
                [kCVPixelBufferPixelFormatTypeKey as String: format]
            self.session.commitConfiguration()

            if let device = self.videoDevice,
               device.activeFormat.isVideoHDRSupported,
               (try? device.lockForConfiguration()) != nil {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = active
                device.unlockForConfiguration()
            }
        }
    }

    // MARK: - Exposition, mise au point, zoom, caméra

    /// Verrouille (ou libère) l'exposition et la mise au point.
    func toggleExposureFocusLock() {
        exposureFocusLocked.toggle()
        let locked = exposureFocusLocked
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice,
                  (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if locked {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    /// Zoom optique/numérique continu (pincement dans le viseur).
    func setZoom(_ factor: CGFloat) {
        let clamped = max(1, min(factor, 8))
        zoomFactor = clamped
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice,
                  (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = min(clamped, device.activeFormat.videoMaxZoomFactor)
        }
    }

    /// Bascule caméra arrière ↔ frontale (TrueDepth : la profondeur
    /// reste disponible). Reconstruit la session et réapplique les réglages.
    func switchCamera() {
        guard !isRecording else { return }
        cameraPosition = cameraPosition == .back ? .front : .back
        isFrontCamera = cameraPosition == .front
        exposureFocusLocked = false
        zoomFactor = 1
        videoQueue.async { [weak self] in
            self?.cachedDepthRange = nil
            self?.depthFrameCounter = 0
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            guard self.configureSession() else {
                DispatchQueue.main.async { self.status = .unavailable }
                return
            }
            if wasRunning { self.session.startRunning() }
        }
        // Réapplique les réglages qui vivent sur l'appareil ou la connexion.
        updateFrameRate()
        updateFourK()
        updateHDR()
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

        // Rafale : enchaîne la capture suivante dès que celle-ci est bouclée
        // (le développement se poursuit en parallèle sur la file de rendu).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.burstCountRemaining > 0 else { return }
            self.burstCountRemaining -= 1
            if self.burstCountRemaining > 0 {
                self.capturePhoto()
            }
        }

        guard error == nil, rawData != nil || processedData != nil else { return }

        let lens = self.lens
        let intensity = self.intensity
        let orientation = self.sensorOrientation
        let formatRatio = mode == .photo ? photoFormat.longOverShort : nil
        let exportFormat = ExportFormat.current

        renderQueue.async { [weak self] in
            // Le rendu vintage est "développé" à partir de la version traitée ;
            // le DNG reste, par définition, les données brutes du capteur.
            var vintageData: Data?
            if let processedData, let source = UIImage(data: processedData) {
                var mask = depthData.flatMap {
                    Self.backgroundMask(from: $0, orientation: orientation)
                }
                let normalized = source.normalized(maxDimension: 3200)
                var ciImage = CIImage(image: normalized)
                if let ratio = formatRatio {
                    ciImage = ciImage.map { Self.centerCrop($0, longOverShort: ratio) }
                    mask = mask.map { Self.centerCrop($0, longOverShort: ratio) }
                }
                if let ciImage,
                   let rendered = LensEngine.shared.renderUIImage(ciImage,
                                                                  lens: lens,
                                                                  intensity: intensity,
                                                                  backgroundMask: mask) {
                    // Format d'export choisi, avec l'EXIF de la capture, la
                    // carte de profondeur embarquée (HEIC/JPEG) et la
                    // distance au sujet mesurée.
                    vintageData = PhotoMetadata.vintageImageData(
                        rendered: rendered,
                        originalData: processedData,
                        depthData: depthData,
                        lens: lens,
                        intensity: intensity,
                        format: exportFormat)
                        ?? rendered.jpegData(compressionQuality: 0.92)
                }
            }
            self?.save(vintage: vintageData, raw: rawData, format: exportFormat)
        }
    }

    /// Enregistre dans Photos : le rendu vintage comme image principale,
    /// le DNG original attaché en ressource alternative (badge RAW dans Photos).
    private func save(vintage: Data?, raw: Data?, format: ExportFormat) {
        guard vintage != nil || raw != nil else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authStatus in
            guard authStatus == .authorized || authStatus == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = "Optyx.dng"
                let vintageOptions = PHAssetResourceCreationOptions()
                vintageOptions.uniformTypeIdentifier = format.utType.identifier
                if let vintage {
                    request.addResource(with: .photo, data: vintage, options: vintageOptions)
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
