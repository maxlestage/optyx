import AVFoundation
import CoreImage

/// Écrit la vidéo filtrée en HEVC (.mov) : reçoit les pixel buffers déjà
/// rendus par le moteur — aucun rendu supplémentaire — et la piste micro
/// compressée en AAC. Toutes les méthodes sont appelées depuis la file
/// vidéo de la caméra.
final class VideoRecorder {

    let outputURL: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false

    init?(size: CGSize) {
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Optyx-\(UUID().uuidString).mov")
        guard size.width > 0, size.height > 0,
              let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov)
        else { return nil }
        self.writer = writer

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 96_000,
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
