import CoreImage
import MetalKit
import SwiftUI
import UIKit

// Pont d'affichage du viseur : Metal ↔ SwiftUI.
//
// CE FICHIER NE FILTRE RIEN. Il ne connaît ni `Lens`, ni `MoteurOptique`, ni
// AVFoundation. Il reçoit une image DÉJÀ rendue — un simple enrobage de pixel
// buffer publié par le contrôleur caméra — et la recopie vers le drawable.
//
// C'est une règle de survie, pas une préférence d'architecture : le jour où ce
// fichier se met à « arranger » un peu l'image (un flou de plus ici, une
// saturation là), le viseur cesse de montrer ce que le fichier enregistré
// contiendra, et le reproche fondateur revient — « ce n'est pas ce que je
// voyais ». Une seule chaîne d'effets existe, elle vit dans `MoteurOptique`, et
// le viseur comme l'export y passent.
//
// Seconde règle : pas un seul `!`. Sur un appareil sans Metal (simulateurs
// anciens), la vue reste noire et l'app démarre. Un viseur absent est infiniment
// préférable à une app qui plante à l'ouverture de l'onglet.

// MARK: - Renderer

/// Recopie vers l'écran la dernière trame filtrée publiée par la caméra.
///
/// Le contrôleur caméra détient une instance de cette classe et l'alimente par
/// `publier(_:)` depuis sa file vidéo ; la vue SwiftUI, elle, ne fait que la
/// brancher sur une `MTKView`. Aucune des deux n'a besoin de connaître l'autre.
///
/// **Cadence.** La `MTKView` est en `isPaused = true` + `enableSetNeedsDisplay
/// = true` : l'affichage est PILOTÉ par l'arrivée des trames, exactement un
/// dessin par trame publiée. C'est ce qui remplace la boucle libre à 120 Hz de
/// l'ancienne app, qui devait ensuite s'empêcher de redessiner (compteur de
/// génération) pour ne pas re-recopier un buffer en cours de réécriture par
/// l'anneau — d'où le scintillement périodique qu'elle documentait. Ici le
/// problème n'est pas rustiné, il n'existe pas.
/// **`ObservableObject` sans le moindre `@Published`, à dessein.** La conformité
/// ne sert qu'à permettre à la vue de le détenir dans un `@StateObject`, donc de
/// n'en construire QU'UNE instance pour toute la durée de l'écran. Publier quoi
/// que ce soit ici invaliderait le corps SwiftUI trente fois par seconde, et
/// c'est exactement le coût qu'on cherche à éviter en passant par Metal.
final class RenduViseur: NSObject, MTKViewDelegate, ObservableObject {

    /// Metal est-il utilisable sur cet appareil ? Évalué une seule fois, comme
    /// dans `BokehView` : `MTLCreateSystemDefaultDevice()` renvoie le device
    /// partagé du système, l'appeler depuis `body` serait du gaspillage pur.
    static let metalDisponible: Bool = MTLCreateSystemDefaultDevice() != nil

    /// Device utilisé pour construire la `MTKView`. Nil = pas de Metal.
    let device: MTLDevice?

    private let fileCommandes: MTLCommandQueue?
    private let contexte: CIContext?

    /// Espace de sortie du blit. sRGB explicite, jamais l'espace de travail par
    /// défaut : le studio exporte en sRGB, et un viseur rendu dans un autre
    /// espace afficherait des couleurs que le fichier n'aura pas.
    private let espaceSortie: CGColorSpace

    /// Dernière trame publiée. Protégée par un verrou parce qu'elle est écrite
    /// depuis la file vidéo de la caméra et lue depuis le fil principal.
    private let verrou = NSLock()
    private var derniereImage: CIImage?

