import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

/// Écrit la vidéo filtrée en HEVC (.mov) : reçoit les pixel buffers déjà
/// rendus par le moteur — aucun rendu supplémentaire — et la piste micro
/// compressée en AAC stéréo. En HDR, l'encodage passe en 10 bits
/// (HEVC Main10, HLG BT.2020). Toutes les méthodes sont appelées depuis
/// la file vidéo de la caméra.
final class VideoRecorder {

    let outputURL: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false

    /// - Parameters:
    ///   - size: dimensions des trames (déjà paires).
    ///   - frameRate: cadence attendue (24 en mode cinéma, 30 sinon).
    ///   - hdr: encodage 10 bits HLG BT.2020.
    init?(size: CGSize, frameRate: Int, hdr: Bool) {
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Optyx-\(UUID().uuidString).mov")
        guard size.width > 0, size.height > 0,
              let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov)
        else { return nil }
        self.writer = writer

        // Débit explicite : ~0,15 bit/pixel/s en SDR, majoré de 25 % en HDR.
        let pixelsPerSecond = Double(size.width * size.height) * Double(frameRate)
        let bitrate = Int(pixelsPerSecond * (hdr ? 0.19 : 0.15))

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            ],
        ]
        if hdr {
            videoSettings[AVVideoProfileLevelKey] =
                kVTProfileLevel_HEVC_Main10_AutoLevel as String
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let bufferFormat = hdr
            ? kCVPixelFormatType_ARGB2101010LEPacked
            : kCVPixelFormatType_32BGRA
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: bufferFormat,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000,
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { return nil }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { return nil }
    }

    /// Ajoute une trame déjà rendue. La première trame ouvre la session
    /// à son horodatage pour caler vidéo et audio sur la même horloge.
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    /// Ajoute un échantillon micro (ignoré tant que la vidéo n'a pas démarré).
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard writer.status == .writing, sessionStarted,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Clôt le fichier et rend son URL (nil si l'écriture a échoué).
    func finish(completion: @escaping (URL?) -> Void) {
        guard writer.status == .writing else {
            completion(nil)
            return
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let url = outputURL
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? url : nil)
        }
    }
}
