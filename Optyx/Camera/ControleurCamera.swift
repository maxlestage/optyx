import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import ImageIO
import Photos
import UIKit

// MARK: - Contrôleur de capture
//
// Tout AVFoundation d'Optyx vit ici, et RIEN d'autre : ce fichier ne connaît ni
// SwiftUI, ni Metal, ni MetalKit. Il ouvre la caméra, fait passer chaque trame
// par `MoteurOptique` — le MÊME moteur que le studio, sans variante ni chemin
// « allégé » — et publie le résultat. La photo capturée emprunte exactement la
// même chaîne, à une résolution différente.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE CONTRAT QUI EMPÊCHE LE VISEUR DE MENTIR
// ─────────────────────────────────────────────────────────────────────────────
//
// Viseur   : CVPixelBuffer → CIImage → MoteurOptique.appliquer(…) à 900 px
// Capture  : Data          → MoteurOptique.rendre(…)              à 3200 px → appliquer(…)
//
// Une SEULE implémentation d'`appliquer`, aucune surcharge, aucun drapeau
// « viseur ». Le seul levier autorisé entre les deux est la RÉSOLUTION, et le
// moteur exprime toutes ses longueurs en fraction du grand côté : le viseur et
// le fichier sont donc la même image à l'échelle près. Sauter un étage au
// viseur pour gagner des images par seconde ferait mentir le viseur — c'est le
// défaut fondateur que cette app essaie d'éteindre, pas une optimisation.
//
// ─────────────────────────────────────────────────────────────────────────────
// LES TROIS FILES, ET POURQUOI IL EN FAUT TROIS
// ─────────────────────────────────────────────────────────────────────────────
//
// `fileSession` : configuration, `startRunning`, `stopRunning`, `capturePhoto`.
//     `startRunning()` BLOQUE jusqu'à ~1 s. Sur le fil principal, c'est un gel
//     visible à chaque ouverture de l'onglet.
// `fileVideo`   : délégué des trames + rendu du viseur. SÉRIE, c'est le cœur du
//     mécanisme anti-empilement (voir `captureOutput`).
// `fileCapture` : développement de la photo pleine résolution + écriture dans la
//     photothèque. Surtout PAS `fileVideo` : un rendu à 3200 px prend plusieurs
//     centaines de millisecondes et gèlerait le viseur pendant tout ce temps.
//
// La classe n'est délibérément PAS annotée `@MainActor` : les rappels délégués
// d'AVFoundation arrivent sur `fileVideo` et `fileSession`, et l'annotation
// obligerait à parsemer le fichier de `nonisolated`. Règle tenue partout à la
// place : TOUTE mutation d'un `@Published` passe par `DispatchQueue.main.async`.

/// État global du viseur, tel que l'interface doit le raconter à l'utilisateur.
///
/// `.refuse` et `.indisponible` sont distincts à dessein : envoyer dans les
/// Réglages quelqu'un dont l'appareil n'a tout simplement pas de caméra (le
/// simulateur, par exemple) est une impasse. Chacun mérite son propre panneau.
enum EtatCamera: Equatable {
    /// Session construite mais arrêtée, ou pas encore démarrée.
    case repos
    /// Session en marche. Les trames arrivent (ou vont arriver).
    case enMarche
    /// L'utilisateur a refusé l'accès à l'appareil photo.
    case refuse
    /// Aucun appareil photo utilisable sur cette machine.
    case indisponible
    /// Appel entrant, Split View, ou autre app qui a pris la caméra. Sans cet
    /// état, l'ancienne app laissait un viseur figé et parfaitement muet.
    case interrompue
}

/// Issue d'un déclenchement. Il n'y a pas de cas « silence » : une photo qui
/// disparaît sans un mot est le défaut que l'ancienne app documentait elle-même.
enum RetourCapture: Equatable {
    case enregistree
    case refusePhototheque
    case echec
}

final class ControleurCamera: NSObject, ObservableObject {

    // MARK: - Réglages du viseur

    /// Résolution de travail du viseur, sur le grand côté.
    ///
    /// En deçà du natif d'un écran d'iPhone, et c'est sans conséquence : le
    /// viseur est un cadrage, pas une épreuve. Le graphe de filtres coûte ainsi
    /// une douzaine de fois moins qu'à 1920×1440, ce qui est exactement ce qui
    /// permet de garder la chaîne COMPLÈTE plutôt que de l'amputer.
    static let coteViseur: CGFloat = 900

    // MARK: - État observable (fil principal exclusivement)

    @Published private(set) var etat: EtatCamera = .repos

    /// Tant qu'aucune trame n'est arrivée, l'interface doit couvrir le viseur
    /// d'un voile noir. Sans ce drapeau, l'ouverture de l'onglet montre un éclair
    /// gris — le drawable vide — avant la première image.
    @Published private(set) var premiereTrameRecue = false

    /// Caméra frontale active. Pilote l'icône de bascule.
    @Published private(set) var frontale = false

    /// Déclencheur en cours : la vue le désactive, ce qui évite la double prise.
    @Published private(set) var captureEnCours = false

    /// Dernière issue de capture. La vue l'affiche puis la remet à `nil` via
    /// `accuserRetour()`.
    @Published var retourCapture: RetourCapture?

    /// Aides visuelles du viseur. Elles ne touchent QUE l'affichage — voir
    /// `ReglagesOutils`.
    @Published var outils = ReglagesOutils() { didSet { recopierOutils() } }

    /// Cadrage de la photo. Appliqué AVANT la chaîne d'effets.
    @Published var format: FormatPhoto = .natif { didSet { recopierOutils() } }

    /// VUE NEUTRE : le moteur est entièrement court-circuité, le viseur montre
    /// le flux du capteur tel quel. C'est l'outil de comparaison — juger un
    /// rendu suppose de voir ce à quoi on le compare, et un curseur d'intensité
    /// à zéro ne donne pas la même chose (il laisse la chaîne s'exécuter).
    @Published var vueNeutre = false { didSet { recopierOutils() } }

    /// Répartition des tons du rendu AFFICHÉ. Vide tant que l'histogramme n'est
    /// pas demandé.
    @Published private(set) var histogramme: DonneesHistogramme = .vide

    /// Un enregistrement vidéo est-il en cours ? Pilote le bouton et le
    /// chronomètre.
    @Published private(set) var enregistrementEnCours = false
    /// Durée écoulée, en secondes entières.
    @Published private(set) var secondesEnregistrees = 0

    // MARK: - Réglages optiques poussés par la vue

    /// Verrou des deux réglages ci-dessous.
    ///
    /// Ils sont ÉCRITS depuis le fil principal (curseur, barre d'objectifs) et
    /// LUS depuis `fileVideo` à chaque trame. Un `struct` lu pendant son écriture
    /// est une course de données réelle, pas théorique. `NSLock` coûte quelques
    /// nanosecondes trente fois par seconde : c'est gratuit.
    ///
    /// Ils ne sont volontairement PAS `@Published` : la source de vérité est
    /// l'`@State` de la vue. Les republier ici créerait deux vérités qui finissent
    /// toujours par diverger.
    private let verrouReglages = NSLock()
    private var _lens: Lens = Lens.catalog[0]
    private var _intensite: Float = 0.75

    /// L'objectif appliqué au flux et à la prochaine photo.
    var lens: Lens {
        get { verrouReglages.lock(); defer { verrouReglages.unlock() }; return _lens }
        set { verrouReglages.lock(); _lens = newValue; verrouReglages.unlock() }
    }

    /// L'intensité, dans [0, 1].
    var intensite: Float {
        get { verrouReglages.lock(); defer { verrouReglages.unlock() }; return _intensite }
        set { verrouReglages.lock(); _intensite = min(max(newValue, 0), 1); verrouReglages.unlock() }
    }