    /// Vue à réveiller quand une trame arrive. Référence FAIBLE (la vue est
    /// détenue par la hiérarchie UIKit) et touchée UNIQUEMENT sur le fil
    /// principal — c'est la raison du saut par `DispatchQueue.main.async` dans
    /// `publier(_:)`, et non une précaution décorative.
    private weak var vue: MTKView?

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        let file = device?.makeCommandQueue()
        self.fileCommandes = file
        // Contexte adossé à la MÊME file de commandes que le blit : c'est ce
        // qui permet à Core Image d'encoder son travail dans notre command
        // buffer plutôt que d'en ouvrir un second, et donc de rester sur le GPU
        // sans aller-retour. `cacheIntermediates: false` parce qu'à 30 trames
        // par seconde le cache d'intermédiaires ne resservira jamais : il ne
        // ferait que gonfler la mémoire.
        if let file {
            self.contexte = CIContext(mtlCommandQueue: file,
                                      options: [.cacheIntermediates: false])
        } else {
            self.contexte = nil
        }
        self.espaceSortie = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        super.init()
    }

    /// Vrai si le blit peut réellement s'exécuter sur cet appareil.
    var estOperationnel: Bool {
        contexte != nil && fileCommandes != nil && device != nil
    }

    // MARK: Alimentation

    /// Publie une trame déjà filtrée. Appelable depuis n'importe quelle file.
    ///
    /// L'argument doit être une image PRÊTE (typiquement
    /// `CIImage(cvPixelBuffer:)` sur le buffer que la caméra vient de rendre),
    /// pas une recette de filtres : le graphe s'exécuterait alors sur le fil
    /// principal, à chaque trame, et la barre d'objectifs se mettrait à
    /// saccader.
    func publier(_ image: CIImage) {
        verrou.lock()
        derniereImage = image
        verrou.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.vue?.setNeedsDisplay()
        }
    }

    /// Oublie la dernière trame et repasse au noir. À appeler à l'arrêt de la
    /// session : sans cela, revenir sur l'onglet afficherait pendant une
    /// fraction de seconde l'image figée de la fois précédente.
    func vider() {
        verrou.lock()
        derniereImage = nil
        verrou.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.vue?.setNeedsDisplay()
        }
    }

    /// Associe la vue à réveiller. Appelé sur le fil principal par le pont
    /// SwiftUI, jamais par la caméra.
    func attacher(_ nouvelle: MTKView?) {
        vue = nouvelle
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Rien à recalculer : le cadrage est refait à chaque dessin à partir de
        // la taille du drawable. MetalKit demande de lui-même un redessin après
        // ce changement quand `enableSetNeedsDisplay` est actif.
    }

    func draw(in view: MTKView) {
        guard let contexte, let fileCommandes else { return }

        verrou.lock()
        let courante = derniereImage
        verrou.unlock()

        let taille = view.drawableSize
        guard taille.width > 0, taille.height > 0 else { return }
        guard let drawable = view.currentDrawable,
              let tampon = fileCommandes.makeCommandBuffer()
        else { return }

        let cadre = CGRect(origin: .zero, size: taille)

        // Le fond noir est COMPOSÉ dans l'image, il n'est pas laissé à la
        // couleur d'effacement de la vue : `CIContext.render(_:to:…)` n'écrit
        // que les pixels couverts par l'image, et les bandes du cadrage
        // aspect-fit garderaient sinon le contenu de la trame précédente — des
        // bordures fantômes qui bougent à chaque rotation.
        //
        // Composition par `composited(over:)` sur un noir OPAQUE : jamais une
        // addition. Additionner deux images dont l'alpha vaut 1 porterait
        // l'alpha à 2 et le rendu prémultiplié diviserait les couleurs — c'est
        // exactement le bug qui a produit des images entièrement noires.
        let fond = CIImage(color: .black).cropped(to: cadre)
        let composee: CIImage
        if let courante, !courante.extent.isEmpty, courante.extent.isInfinite == false {
            composee = Self.ajuster(courante, dans: cadre).composited(over: fond)
        } else {
            composee = fond
        }

        contexte.render(composee,
                        to: drawable.texture,
                        commandBuffer: tampon,
                        bounds: cadre,
                        colorSpace: espaceSortie)
        tampon.present(drawable)
        tampon.commit()
    }

    /// Cadrage « aspect-fit » centré : l'image entière est visible, jamais
    /// rognée. Rogner pour remplir l'écran mentirait sur le cadrage — la photo
    /// enregistrée contiendrait des bords que le viseur n'a jamais montrés.
    private static func ajuster(_ image: CIImage, dans cadre: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }

        let echelle = min(cadre.width / source.width, cadre.height / source.height)
        let mise = image.transformed(by: CGAffineTransform(scaleX: echelle, y: echelle))
        // Le décalage se calcule sur l'extent APRÈS mise à l'échelle : une
        // image dont l'origine n'est pas à zéro (recadrage amont) serait sinon
        // centrée de travers.
        let dx = (cadre.width - mise.extent.width) / 2 - mise.extent.minX
        let dy = (cadre.height - mise.extent.height) / 2 - mise.extent.minY
        return mise.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}

