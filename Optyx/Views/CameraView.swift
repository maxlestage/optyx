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
                MetalPreviewView(renderer: camera.previewRenderer)
                    .ignoresSafeArea(edges: .top)
                if !camera.hasFrame {
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
                if camera.rawSupported || camera.depthAvailable {
                    HStack(spacing: 8) {
                        Spacer()
                        if camera.depthAvailable { depthToggle }
                        if camera.rawSupported { rawToggle }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
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

    /// Active le bokeh guidé par la profondeur en direct (LiDAR / double
    /// capteur) : le tourbillon ne touche que l'arrière-plan réel.
    private var depthToggle: some View {
        Button {
            camera.depthEnabled.toggle()
        } label: {
            Label("Profondeur", systemImage: "person.and.background.dotted")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.depthEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.depthEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    /// Active la capture DNG : le fichier RAW original (ProRAW si disponible)
    /// est joint à la photo vintage enregistrée dans Photos.
    private var rawToggle: some View {
        Button {
            camera.rawEnabled.toggle()
        } label: {
            Text(camera.isProRAW ? "ProRAW" : "RAW")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.rawEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.rawEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
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

            if camera.rawEnabled {
                Text("DNG original + rendu vintage enregistrés dans Photos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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