    /// Pose les deux d'un coup, sans deux prises de verrou.
    func regler(lens: Lens, intensite: Float) {
        verrouReglages.lock()
        _lens = lens
        _intensite = min(max(intensite, 0), 1)
        verrouReglages.unlock()
    }

    // MARK: - Publication des trames

    /// Appelée pour CHAQUE trame développée, **sur `fileVideo`**, jamais sur le
    /// fil principal.
    ///
    /// Le contrôleur ne connaît pas l'afficheur : il ne référence ni MetalKit ni
    /// SwiftUI. C'est la couche d'affichage qui branche cette fermeture sur son
    /// propre rendu, typiquement en recopiant l'image sous verrou puis en
    /// demandant un redessin sur le fil principal.
    ///
    /// L'image livrée est adossée à un `CVPixelBuffer` DÉJÀ RENDU, pris dans un
    /// anneau de trois. Elle est donc immédiatement affichable — aucun filtre ne
    /// reste à exécuter — mais son contenu sera réécrit trois trames plus tard :
    /// il ne faut pas la conserver au-delà du redessin qui suit.
    var surTrameViseur: ((CIImage) -> Void)? {
        get { verrouReglages.lock(); defer { verrouReglages.unlock() }; return _surTrameViseur }
        set { verrouReglages.lock(); _surTrameViseur = newValue; verrouReglages.unlock() }
    }
    private var _surTrameViseur: ((CIImage) -> Void)?

    // MARK: - Machinerie AVFoundation

    private let session = AVCaptureSession()
    private let sortieVideo = AVCaptureVideoDataOutput()
    private let sortieAudio = AVCaptureAudioDataOutput()
    /// Le micro a-t-il pu être rattaché à la session ? Écrit à la construction,
    /// lu au démarrage d'un enregistrement.
    private var audioDisponible = false

    /// Enregistreur courant, `fileVideo` uniquement. Non nil ⇔ enregistrement
    /// en cours du point de vue du chemin des trames.
    private var enregistreur: EnregistreurVideo?
    /// Instant de la première trame écrite, pour le chronomètre affiché.
    private var debutEnregistrement: CMTime?
    /// Dernière seconde publiée. Évite trente sauts sur le fil principal par
    /// seconde pour une valeur qui ne change qu'une fois.
    private var secondesPubliees = -1

    /// Compteur de trames pour la cadence réduite de l'histogramme.
    /// `fileVideo` uniquement.
    private var compteurHistogramme = 0

    /// Copies protégées par `verrouReglages`, lues à chaque trame sur
    /// `fileVideo`. Les `@Published` correspondants appartiennent au fil
    /// principal : les lire depuis la file vidéo serait une course de données,
    /// trente fois par seconde.
    ///
    /// SUFFIXE `Verrouille` ET NON PRÉFIXE `_`, contrairement à `_lens` et
    /// `_intensite` juste au-dessus. La différence tient à `@Published`, qui
    /// synthétise DÉJÀ un stockage nommé `_outils`, `_format`, `_vueNeutre` :
    /// déclarer les nôtres sous ces noms donne « invalid redeclaration of
    /// synthesized property », erreur qui a cassé la compilation une fois. Le
    /// motif d'à côté est trompeur parce que `lens` et `intensite`, eux, ne
    /// sont PAS `@Published` — ce sont des propriétés calculées ordinaires, et
    /// leur préfixe souligné est donc libre.
    private var outilsVerrouilles = ReglagesOutils()
    private var formatVerrouille: FormatPhoto = .natif
    private var vueNeutreVerrouille = false

    /// Recopie les réglages d'affichage vers leurs doubles verrouillés.
    /// Appelée depuis le fil principal par les `didSet`.
    private func recopierOutils() {
        verrouReglages.lock()
        outilsVerrouilles = outils
        formatVerrouille = format
        vueNeutreVerrouille = vueNeutre
        verrouReglages.unlock()
    }
    private let sortiePhoto = AVCapturePhotoOutput()

    private let fileSession = DispatchQueue(label: "optyx.camera.session", qos: .userInitiated)
    private let fileVideo = DispatchQueue(label: "optyx.camera.video", qos: .userInitiated)
    private let fileCapture = DispatchQueue(label: "optyx.camera.capture", qos: .userInitiated)

    /// Position courante. Lue et écrite sur `fileSession` uniquement.
    private var position: AVCaptureDevice.Position = .back
    /// La session a-t-elle déjà été construite ? `fileSession` uniquement.
    private var configuree = false

    /// L'utilisateur VEUT-il le viseur ouvert ? `fileSession` uniquement.
    ///
    /// Distinct de `session.isRunning` : sans lui, une notification de fin
    /// d'interruption arrivant après un `arreter()` rallumerait la caméra dans un
    /// onglet que l'utilisateur a quitté. C'est le genre de reprise fantôme qui
    /// vide une batterie sans que rien ne s'affiche.
    private var souhaiteMarcher = false

    // MARK: - État de `fileVideo`

    /// Orientation à appliquer à la trame du capteur. Calculée sur le fil
    /// principal (§ ORIENTATION), poussée ici par un `async` : jamais lue en
    /// concurrence avec son écriture.
    private var orientationCapteur: CGImagePropertyOrientation = .right

    /// Le drapeau anti-empilement demandé par la spécification.
    ///
    /// Lu et écrit sur la seule `fileVideo`, donc sans verrou possible d'oubli.
    /// À vrai dire, il est REDONDANT : `fileVideo` est série et la sortie vidéo
    /// porte `alwaysDiscardsLateVideoFrames`, ce qui suffit à garantir qu'une
    /// trame arrivée pendant un rendu est jetée par AVFoundation plutôt que mise
    /// en file. On le garde parce qu'il ne coûte rien et qu'il rend la garantie
    /// LISIBLE à l'endroit exact où elle compte — le jour où quelqu'un rendra
    /// `fileVideo` concurrente « pour aller plus vite », c'est cette ligne qui
    /// sauvera la cadence.
    private var renduEnCours = false

    /// La première trame a-t-elle déjà été signalée ? Copie locale à `fileVideo`
    /// du `@Published` du même nom : lire une propriété du fil principal à chaque
    /// trame serait une course de données, pour économiser un seul `async`.
    private var premiereTrameSignalee = false

    /// Anneau de trois `CVPixelBuffer`. `fileVideo` uniquement.
    ///
    /// Trois et non huit : le seul objet qui retient un tampon est l'affichage,
    /// sur une fenêtre d'au plus une trame écran. Un seul tampon ferait réécrire
    /// l'image pendant que le GPU la lit — c'est le scintillement classique.
    private var anneau: [CVPixelBuffer] = []
    private var indexAnneau = 0
    private var tailleAnneau = CGSize.zero

    /// Espace de rendu du viseur. sRGB explicite pour coïncider avec l'espace de
    /// travail imposé par `MoteurOptique` : laisser `nil` livrerait le rendu dans
    /// l'espace du contexte et la teinte du viseur dériverait de celle du studio.
    private let espaceViseur = CGColorSpace(name: CGColorSpace.sRGB)

    // MARK: - État du fil principal

    /// Dernière tenue EXPLOITABLE. Fil principal uniquement.
    ///
    /// Le type reste `UIDeviceOrientation` parce que les deux tables de rotation
    /// (`orientationPourViseur`, `angleRotationPhoto`) sont écrites dans ce
    /// repère, mais la VALEUR vient désormais de l'interface, pas de
    /// l'accéléromètre : voir `tenueDepuisInterface()`, qui explique pourquoi et
    /// où les deux repères s'inversent. Seules les quatre orientations utiles y
    /// entrent — poser le téléphone à plat ne fait donc pivoter rien du tout.
    private var tenue: UIDeviceOrientation = .portrait