// MARK: - Pont SwiftUI

/// Le viseur, à poser plein cadre dans l'écran de prise de vue.
///
/// `UIViewType` est `MTKView` y compris dans le cas dégradé, pour la même
/// raison que `BokehView` : un `UIViewRepresentable` n'a qu'un seul type de
/// vue, et une `MTKView` sans device ne dessine jamais rien — c'est déjà,
/// littéralement, une vue noire.
struct VueApercu: UIViewRepresentable {

    /// Le renderer est détenu par le contrôleur caméra, qui vit plus longtemps
    /// que cette vue. On ne le crée donc PAS ici : le recréer à chaque
    /// reconstruction du corps SwiftUI couperait le lien avec la caméra et
    /// laisserait un écran noir sans la moindre erreur.
    let rendu: RenduViseur

    func makeUIView(context: Context) -> MTKView {
        // Sans device on renvoie une vue inerte plutôt que de propager un
        // optionnel : l'onglet doit s'ouvrir, quitte à afficher un cadre noir,
        // et `VueCamera` affiche par-dessus un message explicite.
        guard let device = rendu.device else {
            return Self.vueInerte()
        }

        let vue = MTKView(frame: .zero, device: device)
        vue.delegate = rendu
        // OBLIGATOIRE : sans cela, `CIContext.render(_:to: drawable.texture, …)`
        // ne peut pas écrire dans la texture et le viseur reste noir.
        vue.framebufferOnly = false
        vue.colorPixelFormat = .bgra8Unorm
        // Affichage piloté par l'arrivée des trames : aucun dessin à vide, donc
        // aucune consommation quand la session est arrêtée.
        vue.isPaused = true
        vue.enableSetNeedsDisplay = true
        vue.backgroundColor = .black
        vue.isOpaque = true
        vue.clearColor = MTLClearColorMake(0, 0, 0, 1)
        // Le viseur est une image, pas un contrôle : VoiceOver n'a rien à
        // annoncer ici, l'état est décrit par les commandes qui l'entourent.
        vue.isUserInteractionEnabled = false

        rendu.attacher(vue)
        return vue
    }

    func updateUIView(_ vue: MTKView, context: Context) {
        // Le lien vue ↔ renderer est reposé à chaque mise à jour : c'est la
        // seule ligne redondante qu'on garde, parce qu'elle ne peut pas
        // DIVERGER (même objet, même valeur) alors que la perdre — après une
        // recréation de vue par SwiftUI — rendrait le viseur définitivement
        // noir.
        vue.delegate = rendu
        rendu.attacher(vue)
    }

    static func dismantleUIView(_ vue: MTKView, coordinator: Void) {
        // On coupe le lien dans les deux sens : une vue retirée de la
        // hiérarchie ne doit plus être réveillée par les trames qui continuent
        // d'arriver le temps que la session s'arrête.
        vue.delegate = nil
        vue.isPaused = true
    }

    private static func vueInerte() -> MTKView {
        let vue = MTKView(frame: .zero, device: nil)
        vue.backgroundColor = .black
        vue.isOpaque = true
        vue.isPaused = true
        vue.enableSetNeedsDisplay = false
        vue.isUserInteractionEnabled = false
        return vue
    }
}
