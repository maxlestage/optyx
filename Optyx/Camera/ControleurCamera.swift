import AVFoundation
import CoreImage
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

extension ControleurCamera: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Tout ce corps s'exécute sur `fileVideo`, qui est SÉRIE.
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

        // RÉDUCTION. Seul levier autorisé entre le viseur et l'export : le moteur
        // exprime toutes ses longueurs en fraction du grand côté, donc les deux
        // rendus restent la même image à l'échelle près (voir l'en-tête).
        let facteur = min(1, Self.coteViseur / max(etendue.width, etendue.height))
        let reduite = orientee.transformed(by: CGAffineTransform(scaleX: facteur, y: facteur))
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
        verrouReglages.unlock()

        // Le moteur du studio, sans variante. `cadre` est passé explicitement :
        // un flux caméra livre parfois une étendue infinie, et tout le moteur
        // repose sur un cadre fini.
        let rendue = MoteurOptique.appliquer(calee,
                                             lens: objectif,
                                             intensite: force,
                                             cadre: cadre)

        guard let cible = tampon(largeur: largeur, hauteur: hauteur) else { return }

        MoteurOptique.contexteImages.render(rendue,
                                            to: cible,
                                            bounds: cadre,
                                            colorSpace: espaceViseur)

        emettre(CIImage(cvPixelBuffer: cible))

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

        // `fileCapture`, surtout pas `fileVideo` : un rendu à 3200 px prend
        // plusieurs centaines de millisecondes et gèlerait le viseur pendant
        // toute la durée du développement.
        fileCapture.async { [weak self] in
            guard let self else { return }

            let developpee = MoteurOptique.rendre(donnees: donnees,
                                                  lens: objectif,
                                                  intensite: force,
                                                  coteMax: MoteurOptique.coteExport)

            // FILET DE DERNIER RECOURS : si le développement échoue de bout en
            // bout, on enregistre les octets d'origine plutôt que rien. On ne
            // perd JAMAIS une prise de vue.
            let jpeg = developpee?.jpegData(compressionQuality: 0.92) ?? donnees
            self.enregistrer(jpeg: jpeg)
        }
    }
}
