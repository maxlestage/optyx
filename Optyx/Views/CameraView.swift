import SwiftUI

/// Viseur : flux caméra filtré en direct par l'objectif sélectionné.
struct CameraView: View {
    @StateObject private var camera = CameraController()
    @State private var lens: LensProfile = .catalog[1]
    @State private var intensity: Double = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .running, .idle:
                if let frame = camera.previewFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea(edges: .top)
                } else {
                    ProgressView("Démarrage de la caméra…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            case .denied:
                permissionMessage(
                    "Accès caméra refusé",
                    "Autorisez la caméra dans Réglages → Optyx pour utiliser le viseur vintage."
                )
            case .unavailable:
                permissionMessage(
                    "Caméra indisponible",
                    "Aucune caméra détectée (le simulateur n'en a pas). L'onglet Studio fonctionne avec vos photos."
                )
            }

            VStack {
                Spacer()
                controls
            }

            if camera.lastCaptureSaved {
                Label("Enregistrée dans Photos", systemImage: "checkmark.circle.fill")
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: camera.lastCaptureSaved)
        .onAppear {
            camera.lens = lens
            camera.intensity = intensity
            camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: lens) { _, newValue in camera.lens = newValue }
        .onChange(of: intensity) { _, newValue in camera.intensity = newValue }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            LensChipBar(selected: $lens)

            HStack(spacing: 12) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Slider(value: $intensity, in: 0...1)
                    .tint(.orange)
                Text("\(Int(intensity * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal)

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                    Circle().fill(.white).frame(width: 58, height: 58)
                }
            }
            .buttonStyle(.plain)
            .disabled(camera.status != .running)
            .padding(.bottom, 6)
        }
        .padding(.vertical, 12)
        .background(.black.opacity(0.35))
    }

    private func permissionMessage(_ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