    // MARK: - Cycle de vie

    override init() {
        super.init()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            self.relireTenue()
        }

        let centre = NotificationCenter.default
        // L'accéléromètre reste la MEILLEURE horloge : c'est lui qui prévient au
        // bon moment. Seule la SOURCE de la valeur change — on relit la scène, pas
        // le capteur (voir `tenueDepuisInterface`). `didBecomeActive` couvre le
        // retour d'arrière-plan, où l'interface a pu pivoter sans qu'aucune
        // notification d'appareil ne nous parvienne.
        centre.addObserver(self, selector: #selector(tenueChangee(_:)),
                           name: UIDevice.orientationDidChangeNotification, object: nil)
        centre.addObserver(self, selector: #selector(tenueChangee(_:)),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        centre.addObserver(self, selector: #selector(sessionInterrompue),
                           name: .AVCaptureSessionWasInterrupted, object: session)
        centre.addObserver(self, selector: #selector(sessionReprise),
                           name: .AVCaptureSessionInterruptionEnded, object: session)
        centre.addObserver(self, selector: #selector(sessionEnErreur),
                           name: .AVCaptureSessionRuntimeError, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Sans capture de `self` : `deinit` peut s'exécuter hors du fil
        // principal, et `UIDevice` n'y a rien à faire.
        DispatchQueue.main.async {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

    /// Ouvre le viseur. À appeler depuis `.onAppear` et au retour de
    /// `scenePhase == .active`.
    ///
    /// Idempotente : un second appel sur une session déjà en marche ne fait rien
    /// de coûteux.
    func demarrer() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            lancer()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] accorde in
                guard let self else { return }
                if accorde {
                    self.lancer()
                } else {
                    self.publier(etat: .refuse)
                }
            }
        default:
            // `.denied`, `.restricted`, et tout cas futur : même conduite, et
            // surtout jamais d'écran noir muet. La vue affiche un panneau qui
            // explique et propose d'ouvrir les Réglages.
            publier(etat: .refuse)
        }
    }

    /// Ferme le viseur. À appeler depuis `.onDisappear` et sur
    /// `scenePhase == .background` : une session qui tourne dans un onglet
    /// invisible chauffe le téléphone pour rien.
    func arreter() {
        // Un enregistrement en cours est CLOS, jamais abandonné : quitter
        // l'onglet ou passer en arrière-plan doit sauver ce qui est déjà filmé.
        // Le laisser tomber perdrait la prise et abandonnerait un .mov partiel
        // dans le dossier temporaire.
        if enregistrementEnCours { arreterEnregistrement() }

        fileSession.async { [weak self] in
            guard let self else { return }
            self.souhaiteMarcher = false
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async {
                if self.etat == .enMarche || self.etat == .interrompue {
                    self.etat = .repos
                }
                self.premiereTrameRecue = false
            }
        }
        fileVideo.async { [weak self] in
            self?.premiereTrameSignalee = false
        }
    }

    /// Passe de l'arrière à l'avant, et retour.
    func basculerCamera() {
        fileSession.async { [weak self] in
            guard let self else { return }
            let cible: AVCaptureDevice.Position = (self.position == .back) ? .front : .back
            let ancienne = self.position
            self.position = cible

            let marchait = self.session.isRunning

            // Reconstruction COMPLÈTE : retirer toutes les entrées et sorties
            // avant de rajouter. Insérer une seconde entrée sans retirer la
            // première lève une exception Objective-C, que Swift ne rattrape pas.
            guard self.construireSession() else {
                // Repli sur la caméra précédente plutôt que de laisser la session
                // vide : mieux vaut ne pas basculer que perdre le viseur.
                self.position = ancienne
                if self.construireSession() {
                    if marchait, !self.session.isRunning { self.session.startRunning() }
                } else {
                    self.configuree = false
                    self.publier(etat: .indisponible)
                }
                return
            }

            self.configuree = true
            if marchait, !self.session.isRunning { self.session.startRunning() }

            DispatchQueue.main.async {
                self.frontale = (cible == .front)
                // Le miroir du viseur dépend de la position : il faut recalculer
                // l'orientation capteur maintenant, pas au prochain pivotement.
                self.appliquerOrientation()
            }
        }

        // L'anneau de tampons appartient à `fileVideo` : le vider ici évite de
        // réafficher, une trame durant, l'image de l'autre caméra.
        fileVideo.async { [weak self] in
            self?.anneau.removeAll()
            self?.tailleAnneau = .zero
        }
    }

    /// Remet `retourCapture` à `nil` une fois le message montré.
    func accuserRetour() {
        retourCapture = nil
    }

    // MARK: - Démarrage effectif

    private func lancer() {
        fileSession.async { [weak self] in
            guard let self else { return }
            self.souhaiteMarcher = true

            if !self.configuree {
                guard self.construireSession() else {
                    self.publier(etat: .indisponible)
                    return
                }
                self.configuree = true
            }

            // `startRunning()` bloque jusqu'à ~1 s : c'est toute la raison d'être
            // de `fileSession`.
            if !self.session.isRunning { self.session.startRunning() }
            self.publier(etat: .enMarche)
        }

        DispatchQueue.main.async { [weak self] in
            self?.appliquerOrientation()
        }
    }

    /// Construit (ou reconstruit) la session. `fileSession` UNIQUEMENT.
    ///
    /// Renvoie `false` si l'appareil n'a pas de caméra utilisable — cas normal
    /// sur simulateur, et qui doit donner un panneau explicite, pas un plantage.
    private func construireSession() -> Bool {
        session.beginConfiguration()

        // `.photo` et non `.hd1280x720` : c'est le preset qui donne à
        // `AVCapturePhotoOutput` la pleine définition du capteur. Le flux du
        // viseur arrive donc plus grand que nécessaire — on le réduit en Core
        // Image, ce qui coûte une transformation affine GPU, négligeable.
        session.sessionPreset = .photo

        for entree in session.inputs { session.removeInput(entree) }
        for sortie in session.outputs { session.removeOutput(sortie) }

        // Un seul `deviceType`. L'ancienne app cherchait d'abord les caméras à
        // profondeur (LiDAR, dual wide) ; sans carte de profondeur — et le moteur
        // n'en demande aucune, son masque est radial — ce choix n'a plus de
        // raison d'être, et il faisait varier le champ de vision d'un modèle
        // d'iPhone à l'autre.
        let recherche = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )

        guard let appareil = recherche.devices.first else {
            session.commitConfiguration()
            return false
        }

        guard let entree = try? AVCaptureDeviceInput(device: appareil),
              session.canAddInput(entree) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(entree)

        guard session.canAddOutput(sortieVideo) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(sortieVideo)

        // PIÈGE : `videoSettings` doit être posé APRÈS `addOutput`. Posé avant,
        // le réglage peut être ignoré et la sortie livre du YUV bi-planaire au
        // lieu du BGRA. `CIImage(cvPixelBuffer:)` fonctionne quand même, mais
        // l'espace colorimétrique dérape et le viseur cesse de correspondre au
        // studio. Panne parfaitement silencieuse.
        sortieVideo.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // LE mécanisme anti-empilement : si `fileVideo` est encore occupée quand
        // une trame arrive, AVFoundation la JETTE au lieu de la mettre en file.
        // La cadence chute proprement au lieu de dériver seconde après seconde.
        sortieVideo.alwaysDiscardsLateVideoFrames = true
        sortieVideo.setSampleBufferDelegate(self, queue: fileVideo)

        // On ne pose AUCUN `videoRotationAngle` sur la connexion vidéo :
        // AVFoundation ferait alors tourner chaque trame lui-même, ce qui coûte
        // une passe complète et change les dimensions du tampon livré. La
        // rotation du viseur se fait en Core Image (`oriented(_:)`), où elle se
        // replie dans la transformation du graphe et ne coûte rien.

        // ÉCHEC FRANC, et non « on continue sans ». Une session qui tourne sans
        // sortie photo rattachée donne un état `.enMarche`, un déclencheur actif,
        // et une `NSInvalidArgumentException` — « no active and enabled video
        // connection » — au premier appui : un plantage dur, que Swift ne rattrape
        // pas. Mieux vaut `.indisponible` et un panneau qui explique.
        guard session.canAddOutput(sortiePhoto) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(sortiePhoto)

        // MICRO — facultatif, et c'est délibéré. L'accès micro est refusé bien
        // plus souvent que l'accès caméra, et une app photo qui refuse de
        // démarrer parce qu'elle n'a pas le son serait absurde. Sans micro, la
        // vidéo s'enregistre muette ; l'utilisateur n'est jamais bloqué.
        //
        // On ne DEMANDE pas l'autorisation ici : la demander au lancement, avant
        // que quiconque ait voulu filmer, est le meilleur moyen de se la faire
        // refuser une fois pour toutes. Elle est demandée au premier
        // enregistrement, dans `basculerEnregistrement()`.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let micro = AVCaptureDevice.default(for: .audio),
           let entreeMicro = try? AVCaptureDeviceInput(device: micro),
           session.canAddInput(entreeMicro),
           session.canAddOutput(sortieAudio) {
            session.addInput(entreeMicro)
            session.addOutput(sortieAudio)
            sortieAudio.setSampleBufferDelegate(self, queue: fileVideo)
            audioDisponible = true
        } else {
            audioDisponible = false
        }

        session.commitConfiguration()

        plafonnerCadence(appareil)
        return true
    }

    /// Plafonne le capteur à 30 i/s.
    ///
    /// Sans cela il peut livrer à 60 : on doublerait le travail du graphe pour un
    /// viseur que personne ne perçoit plus fluide. `do/catch`, jamais `try!` —
    /// `lockForConfiguration` échoue légitimement si une autre app tient le
    /// périphérique, et ce n'est pas une raison de faire tomber l'app.
    private func plafonnerCadence(_ appareil: AVCaptureDevice) {
        let cible = CMTime(value: 1, timescale: 30)
        guard let plage = appareil.activeFormat.videoSupportedFrameRateRanges.first else { return }
        guard CMTimeCompare(cible, plage.minFrameDuration) >= 0,
              CMTimeCompare(cible, plage.maxFrameDuration) <= 0 else { return }
        do {
            try appareil.lockForConfiguration()
            appareil.activeVideoMinFrameDuration = cible
            appareil.activeVideoMaxFrameDuration = cible
            appareil.unlockForConfiguration()
        } catch {
            // Cadence non plafonnée : le viseur reste correct, simplement plus
            // gourmand. Rien à signaler à l'utilisateur.
        }
    }

    // MARK: - Orientation

    /// Le sélecteur prend bien un `Notification` : `NotificationCenter` documente
    /// que la méthode observée doit avoir un et un seul argument. Un sélecteur
    /// sans paramètre « marche » en pratique sur ARM64, ce qui est exactement le
    /// genre de chance sur laquelle on ne construit rien.
    @objc private func tenueChangee(_ note: Notification) {
        relireTenue()
    }

    /// Fil principal uniquement.
    private func relireTenue() {
        // On GARDE la dernière tenue connue quand la scène ne sait pas encore
        // répondre. Sans ce filtre, une lecture transitoire ferait pivoter le
        // viseur d'un quart de tour pour rien.
        if let nouvelle = Self.tenueDepuisInterface() {
            tenue = nouvelle
        }
        appliquerOrientation()
    }

    /// Tenue déduite de l'INTERFACE, et non de l'accéléromètre. Fil principal
    /// uniquement. Renvoie `nil` quand aucune scène exploitable n'est trouvée.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// POURQUOI PAS `UIDevice.current.orientation`
    /// ─────────────────────────────────────────────────────────────────────────
    /// L'orientation de l'appareil est PHYSIQUE : elle décrit comment le
    /// téléphone est tenu dans l'espace, pas comment l'interface est posée. Les
    /// deux divergent dans deux cas parfaitement silencieux, et le viseur ment
    /// alors sur le cadrage :
    ///
    /// 1. Téléphone retourné. La cible déclare les quatre orientations, mais
    ///    aucun iPhone à encoche n'adopte réellement `portraitUpsideDown` :
    ///    l'accéléromètre bascule, l'interface non. Le viseur partait à 180°
    ///    pendant que le déclencheur, les puces et le curseur restaient en place.
    /// 2. Lancement en paysage. `UIDevice.current.orientation` vaut `.unknown`
    ///    tant que l'accéléromètre n'a pas produit sa première notification : les
    ///    premières trames sortaient tournées d'un quart de tour, et une photo
    ///    déclenchée dans cette fenêtre partait couchée puisque `declencher()`
    ///    lit la même `tenue`. L'orientation d'interface, elle, est juste dès la
    ///    première image.
    ///
    /// PIÈGE CLASSIQUE : les deux repères sont INVERSÉS en paysage.
    /// `UIInterfaceOrientation.landscapeLeft` correspond à
    /// `UIDeviceOrientation.landscapeRight`, et réciproquement. Le croisement
    /// ci-dessous est donc volontaire : ne pas le « corriger ».
    private static func tenueDepuisInterface() -> UIDeviceOrientation? {
        var trouvee: UIInterfaceOrientation = .unknown
        for scene in UIApplication.shared.connectedScenes {
            guard let fenetre = scene as? UIWindowScene else { continue }
            // La scène active au premier plan fait foi ; à défaut, la première
            // scène de fenêtre rencontrée sert de repli.
            if scene.activationState == .foregroundActive {
                trouvee = fenetre.interfaceOrientation
                break
            }
            if trouvee == .unknown { trouvee = fenetre.interfaceOrientation }
        }

        switch trouvee {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }

    /// Calcule l'orientation capteur sur le fil principal, puis la POUSSE sur
    /// `fileVideo`. Elle n'est ainsi jamais lue en concurrence de son écriture.
    private func appliquerOrientation() {
        let valeur = Self.orientationPourViseur(tenue: tenue, frontale: frontale)
        fileVideo.async { [weak self] in
            self?.orientationCapteur = valeur
        }
    }

    /// Correspondance canonique tenue → orientation Core Image.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// LE MIROIR — règle explicite, à NE PAS « corriger »
    /// ─────────────────────────────────────────────────────────────────────────
    /// Le viseur frontal est EN MIROIR ; le fichier enregistré ne l'est PAS.
    /// C'est le comportement de l'app Appareil photo d'Apple (réglage « Miroir
    /// avant » désactivé par défaut) et donc l'attente de l'utilisateur : on se
    /// cadre dans un miroir, on obtient l'image telle que l'objectif l'a vue.
    ///
    /// Le miroir vient UNIQUEMENT des variantes `…Mirrored` ci-dessous, qui ne
    /// s'appliquent qu'au flux du viseur. La connexion photo n'est jamais mise en
    /// miroir : `isVideoMirrored` reste à son défaut et
    /// `automaticallyAdjustsVideoMirroring` reste `true`. La photo capturée ne
    /// traverse jamais cette table — elle porte son propre angle de rotation,
    /// posé dans `declencher()`.
    ///
    /// Ce commentaire existe parce que, sans lui, le prochain lecteur voit une
    /// asymétrie, la prend pour un bug, et casse le comportement attendu.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// LA RÈGLE QUI EMPÊCHE LA RECHUTE
    /// ─────────────────────────────────────────────────────────────────────────
    /// La valeur frontale est TOUJOURS le miroir horizontal de la valeur arrière.
    /// Le miroir se lit dans la définition EXIF de `CGImagePropertyOrientation`,
    /// qui dit où partent la ligne 0 et la colonne 0 du tampon : retourner l'image
    /// horizontalement échange « colonne 0 à gauche » et « colonne 0 à droite »,
    /// et ne touche PAS à la ligne 0. D'où les quatre seules paires légitimes :
    ///
    ///     .up    ↔ .upMirrored        (ligne 0 en haut,    colonne 0 gauche/droite)
    ///     .down  ↔ .downMirrored      (ligne 0 en bas,     colonne 0 droite/gauche)
    ///     .right ↔ .leftMirrored      (colonne 0 en haut,  ligne 0 droite/gauche)
    ///     .left  ↔ .rightMirrored     (colonne 0 en bas,   ligne 0 gauche/droite)
    ///
    /// Toute paire qui ne respecte pas cette table est fausse de 180° : le viseur
    /// frontal se retrouve tête en bas alors que les commandes SwiftUI, elles, ont
    /// bien pivoté. C'est exactement le défaut que les deux lignes paysage
    /// portaient — elles renvoyaient `.downMirrored` pour `.up` et `.upMirrored`
    /// pour `.down`.
    private static func orientationPourViseur(tenue: UIDeviceOrientation,
                                              frontale: Bool) -> CGImagePropertyOrientation {
        switch tenue {
        case .portraitUpsideDown:
            return frontale ? .rightMirrored : .left
        case .landscapeLeft:
            return frontale ? .upMirrored : .up
        case .landscapeRight:
            return frontale ? .downMirrored : .down
        default:
            // `.portrait` et tout le reste : la tenue par défaut.
            return frontale ? .leftMirrored : .right
        }
    }

    /// Angle à poser sur la connexion PHOTO, en degrés.
    ///
    /// `videoRotationAngle` (iOS 17) et non `videoOrientation` (déprécié en
    /// iOS 17) : leurs axes sont inversés l'un par rapport à l'autre, et les
    /// mélanger est la recette classique de la photo à 180°.
    private static func angleRotationPhoto(tenue: UIDeviceOrientation) -> CGFloat {
        switch tenue {
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        default: return 90
        }
    }

    // MARK: - Déclencheur

    /// Prend une photo, la développe avec le MÊME moteur que le viseur, et
    /// l'enregistre. À appeler depuis le fil principal.
    func declencher() {
        guard !captureEnCours else { return }
        guard etat == .enMarche else {
            retourCapture = .echec
            return
        }

        captureEnCours = true
        retourCapture = nil

        let angle = Self.angleRotationPhoto(tenue: tenue)

        fileSession.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                self.terminerCapture(.echec)
                return
            }

            // GARDE, et non simple pose d'angle. `capturePhoto(with:delegate:)`
            // sans connexion vidéo active et activée lève une
            // `NSInvalidArgumentException` : une exception Objective-C, donc un
            // plantage dur au moment précis où l'utilisateur appuie. Un `guard`
            // ici transforme ce plantage en message d'échec visible.
            guard let connexion = self.sortiePhoto.connection(with: .video),
                  connexion.isEnabled, connexion.isActive else {
                self.terminerCapture(.echec)
                return
            }

            // L'angle est posé sur la connexion photo — et là, oui : les octets
            // rendus par `fileDataRepresentation()` sortent alors DÉJÀ droits,
            // EXIF cohérent. `MoteurOptique.imageReduite` normalise de toute
            // façon l'orientation derrière : la chaîne est doublement protégée.
            if connexion.isVideoRotationAngleSupported(angle) {
                connexion.videoRotationAngle = angle
            }

            // PIÈGE : une instance FRAÎCHE à chaque capture. Réutiliser la
            // précédente lève une `NSInvalidArgumentException` — un plantage dur,
            // pas une erreur Swift rattrapable. C'est exactement le genre de
            // « mise en cache » qu'un relecteur propose spontanément.
            let reglages: AVCapturePhotoSettings
            if self.sortiePhoto.availablePhotoCodecTypes.contains(.jpeg) {
                reglages = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                reglages = AVCapturePhotoSettings()
            }

            self.sortiePhoto.capturePhoto(with: reglages, delegate: self)
        }
    }

    private func terminerCapture(_ retour: RetourCapture) {
        DispatchQueue.main.async { [weak self] in
            self?.captureEnCours = false
            self?.retourCapture = retour
        }
    }

    // MARK: - Photothèque

    /// Autorisation d'AJOUT SEUL, jamais l'accès complet : Optyx écrit dans la
    /// photothèque, il ne la lit jamais. Demander l'accès complet pour écrire un
    /// fichier est le genre de demande qui fait refuser tout net.
    private func enregistrer(jpeg: Data) {
        let statut = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch statut {
        case .authorized, .limited:
            ecrire(jpeg: jpeg)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] nouveau in
                guard let self else { return }
                if nouveau == .authorized || nouveau == .limited {
                    self.ecrire(jpeg: jpeg)
                } else {
                    self.terminerCapture(.refusePhototheque)
                }
            }
        default:
            self.terminerCapture(.refusePhototheque)
        }
    }

    /// Écrit les octets tels quels.
    ///
    /// `addResource(with:data:options:)` plutôt qu'un `UIImage` : passer par une
    /// image ferait réencoder le fichier par le système avec ses propres
    /// réglages, et l'utilisateur n'obtiendrait pas les octets qu'on a produits.
    private func ecrire(jpeg: Data) {
        PHPhotoLibrary.shared().performChanges {
            let requete = PHAssetCreationRequest.forAsset()
            requete.addResource(with: .photo, data: jpeg, options: nil)
        } completionHandler: { [weak self] succes, _ in
            self?.terminerCapture(succes ? .enregistree : .echec)
        }
    }

    // MARK: - Histogramme

    /// Nombre de classes. 64 et non 256 : au-delà, le tracé n'apporte plus
    /// aucune information sur un histogramme large de quelques centimètres, et
    /// la lecture GPU→CPU croît d'autant.
    private static let classesHistogramme = 64

    /// Mesure la répartition des tons. Appelée sur `fileVideo`.
    private func mesurerHistogramme(_ image: CIImage, cadre: CGRect) {
        let classes = Self.classesHistogramme
        let filtre = CIFilter.areaHistogram()
        filtre.inputImage = image
        filtre.extent = cadre
        filtre.count = classes
        filtre.scale = 1
        guard let sortie = filtre.outputImage else { return }

        var brut = [Float](repeating: 0, count: classes * 4)
        MoteurOptique.contexteImages.render(
            sortie,
            toBitmap: &brut,
            rowBytes: classes * 16,
            bounds: CGRect(x: 0, y: 0, width: classes, height: 1),
            format: .RGBAf,
            colorSpace: nil)

        var rouge = [Float](repeating: 0, count: classes)
        var vert = rouge
        var bleu = rouge
        for classe in 0..<classes {
            rouge[classe] = brut[classe * 4]
            vert[classe] = brut[classe * 4 + 1]
            bleu[classe] = brut[classe * 4 + 2]
        }

        // Normalisation par le PIC COMMUN aux trois canaux, et non canal par
        // canal : normaliser séparément ferait monter les trois courbes au même
        // sommet et effacerait précisément ce qu'on vient lire — la dominante
        // de couleur. Sur un Takumar, les trois canaux paraîtraient équilibrés.
        let pic = max(rouge.max() ?? 0, vert.max() ?? 0, bleu.max() ?? 0)
        guard pic > 0 else { return }
        let donnees = DonneesHistogramme(rouge: rouge.map { $0 / pic },
                                         vert: vert.map { $0 / pic },
                                         bleu: bleu.map { $0 / pic })
        DispatchQueue.main.async { [weak self] in
            self?.histogramme = donnees
        }
    }

    // MARK: - Vidéo

    /// Démarre ou arrête l'enregistrement. À appeler depuis le fil principal.
    ///
    /// Le micro est demandé ICI, au premier enregistrement, et non au lancement
    /// de l'app : une autorisation réclamée avant que l'utilisateur ait montré
    /// la moindre intention de filmer est celle qu'on se fait refuser, et un
    /// refus est définitif jusqu'aux Réglages.
    func basculerEnregistrement() {
        if enregistrementEnCours {
            arreterEnregistrement()
            return
        }

        let statut = AVCaptureDevice.authorizationStatus(for: .audio)
        if statut == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] accorde in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Le micro vient d'être accordé : il faut reconstruire la
                    // session pour l'y rattacher, sinon la première vidéo
                    // serait muette alors que l'utilisateur vient d'accepter.
                    if accorde { self.reconstruirePourAudio() }
                    self.demarrerEnregistrement()
                }
            }
            return
        }
        demarrerEnregistrement()
    }

    /// Rattache le micro à une session déjà bâtie.
    private func reconstruirePourAudio() {
        fileSession.async { [weak self] in
            guard let self, !self.audioDisponible else { return }
            guard let micro = AVCaptureDevice.default(for: .audio),
                  let entree = try? AVCaptureDeviceInput(device: micro) else { return }
            self.session.beginConfiguration()
            if self.session.canAddInput(entree), self.session.canAddOutput(self.sortieAudio) {
                self.session.addInput(entree)
                self.session.addOutput(self.sortieAudio)
                self.sortieAudio.setSampleBufferDelegate(self, queue: self.fileVideo)
                self.audioDisponible = true
            }
            self.session.commitConfiguration()
        }
    }

    private func demarrerEnregistrement() {
        let avecAudio = audioDisponible
        fileVideo.async { [weak self] in
            guard let self, self.enregistreur == nil else { return }
            // La taille vient du dernier tampon rendu : c'est exactement celle
            // des trames qui vont être écrites. La deviner autrement, depuis le
            // preset ou l'écran, produirait un écrivain qui refuse chaque trame
            // sans le dire.
            let taille = self.tailleAnneau
            guard taille.width >= 2, taille.height >= 2 else {
                // Aucune trame n'a encore été rendue : l'anneau n'existe pas,
                // donc on ignore la taille des images à écrire. Démarrer
                // maintenant créerait un écrivain aux mauvaises dimensions, qui
                // refuserait chaque trame en silence.
                DispatchQueue.main.async { self.retourCapture = .echec }
                return
            }
            self.enregistreur = EnregistreurVideo(taille: taille, cadence: 30, avecAudio: avecAudio)
            self.debutEnregistrement = nil
            self.secondesPubliees = -1
            let demarre = self.enregistreur != nil
            DispatchQueue.main.async {
                self.secondesEnregistrees = 0
                self.enregistrementEnCours = demarre
                if !demarre { self.retourCapture = .echec }
            }
        }
    }

    private func arreterEnregistrement() {
        fileVideo.async { [weak self] in
            guard let self, let enregistreur = self.enregistreur else { return }
            self.enregistreur = nil
            self.debutEnregistrement = nil
            enregistreur.terminer { [weak self] url in
                guard let self else { return }
                DispatchQueue.main.async { self.enregistrementEnCours = false }
                guard let url else {
                    DispatchQueue.main.async { self.retourCapture = .echec }
                    return
                }
                self.enregistrerVideo(url)
            }
        }
    }

    /// Dépose le .mov dans la photothèque, puis efface le fichier temporaire —
    /// une vidéo de plusieurs dizaines de mégaoctets laissée dans `tmp` finirait
    /// par saturer l'espace de l'app.
    private func enregistrerVideo(_ url: URL) {
        let nettoyer = { try? FileManager.default.removeItem(at: url) }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] statut in
            guard let self else { return }
            guard statut == .authorized || statut == .limited else {
                nettoyer()
                DispatchQueue.main.async { self.retourCapture = .refusePhototheque }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let requete = PHAssetCreationRequest.forAsset()
                requete.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { succes, _ in
                nettoyer()
                DispatchQueue.main.async {
                    self.retourCapture = succes ? .enregistree : .echec
                }
            }
        }
    }

    // MARK: - Incidents de session

    @objc private func sessionInterrompue(_ note: Notification) {
        publier(etat: .interrompue)
    }

    @objc private func sessionReprise(_ note: Notification) {
        fileSession.async { [weak self] in
            guard let self else { return }
            guard self.souhaiteMarcher else { return }
            if !self.session.isRunning { self.session.startRunning() }
            self.publier(etat: .enMarche)
        }
    }

    @objc private func sessionEnErreur(_ note: Notification) {
        // Erreur d'exécution : la session s'est arrêtée toute seule. On relance
        // depuis `fileSession`. Sans cela — et l'ancienne app n'observait aucune
        // de ces trois notifications — un appel entrant laissait un viseur figé
        // et parfaitement muet.
        fileSession.async { [weak self] in
            guard let self else { return }
            guard self.configuree, self.souhaiteMarcher else { return }
            if !self.session.isRunning { self.session.startRunning() }
            self.publier(etat: self.session.isRunning ? .enMarche : .repos)
        }
    }

    // MARK: - Utilitaires

    private func publier(etat nouveau: EtatCamera) {
        DispatchQueue.main.async { [weak self] in
            self?.etat = nouveau
        }
    }

    /// Tampon suivant de l'anneau, recréé si les dimensions ont changé.
    /// `fileVideo` UNIQUEMENT.
    ///
    /// `CVPixelBufferCreate` directement, et non `CVPixelBufferPoolCreateBuffer`
    /// qui n'est plus exposé proprement à Swift dans les SDK récents. Les deux
    /// attributs sont obligatoires : sans compatibilité Metal, le rendu
    /// `CIContext` → tampon repasse par le CPU.
    private func tampon(largeur: Int, hauteur: Int) -> CVPixelBuffer? {
        let taille = CGSize(width: largeur, height: hauteur)
        if taille != tailleAnneau {
            anneau.removeAll()
            tailleAnneau = taille
            indexAnneau = 0
        }

        if anneau.count < 3 {
            let attributs: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ]
            var neuf: CVPixelBuffer?
            let code = CVPixelBufferCreate(kCFAllocatorDefault,
                                           largeur, hauteur,
                                           kCVPixelFormatType_32BGRA,
                                           attributs as CFDictionary,
                                           &neuf)
            guard code == kCVReturnSuccess, let cree = neuf else { return nil }
            anneau.append(cree)
            return cree
        }

        indexAnneau = (indexAnneau + 1) % anneau.count
        return anneau[indexAnneau]
    }
}

