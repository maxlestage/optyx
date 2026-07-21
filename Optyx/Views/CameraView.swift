import SwiftUI

/// Viseur : flux caméra filtré en direct par l'objectif sélectionné.
struct CameraView: View {
    @StateObject private var camera = CameraController()
    @State private var lens: LensProfile = .catalog[1]
    @State private var intensity: Double = 1.0
    /// Zoom au début du pincement en cours.
    @State private var pinchBaseZoom: CGFloat = 1
    /// Un tap sur l'image masque tous les contrôles (re-tap pour revenir).
    @State private var hideControls = false
    /// Format de fichier des exports photo (partagé avec le Studio).
    @AppStorage("exportFormat") private var exportFormatRaw = ExportFormat.heic.rawValue

    private var exportFormat: ExportFormat {
        ExportFormat(rawValue: exportFormatRaw) ?? .heic
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            content(isLandscape: isLandscape)
        }
    }

    private func content(isLandscape: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .running, .idle:
                MetalPreviewView(renderer: camera.previewRenderer,
                                 onHardwareShutter: { camera.triggerShutter() })
                    .ignoresSafeArea(edges: .top)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            hideControls.toggle()
                        }
                    }
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

            if !hideControls {
                overlayControls(isLandscape: isLandscape)
            } else {
                // Petit rappel discret : les contrôles reviennent d'un tap
                // (sur l'œil ou n'importe où sur l'image).
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                hideControls = false
                            }
                        } label: {
                            Image(systemName: "eye")
                                .font(.headline)
                                .padding(12)
                                .background(.black.opacity(0.4), in: Circle())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(20)
                    }
                }
            }

            if camera.lastCaptureSaved {
                Label("Enregistrée dans Photos", systemImage: "checkmark.circle.fill")
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }

            if let countdown = camera.countdown {
                Text("\(countdown)")
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .transition(.opacity)
                    .id(countdown)
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

    /// Tout l'habillage du viseur (pastilles, histogramme, contrôles),
    /// masquable d'un tap sur l'image.
    @ViewBuilder
    private func overlayControls(isLandscape: Bool) -> some View {
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
                        timerToggle
                        if camera.mode == .photo { burstToggle }
                        if camera.mode == .photo { formatMenu }
                        if camera.mode == .photo { fileFormatMenu }
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
                if !isLandscape { controls }
            }

            // En paysage : image dégagée, réglages dans une barre fine en
            // bas et déclencheur sur le bord droit, sous le pouce.
            if isLandscape {
                VStack {
                    Spacer()
                    landscapeBottomBar
                }
                HStack {
                    Spacer()
                    landscapeSideControls
                }
            }
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

    /// Retardateur : un tap cycle Off → 3 s → 5 s → 10 s.
    private var timerToggle: some View {
        Button {
            camera.timerSetting = camera.timerSetting.next
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                if camera.timerSetting != .off {
                    Text("\(camera.timerSetting.rawValue) s")
                }
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(camera.timerSetting != .off
                               ? Color.orange.opacity(0.9)
                               : Color.white.opacity(0.15))
            )
            .foregroundStyle(camera.timerSetting != .off ? .black : .white)
        }
        .buttonStyle(.plain)
        .disabled(camera.countdown != nil)
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

    /// Mode rafale : le déclencheur enchaîne 8 captures pleine qualité ;
    /// pendant la rafale, la pastille affiche le compteur.
    private var burstToggle: some View {
        Button {
            camera.burstEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.down.right.fill")
                if camera.burstCountRemaining > 0 {
                    Text("\(camera.burstCountRemaining)")
                        .monospacedDigit()
                } else if camera.burstEnabled {
                    Text("×\(camera.burstSize)")
                }
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(camera.burstEnabled
                               ? Color.orange.opacity(0.9)
                               : Color.white.opacity(0.15))
            )
            .foregroundStyle(camera.burstEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
        .disabled(camera.burstCountRemaining > 0)
    }

    /// Format de fichier des exports : HEIC, JPEG, PNG ou TIFF.
    private var fileFormatMenu: some View {
        Menu {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button {
                    exportFormatRaw = format.rawValue
                } label: {
                    if exportFormat == format {
                        Label(format.title, systemImage: "checkmark")
                    } else {
                        Text(format.title)
                    }
                }
            }
        } label: {
            Text(exportFormat.label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(exportFormat != .heic
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(exportFormat != .heic ? .black : .white)
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
            Label(camera.depthMaskPreview ? "Masque" : "Profondeur",
                  systemImage: "person.and.background.dotted")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(camera.depthMaskPreview
                                   ? Color.purple.opacity(0.9)
                                   : camera.depthEnabled
                                   ? Color.orange.opacity(0.9)
                                   : Color.white.opacity(0.15))
                )
                .foregroundStyle(camera.depthEnabled || camera.depthMaskPreview
                                 ? .black : .white)
        }
        .buttonStyle(.plain)
        // Diagnostic : appui long = affiche le masque de profondeur brut
        // en surimpression (blanc = loin/effets, noir = net) — pour voir
        // exactement ce que le LiDAR fournit au moteur.
        .onLongPressGesture {
            camera.depthMaskPreview.toggle()
        }
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

            shutterButton
                .padding(.bottom, 6)
        }
        .padding(.vertical, 12)
        .background(.black.opacity(0.35))
    }

    private var shutterButton: some View {
        Button {
            camera.triggerShutter()
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
    }

    /// Paysage : barre fine en bas — objectifs et intensité seulement.
    private var landscapeBottomBar: some View {
        HStack(spacing: 12) {
            LensChipBar(selected: $lens)
                .frame(maxWidth: .infinity)
            Slider(value: $intensity, in: 0...1)
                .tint(.orange)
                .frame(width: 170)
            Text("\(Int(intensity * 100)) %")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing)
        }
        .padding(.vertical, 8)
        .background(.black.opacity(0.35))
    }

    /// Paysage : mode et déclencheur sur le bord droit, sous le pouce.
    private var landscapeSideControls: some View {
        VStack(spacing: 16) {
            modeButton("Photo", .photo)
            modeButton("Vidéo", .video)
            shutterButton
        }
        .padding(14)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 24))
        .padding(.trailing, 12)
        .padding(.bottom, 40)
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
