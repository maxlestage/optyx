import SwiftUI
import UIKit

/// Vue racine : deux onglets, rien de plus.
///
/// Le périmètre est délibérément resserré (catalogue + studio photo). La version
/// précédente de l'app empilait caméra temps réel, vidéo, profondeur et RAW, et
/// s'est noyée dans cette ampleur. Deux onglets, c'est aussi une promesse tenue
/// vis-à-vis de l'utilisateur : ce qu'il voit animé dans le catalogue est
/// exactement ce que le studio appliquera à sa photo, puisque les deux partagent
/// le même profil de disque de bokeh.
struct RootView: View {
    /// Sélection typée plutôt qu'un `Int`. Un index nu se décale silencieusement
    /// dès qu'on réordonne les onglets ; un cas d'énumération casse à la
    /// compilation, ce qui est exactement ce qu'on veut d'un compilateur.
    private enum Onglet: Hashable {
        case objectifs
        case studio
    }

    @State private var onglet: Onglet = .objectifs

    init() {
        // SwiftUI seul ne suffit pas à noircir la barre d'onglets de façon
        // fiable : sans apparence explicite, iOS applique un matériau translucide
        // qui laisse remonter un gris laiteux sous les scènes de bokeh, et le
        // fond « noir » de la page cesse d'être noir au ras de la barre. On règle
        // donc le proxy UIKit une fois pour toutes.
        let apparence = UITabBarAppearance()
        apparence.configureWithOpaqueBackground()
        apparence.backgroundColor = .black
        // Le filet de séparation par défaut dessine une ligne claire d'un pixel
        // en haut de la barre ; sur fond noir elle se voit plus que tout le reste.
        apparence.shadowColor = .clear

        UITabBar.appearance().standardAppearance = apparence
        // `scrollEdgeAppearance` couvre le cas où le contenu de l'onglet est
        // arrivé en bout de défilement : sans elle, la barre redevient
        // translucide à ce moment précis et l'utilisateur voit le fond changer.
        UITabBar.appearance().scrollEdgeAppearance = apparence
    }

    var body: some View {
        TabView(selection: $onglet) {
            CatalogView()
                .tag(Onglet.objectifs)
                .tabItem {
                    Label("Objectifs", systemImage: "camera.aperture")
                }

            StudioView()
                .tag(Onglet.studio)
                .tabItem {
                    // « photo.on.rectangle.angled » existe depuis iOS 16 ; on
                    // s'en tient aux symboles anciens, un nom absent se rend en
                    // carré vide sans jamais échouer à la compilation.
                    Label("Studio", systemImage: "photo.on.rectangle.angled")
                }
        }
        // Teinte de sélection globale. On garde l'orange de la marque ici plutôt
        // que l'accent de l'objectif courant : voir la barre d'onglets changer de
        // couleur à chaque carte parcourue transformerait le châssis de l'app en
        // élément mouvant, alors qu'il doit rester le repère stable.
        .tint(Theme.Couleur.orange)
        // Filet de sécurité sous la hiérarchie : si un onglet rend un contenu
        // plus court que l'écran, on veut du noir dessous, pas le gris système.
        .background(Theme.Couleur.fond.ignoresSafeArea())
    }
}
