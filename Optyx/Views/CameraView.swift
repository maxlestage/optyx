import SwiftUI

/// Viseur : flux caméra filtré en direct par l'objectif sélectionné.
struct CameraView: View {
    @StateObject private var camera = CameraController()
    @State private var lens: LensProfile = .catalog[1]
    @State private var intensity: Double = 1.0
    /// Zoom au début du pincement en cours.
    @State private var pinchBaseZoom: CGFloat = 1

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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if camera.isRecording { recordingChip }
                        flipButton
                        if camera.zoomFactor > 1.05 { zoomChip }
                        aeafToggle
                        if camera.mode == .video { fourKToggle }
                        if camera.mode == .video { hdrToggle }
                        if camera.mode == .video { cineToggle }
                        if camera.mode == .video { letterboxToggle }
                        if camera.depthAvailable { depthToggle }
                        if camera.mode == .photo { formatMenu }
                        if camera.rawSupported && camera.mode == .photo { rawToggle }
                        histogramToggle
                        zebraToggle
                        peakingToggle
                        gridToggle
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 4)

                if camera.histogramEnabled, let histogram = camera.histogram {
                    HStack {
                        HistogramView(data: histogram)
                            .frame(width: 132, height: 64)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)
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
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    camera.setZoom(pinchBaseZoom * value)
                }
                .onEnded { _ in
                    pinchBaseZoom = camera.zoomFactor
                }
        )
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

    /// Mode cinéma : capteur calé à 24 images par seconde.
    private var cineToggle: some View {
        Button {
            camera.toggleCineMode()
        } label: {
            Label("24 i/s", systemImage: "film")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.cineMode
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.cineMode ? .black : .white)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    /// Affiche/masque l'histogramme temps réel.
    private var histogramToggle: some View {
        Button {
            camera.histogramEnabled.toggle()
        } label: {
            Image(systemName: "chart.bar.fill")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.histogramEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.histogramEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    /// Zébras : hachures sur les zones surexposées (viseur uniquement).
    private var zebraToggle: some View {
        Button {
            camera.zebrasEnabled.toggle()
        } label: {
            Text("Zébras")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.zebrasEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.zebrasEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    /// Focus peaking : contours nets surlignés en vert (viseur uniquement).
    private var peakingToggle: some View {
        Button {
            camera.peakingEnabled.toggle()
        } label: {
            Text("Peaking")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.peakingEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.peakingEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    /// Formats de cadrage photo : 4:3 natif, 3:2 film 135, 1:1 (6×6),
    /// 16:9 et 65:24 (XPan).
    private var formatMenu: some View {
        Menu {
            ForEach(CameraController.PhotoFormat.allCases, id: \.self) { format in
                Button {
                    camera.photoFormat = format
                } label: {
                    if camera.photoFormat == format {
                        Label(format.title, systemImage: "checkmark")
                    } else {
                        Text(format.title)
                    }
                }
            }
        } label: {
            Text(camera.photoFormat.rawValue)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.photoFormat != .fourThree
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.photoFormat != .fourThree ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    /// Grille des tiers (viseur uniquement).
    private var gridToggle: some View {
        Button {
            camera.gridEnabled.toggle()
        } label: {
            Image(systemName: "grid")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.gridEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.gridEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    /// Bascule caméra arrière ↔ frontale.
    private var flipButton: some View {
        Button {
            camera.switchCamera()
            pinchBaseZoom = 1
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    /// Facteur de zoom courant ; un tap le remet à 1×.
    private var zoomChip: some View {
        Button {
            camera.setZoom(1)
            pinchBaseZoom = 1
        } label: {
            Text(String(format: "%.1f×", camera.zoomFactor))
                .font(.caption.monospacedDigit().weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    /// Verrouillage exposition + mise au point.
    private var aeafToggle: some View {
        Button {
            camera.toggleExposureFocusLock()
        } label: {
            Label("AE/AF", systemImage: camera.exposureFocusLocked
                  ? "lock.fill" : "lock.open")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.exposureFocusLocked
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.exposureFocusLocked ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    /// HDR : capture et encodage 10 bits HLG BT.2020.
    private var hdrToggle: some View {
        Button {
            camera.toggleHDR()
        } label: {
            Text("HDR")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.hdrEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.hdrEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    /// Mode 4K : enregistrement à 3840 px avec stabilisation cinématique,
    /// pour tous les profils d'objectifs.
    private var fourKToggle: some View {
        Button {
            camera.toggleFourK()
        } label: {
            Text("4K")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.fourKEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.fourKEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    /// Letterbox CinemaScope : recadrage du flux vidéo à 2.39:1.
    private var letterboxToggle: some View {
        Button {
            camera.toggleLetterbox()
        } label: {
            Text("2.39:1")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.letterboxEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.letterboxEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    /// Chronomètre d'enregistrement.
    private var recordingChip: some View {
        Label(timeString(camera.recordingSeconds), systemImage: "record.circle")
            .font(.caption.monospacedDigit().weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.red.opacity(0.85)))
            .foregroundStyle(.white)
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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

            if camera.rawEnabled && camera.mode == .photo {
                Text("DNG original + rendu vintage enregistrés dans Photos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                modeButton("Photo", .photo)
                modeButton("Vidéo", .video)
            }

            Button {
                if camera.mode == .photo {
                    camera.capturePhoto()
                } else {
                    camera.toggleRecording()
                }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                    if camera.mode == .photo {
                        Circle().fill(.white).frame(width: 58, height: 58)
                    } else if camera.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle().fill(.red).frame(width: 58, height: 58)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(camera.status != .running)
            .padding(.bottom, 6)
        }
        .padding(.vertical, 12)
        .background(.black.opacity(0.35))
    }

    private func modeButton(_ label: String, _ mode: CameraController.CaptureMode) -> some View {
        Button {
            camera.mode = mode
        } label: {
            Text(label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(camera.mode == mode ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
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