// MARK: - Trames du viseur

extension ControleurCamera: AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Tout ce corps s'exécute sur `fileVideo`, qui est SÉRIE.

        // AUDIO — le micro et la caméra partagent ce délégué et cette file. On
        // les sépare par l'identité de la sortie, et surtout PAS par le type de
        // média du tampon : un échantillon audio n'a pas d'image, il
        // ressortirait donc par le `guard` vidéo ci-dessous, silencieusement,
        // et la vidéo serait muette sans qu'aucune erreur ne le signale.
        if output === sortieAudio {
            enregistreur?.ajouterAudio(sampleBuffer)
            return
        }

        if renduEnCours { return }
        renduEnCours = true
        defer { renduEnCours = false }

        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Nommée `emettre` et non `publier` : `publier(etat:)` existe déjà sur
        // cette classe, et une variable locale qui masque un membre est une
        // ambiguïté gratuite pour le prochain lecteur.
        guard let emettre = surTrameViseur else { return }

        let orientee = CIImage(cvPixelBuffer: source).oriented(orientationCapteur)
        let etendue = orientee.extent
        // `isInfinite` avant toute conversion en `Int` : une `CIImage` d'étendue
        // infinie donnerait `Int(CGFloat.infinity)`, qui ne renvoie pas une
        // valeur absurde mais fait TOMBER le processus. Un tampon caméra est
        // toujours fini ; cette ligne coûte une comparaison et supprime la
        // catégorie entière de panne.
        guard !etendue.isInfinite, !etendue.isNull,
              etendue.width >= 8, etendue.height >= 8 else { return }

        // ─────────────────────────────────────────────────────────────────────
        // RÉDUCTION. Seul levier autorisé entre le viseur et l'export : le moteur
        // exprime toutes ses longueurs en fraction du grand côté, donc les deux
        // rendus restent la même image à l'échelle près (voir l'en-tête).
        //
        // LANCZOS, et non plus `transformed(by: scaleX:y:)`. Ce n'est pas une
        // question de goût mais de PRÉFILTRAGE, et c'était un bug de format :
        // `transformed(by:)` échantillonne en BILINÉAIRE, donc sur une empreinte
        // de 2×2 texels, quel que soit le facteur de réduction. Ici le facteur
        // vaut min(1, 900/4032) = 0,2232, soit un pas de 4,48 px capteur entre
        // deux pixels du viseur : l'empreinte 2×2 ne couvre plus que
        // (2/4,48)² = 19,9 % de la cellule source. QUATRE pixels capteur sur cinq
        // ne contribuaient à AUCUN pixel du viseur, et lesquels dépendait de la
        // phase sous-pixel — c'est-à-dire du tremblement de la main.
        //
        // Ce que cela coûtait, mesuré sur une source ponctuelle carrée de S px
        // capteur, en balayant la phase sur une période complète (4,48 px) :
        // le T1 de `detecterPoints` (rampe 0,88 → 0,99 sur la luminance absolue)
        // oscillait de 0,00 à 1,00 pour TOUT S entre 1,7 et 6,4 px capteur —
        // c'est-à-dire sur toutes les petites sources. Les disques de l'étage C
        // s'allumaient et s'éteignaient d'une trame à l'autre. En Lanczos, dont
        // le noyau s'élargit avec la réduction, la crête devient déterministe et
        // la bande d'indécision du viseur (5,0 à 9,8 px capteur) coïncide avec
        // celle de l'export (5,2 à 10,1) au lieu de lui être disjointe.
        //
        // Le second effet est l'accord des trois cadres, et il ne s'obtient
        // qu'AVEC la normalisation de `detecterPoints` (MoteurOptique). Seuil de
        // détection, en px capteur, à t1 moyen = 0,5 :
        //   configuration                          viseur  aperçu  export  rapport
        //   bilinéaire + détection non normalisée    4,05    4,48    2,05    2,19
        //   Lanczos seul                             6,32    4,48    2,05    3,09  ← PIRE
        //   normalisation seule                      4,05    7,30    6,41    1,80
        //   Lanczos + normalisation (retenu)         6,32    7,30    6,41    1,16
        // Les deux corrections vont donc par PAIRE : Lanczos seul éloigne le
        // viseur du fichier au lieu de l'en rapprocher. Ne pas défaire l'une sans
        // l'autre.
        //
        // `clampedToExtent()` avant, recadrage après (R2 du moteur) : le support
        // de Lanczos vaut 3/0,2232 = 13,4 px source, soit 3 px de viseur, et sans
        // le clamp ces 3 px de bordure seraient assombris par le « noir
        // transparent » de l'extérieur du cadre.
        // ─────────────────────────────────────────────────────────────────────
        let facteur = min(1, Self.coteViseur / max(etendue.width, etendue.height))
        let reduite: CIImage
        if facteur > 0.999 {
            // Flux déjà plus petit que le côté de travail : rééchantillonner ne
            // ferait qu'interpoler du vide.
            reduite = orientee
        } else {
            reduite = orientee
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    "inputScale": Float(facteur),
                    "inputAspectRatio": Float(1)
                ])
                .cropped(to: CGRect(x: etendue.origin.x * facteur,
                                    y: etendue.origin.y * facteur,
                                    width: etendue.width * facteur,
                                    height: etendue.height * facteur))
        }
        let brute = reduite.extent

        // Dimensions PAIRES : prudence d'alignement de texture, et c'est gratuit.
        let largeur = max(2, Int(brute.width.rounded(.down))) & ~1
        let hauteur = max(2, Int(brute.height.rounded(.down))) & ~1
        let cadre = CGRect(x: 0, y: 0, width: CGFloat(largeur), height: CGFloat(hauteur))

        // PIÈGE : le rectangle rendu doit coïncider EXACTEMENT avec le tampon.
        // On ramène donc l'origine de l'étendue à zéro par translation, puis on
        // recadre. Un rectangle décalé ou plus grand laisse des pixels NON écrits
        // — bandes de bruit sur le bord du viseur, à chaque trame.
        let calee = reduite
            .transformed(by: CGAffineTransform(translationX: -brute.origin.x,
                                               y: -brute.origin.y))
            .cropped(to: cadre)

        verrouReglages.lock()
        let objectif = _lens
        let force = _intensite
        let outilsCourants = outilsVerrouilles
        let formatCourant = formatVerrouille
        let neutre = vueNeutreVerrouille
        verrouReglages.unlock()

        // Le moteur du studio, sans variante. `cadre` est passé explicitement :
        // un flux caméra livre parfois une étendue infinie, et tout le moteur
        // repose sur un cadre fini.
        //
        // ─────────────────────────────────────────────────────────────────────
        // POURQUOI `disquesAutorises` N'EST PAS PASSÉ À `false` ICI
        // ─────────────────────────────────────────────────────────────────────
        // La proposition revient périodiquement, et le diagnostic qui la motive
        // est JUSTE : l'étage C mesure sa porte par un `render(toBitmap:)` 1×1
        // synchrone, donc un vidage de pipeline trente fois par seconde, et le
        // graphe qu'il force (CIMorphologyMinimum r = 8,10 px, CIMorphologyMaximum
        // r = 8,10 px, CIGaussianBlur r = 45,0 px, CIAreaAverage sur
        // 674×900 = 606 600 px, soit ≈ 41,7 M lectures de texels pour les seules
        // morphologies) est ensuite RECALCULÉ par le rendu principal. Sur une
        // scène diurne c'est du travail intégralement perdu : t4 est une rampe
        // décroissante 0,42 → 0,14 sur l'ambiance locale, donc t4 = 0 partout dès
        // que l'ambiance dépasse 0,42, la carte de points est noire, et
        // `CIScreenBlendMode` avec du noir est l'identité exacte.
        //
        // Le REMÈDE, lui, est rejeté, et les trois variantes le sont pour la même
        // raison mesurée :
        //   • `false` en permanence : le viseur perd des disques qu'il montre
        //     RÉELLEMENT. Seuil de détection au viseur = 6,32 px capteur (t1 moyen
        //     0,5, phase balayée sur une période), soit une tête de lampadaire de
        //     0,30 m jusqu'à 158 m, une ampoule nue de 60 mm jusqu'à 31,6 m, une
        //     guirlande de 5 mm jusqu'à 2,6 m. Ce n'est pas un cas de coin : c'est
        //     la scène nocturne entière.
        //   • `true` une trame sur N : les disques apparaissent 2 fois par seconde
        //     et disparaissent 28 — un clignotement, pire que les deux extrêmes.
        //   • porte mémorisée : `appliquer` ne sait pas recevoir une porte déjà
        //     mesurée, donc mémoriser ne dispense d'aucun calcul. Tant que le
        //     moteur n'expose pas ce point d'entrée, il n'y a rien à mémoriser.
        //
        // Le coût réel est une latence CPU, pas une perte d'images : `fileVideo`
        // est série et `alwaysDiscardsLateVideoFrames` est posé, donc la cadence
        // se dégrade proprement. Un viseur qui ment sur le seul étage
        // spectaculaire est le défaut fondateur de l'app ; une trame plus longue
        // ne l'est pas. La bonne correction est côté moteur — supprimer la lecture
        // GPU→CPU en portant la porte comme IMAGE 1×1 étirée au cadre, ce qui est
        // arithmétiquement identique et ne vide aucun pipeline.
        // RECADRAGE AVANT LE MOTEUR. Le vignettage et les masques sont exprimés
        // en fraction du cadre : recadrer APRÈS couperait un vignettage calculé
        // pour un cadre plus large, et les coins d'un 1:1 seraient clairs alors
        // qu'ils devraient être les plus sombres du cadre.
        let recadree = OutilsPro.recadrer(calee, rapport: formatCourant.rapport)
        let cadreEffectif = recadree.extent
        let largeurUtile = max(2, Int(cadreEffectif.width.rounded(.down))) & ~1
        let hauteurUtile = max(2, Int(cadreEffectif.height.rounded(.down))) & ~1
        let cadreRendu = CGRect(x: cadreEffectif.minX, y: cadreEffectif.minY,
                                width: CGFloat(largeurUtile),
                                height: CGFloat(hauteurUtile))

        // VUE NEUTRE : la chaîne est court-circuitée, pas mise à zéro. Passer
        // une intensité nulle laisserait le graphe s'exécuter pour un résultat
        // identique — du travail GPU intégralement perdu, à trente trames par
        // seconde.
        let rendue = neutre
            ? recadree
            : MoteurOptique.appliquer(recadree,
                                      lens: objectif,
                                      intensite: force,
                                      cadre: cadreRendu)

        guard let cible = tampon(largeur: largeurUtile, hauteur: hauteurUtile) else { return }

        MoteurOptique.contexteImages.render(rendue,
                                            to: cible,
                                            bounds: cadreRendu,
                                            colorSpace: espaceViseur)

        // HISTOGRAMME — mesuré sur le rendu AFFICHÉ, jamais sur le flux brut :
        // il doit décrire l'image qu'on va enregistrer, pas celle que le capteur
        // a livrée. Un histogramme du brut annoncerait des hautes lumières que
        // le vignettage et la dérive du verre auront déplacées.
        //
        // Calculé sur `fileVideo` et non sur une file dédiée, à dessein : le
        // tampon appartient à un anneau de trois et sera réécrit sous peu. Le
        // lire depuis une autre file serait une course, et l'histogramme
        // décrirait par intermittence une trame plus récente que celle affichée.
        //
        // Une trame sur six : la mesure est un aller-retour GPU→CPU, donc un
        // vidage de pipeline. À trente par seconde elle coûterait plus que tout
        // le reste de la chaîne, pour un tracé que l'œil ne peut pas suivre.
        if outilsCourants.histogramme {
            compteurHistogramme += 1
            if compteurHistogramme % 6 == 0 {
                mesurerHistogramme(CIImage(cvPixelBuffer: cible), cadre: cadreRendu)
            }
        }

        // AIDES VISUELLES — posées sur une COPIE destinée au seul écran, et
        // après que le tampon a été écrit. Ni la photo ni la vidéo ne les
        // portent : des zébras gravés dans un fichier seraient une catastrophe
        // silencieuse, découverte des semaines plus tard.
        emettre(OutilsPro.aides(sur: CIImage(cvPixelBuffer: cible),
                                reglages: outilsCourants))

        // ENREGISTREMENT — le MÊME tampon que celui qui vient d'être affiché.
        // Aucun filtre n'est réexécuté : le fichier ne peut donc pas différer
        // du viseur, et filmer ne coûte que l'encodage.
        //
        // L'horodatage vient du tampon d'origine, jamais d'une horloge lue ici :
        // c'est lui qui porte la cadence réelle du capteur, y compris quand une
        // trame a été jetée par `alwaysDiscardsLateVideoFrames`. Une horloge
        // locale produirait une vidéo qui accélère dès que le rendu prend du
        // retard.
        if let enregistreur {
            let instant = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            enregistreur.ajouterVideo(cible, a: instant)
            if let debut = debutEnregistrement {
                let ecoulees = Int(CMTimeGetSeconds(CMTimeSubtract(instant, debut)))
                if ecoulees != secondesPubliees {
                    secondesPubliees = ecoulees
                    DispatchQueue.main.async { [weak self] in
                        self?.secondesEnregistrees = max(0, ecoulees)
                    }
                }
            } else {
                debutEnregistrement = instant
            }
        }

        if !premiereTrameSignalee {
            premiereTrameSignalee = true
            DispatchQueue.main.async { [weak self] in
                self?.premiereTrameRecue = true
            }
        }
    }
}

