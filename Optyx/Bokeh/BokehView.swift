import MetalKit
import SwiftUI

// Pont SwiftUI ↔ Metal pour les scènes de bokeh.
//
// Ce fichier ne contient AUCUNE logique de rendu : tout le dessin vit dans
// BokehRenderer et BokehShaders.metal. Ceux-ci servent au CATALOGUE seul — le
// studio part d'une photo et passe par Core Image ; ce qui relie les deux, ce
// sont les paramètres de BokehParams, pas le shader (voir l'en-tête de
// BokehRenderer). Un pont qui « arrangerait » un peu l'image ici (un flou
// SwiftUI par dessus, une opacité différente ici et là) creuserait donc un
// écart que RIEN ne rattraperait côté studio, et ramènerait le reproche
// fondateur : « ce n'est pas comme le site ».
//
// Règle de survie de ce fichier : pas un seul `!`. Une scène décorative qui
// fait planter l'app au lancement sur un appareil sans Metal est infiniment
// pire qu'une scène absente.

/// Scène de bokeh animée, rendue par Metal.
///
/// `UIViewType` est `MTKView` y compris dans le cas dégradé : un
/// `UIViewRepresentable` n'a qu'un seul type de vue possible, et enrober la
/// MTKView dans un conteneur juste pour pouvoir renvoyer un `UIView` nu
/// ajouterait une couche de contraintes à tenir pour rien. Une MTKView sans
/// device ne dessine jamais rien — c'est déjà, littéralement, une vue noire.
struct BokehView: UIViewRepresentable {

    /// L'objectif dont on rend la signature. Le changer ne recrée pas la vue :
    /// `updateUIView` le transmet au renderer, qui fait le fondu de palette.
    let lens: Lens

    /// Metal est-il utilisable sur cet appareil ?
    ///
    /// Évalué une seule fois : `MTLCreateSystemDefaultDevice()` renvoie le
    /// device partagé du système, l'appeler en boucle depuis `body` (donc
    /// potentiellement à chaque frame de SwiftUI) serait du gaspillage pur.
    /// Renvoie nil sur les simulateurs anciens et sur les cibles sans GPU
    /// Metal ; c'est le seul test fiable, un `#if targetEnvironment(simulator)`
    /// serait à la fois trop large et trop étroit.
    static let metalDisponible: Bool = MTLCreateSystemDefaultDevice() != nil

    /// Le Coordinator est le SEUL propriétaire du renderer.
    ///
    /// `MTKView.delegate` est une référence faible : si personne d'autre ne
    /// retient le renderer, il est désalloué aussitôt après `makeUIView` et la
    /// scène reste noire sans la moindre erreur. C'est le piège classique de
    /// MetalKit, et la raison d'être de cette classe.
    final class Coordinator {
        var renderer: BokehRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        // Sans device, on renvoie une MTKView inerte plutôt que de propager un
        // optionnel : l'app doit démarrer, quitte à afficher un cadre noir.
        guard let device = MTLCreateSystemDefaultDevice() else {
            return Self.vueInerte()
        }

        let vue = MTKView(frame: .zero, device: device)

        // `backgroundColor` est le SEUL réglage d'apparence posé ici, parce
        // qu'il agit avant tout rendu Metal : il couvre l'instant entre l'ajout
        // de la vue à la hiérarchie et le premier drawable, y compris dans le
        // cas dégradé ci-dessous où le renderer ne verra jamais cette vue.
        vue.backgroundColor = .black

        // Tout le reste de la configuration Metal — clearColor, isOpaque,
        // framebufferOnly, cadence, colorPixelFormat, depthStencilPixelFormat,
        // sampleCount — est posé par `BokehRenderer.preparer(_:)`, seule source
        // de vérité, et le doubler ici ferait deux endroits à corriger.
        //
        // Ce n'est pas une préférence de style : le pipeline code ses formats EN
        // DUR (bgra8Unorm, un seul échantillon, aucune profondeur) et ne
        // consulte JAMAIS la vue. Régler l'apparence depuis la vue ferait donc
        // diverger la vue du pipeline, et cette divergence ne se signale ni à la
        // compilation ni par un avertissement : `makeRenderCommandEncoder` lève
        // une assertion Metal à la première trame. Aujourd'hui les défauts de
        // MTKView coïncident par chance avec le pipeline ; le jour où quelqu'un
        // pose `sampleCount = 4` ici, l'app plante à l'ouverture du catalogue.
        guard let renderer = Self.creerRenderer(vue: vue, lens: lens) else {
            // Le renderer n'a pas pu se construire (bibliothèque Metal
            // introuvable, pipeline refusé). On neutralise le display link
            // plutôt que de laisser une vue tourner à 60 Hz pour effacer du
            // noir soixante fois par seconde.
            vue.isPaused = true
            return vue
        }

