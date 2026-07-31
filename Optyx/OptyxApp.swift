import SwiftUI

/// Point d'entrée de l'application.
///
/// Le fichier est volontairement minuscule : toute la composition vit dans
/// `RootView`. Un `App` maigre reste testable dans les aperçus SwiftUI, alors
/// qu'un `App` qui construit des états ou des services au démarrage ne l'est pas.
@main
struct OptyxApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // Le catalogue est conçu autour de points lumineux sur fond
                // sombre : c'est la scène qui porte la signature de l'objectif.
                // En clair, les disques de bokeh se noieraient dans le blanc et
                // toute la démonstration s'effondrerait. On force donc le sombre
                // pour l'app entière au lieu de le subir depuis les réglages
                // système.
                .preferredColorScheme(.dark)
        }
    }
}
