import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            CameraView()
                .tabItem { Label("Caméra", systemImage: "camera.fill") }

            EditorView()
                .tabItem { Label("Studio", systemImage: "photo.on.rectangle.angled") }

            LensCatalogView()
                .tabItem { Label("Objectifs", systemImage: "camera.aperture") }
        }
        .tint(.orange)
    }
}

#Preview {
    ContentView()
}