        // Le Coordinator est ce qui RETIENT le renderer : `MTKView.delegate` est
        // une référence faible, et sans cette ligne le renderer serait désalloué
        // à la sortie de `makeUIView`, laissant une scène noire sans erreur.
        context.coordinator.renderer = renderer
        // `preparer` a déjà posé ce delegate. On le repose quand même : c'est la
        // seule ligne dupliquée qu'on garde, parce qu'elle ne peut pas DIVERGER
        // (même objet, même valeur) alors que la perdre rendrait la scène noire.
        vue.delegate = renderer
        return vue
    }

    func updateUIView(_ vue: MTKView, context: Context) {
        // Simple affectation : c'est le renderer qui détecte le changement
        // d'objectif et lance le fondu de palette. Surtout ne pas recréer le
        // renderer ici — on perdrait le champ de particules, et le passage
        // d'un objectif à l'autre deviendrait une coupure au lieu d'un
        // fondu.
        context.coordinator.renderer?.lens = lens
    }

    static func dismantleUIView(_ vue: MTKView, coordinator: Coordinator) {
        // Une MTKView retirée de la hiérarchie garde son CADisplayLink actif :
        // en quittant le catalogue, chaque scène abandonnée continuerait de
        // consommer du GPU. On coupe explicitement, puis on lâche le renderer
        // pour que ses buffers soient libérés tout de suite.
        vue.isPaused = true
        vue.delegate = nil
        coordinator.renderer = nil
    }

    /// Vue noire sans device, pour le cas où Metal est absent.
    private static func vueInerte() -> MTKView {
        let vue = MTKView(frame: .zero, device: nil)
        vue.backgroundColor = .black
        vue.isOpaque = true
        vue.isPaused = true
        vue.enableSetNeedsDisplay = false
        return vue
    }

    /// UNIQUE point de couplage avec `BokehRenderer`.
    ///
    /// Isolé dans une fonction pour que l'adaptation à la signature réelle du
    /// renderer tienne en une ligne, sans toucher au reste du pont.
    /// L'initialiseur est faillible par contrat : tout ce qui peut manquer
    /// (bibliothèque Metal, fonctions de shader, état de pipeline) doit
    /// donner nil, jamais une exception ni un `!`.
    private static func creerRenderer(vue: MTKView, lens: Lens) -> BokehRenderer? {
        // Le device de la vue est celui qui a servi à la créer dans makeUIView ;
        // en reprendre un autre construirait un pipeline étranger à la cible.
        guard let device = vue.device,
              let renderer = BokehRenderer(device: device, lens: lens)
        else { return nil }
        // `preparer` aligne la vue sur les formats du pipeline (bgra8Unorm, pas
        // de profondeur, un seul échantillon) : un désaccord ne se signale pas à
        // la compilation, il fait échouer la création de l'encodeur à la trame.
        renderer.preparer(vue)
        return renderer
    }
}

/// Repli SwiftUI pur, sans Metal.
///
/// Ce n'est PAS une imitation du bokeh — prétendre rendre la signature d'un
/// objectif avec un dégradé serait mentir à l'utilisateur sur ce qu'il
/// obtiendra. C'est un fond teinté par l'accent de l'objectif, qui garde à la
/// carte sa couleur et sa lisibilité quand le GPU n'est pas disponible.
struct BokehFallbackView: View {

    let lens: Lens

    var body: some View {
        GeometryReader { geo in
            let cote = max(geo.size.width, geo.size.height)

            ZStack {
                Color.black

                // Halo central : les deux teintes viennent de l'objectif
                // lui-même (accent, puis première couleur de palette), pour
                // que le repli reste reconnaissable d'une fiche à l'autre.
                // Opacités volontairement basses : le titre et les métadonnées
                // se posent par-dessus et doivent rester lisibles.
                RadialGradient(
                    colors: [
                        Color(hex: lens.accent, opacity: 0.34),
                        Color(hex: lens.palette.first ?? lens.accent, opacity: 0.14),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: cote * 0.58
                )
            }
        }
        // Purement décoratif : annoncé aucune fois à VoiceOver, qui lit déjà
        // le nom de l'objectif juste à côté.
        .accessibilityHidden(true)
    }
}

/// Scène de bokeh à poser dans l'interface : Metal si possible, repli sinon.
///
/// Les vues du catalogue et du studio passent par ici et n'ont jamais à
/// interroger la disponibilité de Metal elles-mêmes — un seul endroit décide,
/// donc un seul endroit à corriger.
struct BokehCanevas: View {

    let lens: Lens

    var body: some View {
        if BokehView.metalDisponible {
            BokehView(lens: lens)
        } else {
            BokehFallbackView(lens: lens)
        }
    }
}
