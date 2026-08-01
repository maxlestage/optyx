import AVFoundation
import CoreMedia
import CoreVideo

/// Écrit la vidéo filtrée en HEVC (.mov).
///
/// PRINCIPE : il reçoit les `CVPixelBuffer` DÉJÀ RENDUS par le moteur pour le
/// viseur, et n'exécute aucun filtre. Enregistrer ne coûte donc que
/// l'encodage — le rendu, lui, était de toute façon payé pour l'affichage.
/// C'est ce qui rend la vidéo tenable à 30 i/s là où une seconde passe de
/// `MoteurOptique` par trame ne le serait pas.
///
/// COROLLAIRE À NE PAS PERDRE DE VUE : le fichier montre EXACTEMENT ce que le
/// viseur montrait, au pixel près, puisque ce sont littéralement les mêmes
/// octets. Aucune divergence viseur/fichier n'est possible par construction.
///
/// Toutes les méthodes sont appelées depuis la file vidéo du contrôleur.
final class EnregistreurVideo {

    let urlSortie: URL
    private let ecrivain: AVAssetWriter
    private let entreeVideo: AVAssetWriterInput
    private let entreeAudio: AVAssetWriterInput?
    private let adaptateur: AVAssetWriterInputPixelBufferAdaptor
    private var sessionOuverte = false

    /// - Parameters:
    ///   - taille: dimensions des trames, déjà paires (exigence de l'encodeur).
    ///   - cadence: images par seconde attendues.
    ///   - avecAudio: n'ajoute la piste micro que si l'autorisation est
    ///     accordée. Une piste audio déclarée mais jamais alimentée allonge la
    ///     clôture du fichier sans rien apporter.
    init?(taille: CGSize, cadence: Int, avecAudio: Bool) {
        urlSortie = FileManager.default.temporaryDirectory
            .appendingPathComponent("Optyx-\(UUID().uuidString).mov")

        guard taille.width >= 2, taille.height >= 2,
              let ecrivain = try? AVAssetWriter(outputURL: urlSortie, fileType: .mov)
        else { return nil }
        self.ecrivain = ecrivain

        // Débit explicite plutôt que le réglage par défaut : ~0,15 bit par pixel
        // et par seconde. Laisser AVFoundation choisir donne, sur un rendu
        // vintage plein de flou et de grain, soit un fichier énorme, soit des
        // blocs visibles dans les dégradés — le grain est précisément ce qu'un
        // encodeur compresse le plus mal.
        let pixelsParSeconde = Double(taille.width * taille.height) * Double(cadence)
        let debit = Int(pixelsParSeconde * 0.15)

        let reglagesVideo: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(taille.width),
            AVVideoHeightKey: Int(taille.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: debit,
                AVVideoExpectedSourceFrameRateKey: cadence,
                AVVideoMaxKeyFrameIntervalKey: cadence * 2,
            ],
        ]
        entreeVideo = AVAssetWriterInput(mediaType: .video, outputSettings: reglagesVideo)
        entreeVideo.expectsMediaDataInRealTime = true

        adaptateur = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: entreeVideo,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(taille.width),
                kCVPixelBufferHeightKey as String: Int(taille.height),
            ])

        guard ecrivain.canAdd(entreeVideo) else { return nil }
        ecrivain.add(entreeVideo)

        if avecAudio {
            let reglagesAudio: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ]
            let entree = AVAssetWriterInput(mediaType: .audio, outputSettings: reglagesAudio)
            entree.expectsMediaDataInRealTime = true
            if ecrivain.canAdd(entree) {
                ecrivain.add(entree)
                entreeAudio = entree
            } else {
                entreeAudio = nil
            }
        } else {
            entreeAudio = nil
        }

        guard ecrivain.startWriting() else { return nil }
    }

    /// Ajoute une trame déjà rendue.
    ///
    /// La PREMIÈRE trame ouvre la session à son propre horodatage. C'est ce qui
    /// cale la vidéo et l'audio sur la même horloge : ouvrir la session à zéro,
    /// ou à l'instant du tap sur le déclencheur, décalerait le son de la durée
    /// écoulée avant l'arrivée de la première image.
    func ajouterVideo(_ tampon: CVPixelBuffer, a instant: CMTime) {
        guard ecrivain.status == .writing else { return }
        if !sessionOuverte {
            ecrivain.startSession(atSourceTime: instant)
            sessionOuverte = true
        }
        guard entreeVideo.isReadyForMoreMediaData else { return }
        adaptateur.append(tampon, withPresentationTime: instant)
    }

    /// Ajoute un échantillon micro. Ignoré tant que la première image vidéo
    /// n'est pas arrivée : un échantillon audio antérieur à l'ouverture de la
    /// session serait rejeté et invaliderait l'écrivain.
    func ajouterAudio(_ echantillon: CMSampleBuffer) {
        guard ecrivain.status == .writing, sessionOuverte,
              let entree = entreeAudio, entree.isReadyForMoreMediaData else { return }
        entree.append(echantillon)
    }

    /// Clôt le fichier et rend son URL, ou nil si l'écriture a échoué.
    func terminer(_ fini: @escaping (URL?) -> Void) {
        guard ecrivain.status == .writing else {
            fini(nil)
            return
        }
        entreeVideo.markAsFinished()
        entreeAudio?.markAsFinished()
        let url = urlSortie
        ecrivain.finishWriting { [ecrivain] in
            fini(ecrivain.status == .completed ? url : nil)
        }
    }

    /// Abandonne l'écriture et supprime le fichier partiel.
    func annuler() {
        ecrivain.cancelWriting()
        try? FileManager.default.removeItem(at: urlSortie)
    }
}
