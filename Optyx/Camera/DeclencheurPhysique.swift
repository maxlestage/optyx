import AVKit
import SwiftUI
import UIKit

/// Déclencheur MATÉRIEL : boutons de volume et bouton Commande de l'appareil
/// photo, exactement comme dans l'app Appareil photo d'Apple.
///
/// POURQUOI UN FICHIER À PART plutôt qu'une ligne dans `VueApercu` : celui-ci
/// porte une règle explicite — il ne connaît ni `Lens`, ni `MoteurOptique`, ni
/// AVFoundation, et ne fait que recopier une image déjà rendue. Y importer
/// AVFoundation pour trois lignes ouvrirait précisément la porte que ce
/// commentaire ferme. Ici, la dépendance est isolée dans un composant qui n'a
/// pas d'autre raison d'être.
///
/// `AVCaptureEventInteraction` (iOS 17.2+) ne capte les boutons que lorsqu'une
/// session de capture tourne au premier plan. Ailleurs dans l'app — au
/// catalogue, au studio — les boutons de volume gardent leur comportement
/// normal, sans qu'on ait à les désarmer nous-mêmes.
///
/// La vue est TRANSPARENTE et ne reçoit aucun toucher : elle se superpose au
/// viseur sans rien intercepter. Elle n'existe que pour porter l'interaction,
/// qui a besoin d'une `UIView` vivante dans la hiérarchie.
struct DeclencheurPhysique: UIViewRepresentable {

    /// Appelée sur le fil principal, à la RELÂCHE du bouton.
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let vue = PasseTout()
        vue.backgroundColor = .clear
        vue.isOpaque = false

        guard #available(iOS 17.2, *) else { return vue }

        // La fermeture est prise sur le coordinateur et non capturée
        // directement : SwiftUI reconstruit `DeclencheurPhysique` à chaque
        // rafraîchissement du corps parent, et une fermeture capturée figerait
        // la version du premier rendu — le déclencheur appellerait alors un
        // état périmé, symptôme classique et parfaitement silencieux.
        let coordinateur = context.coordinator
        let interaction = AVCaptureEventInteraction { evenement in
            // `.ended` seulement : sans ce filtre, un appui déclenche DEUX fois
            // (une à l'enfoncement, une au relâchement).
            guard evenement.phase == .ended else { return }
            coordinateur.action()
        }
        vue.addInteraction(interaction)
        return vue
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinateur {
        Coordinateur(action: action)
    }

    final class Coordinateur {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }

    /// `UIView` qui ne se laisse jamais désigner par un toucher : le viseur et
    /// les commandes qu'elle recouvre restent pleinement utilisables.
    private final class PasseTout: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