// MARK: - Capture photo

extension ControleurCamera: AVCapturePhotoCaptureDelegate {

    /// Sans profondeur ni RAW, une seule photo arrive : tout le travail tient
    /// ici, et `photoOutput(_:didFinishCaptureFor:error:)` devient inutile. C'est
    /// une simplification directe de la réduction du périmètre.
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {

        // Un échec de capture doit être VISIBLE. L'ancienne app avait un cas où
        // le déclencheur « capturait » sans que rien n'arrive dans Photos, en
        // silence complet.
        if error != nil {
            terminerCapture(.echec)
            return
        }
        guard let donnees = photo.fileDataRepresentation() else {
            terminerCapture(.echec)
            return
        }

        let objectif = lens
        let force = intensite
        // Cadrage et vue neutre lus SOUS VERROU, comme au viseur : ce sont les
        // mêmes réglages, et la photo doit sortir dans le format que
        // l'utilisateur voyait au moment du déclenchement.
        verrouReglages.lock()
        let rapportCourant = formatVerrouille.rapport
        let neutreCourant = vueNeutreVerrouille
        verrouReglages.unlock()

        // `fileCapture`, surtout pas `fileVideo` : un rendu à 3200 px prend
        // plusieurs centaines de millisecondes et gèlerait le viseur pendant
        // toute la durée du développement.
        fileCapture.async { [weak self] in
            guard let self else { return }

            let developpee = MoteurOptique.rendre(donnees: donnees,
                                                  lens: objectif,
                                                  intensite: force,
                                                  coteMax: MoteurOptique.coteExport,
                                                  rapport: rapportCourant,
                                                  neutre: neutreCourant)

            // FILET DE DERNIER RECOURS : si le développement échoue de bout en
            // bout, on enregistre les octets d'origine plutôt que rien. On ne
            // perd JAMAIS une prise de vue.
            let jpeg = developpee?.jpegData(compressionQuality: 0.92) ?? donnees
            self.enregistrer(jpeg: jpeg)
        }
    }
}
