import CoreImage
import Photos
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Studio : applique un objectif vintage à une photo de la photothèque.
struct EditorView: View {
    @State private var pickerItem: PhotosPickerItem?
    /// Image source normalisée en résolution d'aperçu.
    @State private var original: UIImage?
    /// Image source pleine résolution pour l'export.
    @State private var fullResolution: UIImage?
    @State private var processed: UIImage?
    @State private var lens: LensProfile = .catalog[1]
    @State private var intensity: Double = 1.0
    @State private var showOriginal = false
    @State private var isSaving = false
    @State private var savedBanner = false
    /// Masque d'arrière-plan extrait de la carte de profondeur (photos Portrait).
    @State private var depthMask: CIImage?
    @State private var useDepth = true
    /// Données brutes du fichier importé : EXIF et cartes auxiliaires
    /// (profondeur, matte) à préserver dans l'export.
    @State private var originalData: Data?
    /// Format de fichier des exports (partagé avec la caméra).
    @AppStorage("exportFormat") private var exportFormatRaw = ExportFormat.heic.rawValue

    private var exportFormat: ExportFormat {
        ExportFormat(rawValue: exportFormatRaw) ?? .heic
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                if original != nil { controls }
            }
            .navigationTitle("Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Importer", systemImage: "photo.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if original != nil {
                        Button {
                            saveToLibrary()
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Label("Enregistrer", systemImage: "square.and.arrow.down")
                            }
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .background(Color.black)
        }
        .onChange(of: pickerItem) { _, item in
            loadPickedImage(item)
        }
        .task(id: processingKey) {
            await processPreview()
        }
    }

    /// Identifiant de rendu : tout changement relance le traitement.
    private var processingKey: String {
        "\(lens.id)-\(intensity)-\(useDepth)-\(original?.hashValue ?? 0)"
    }

    /// Masque effectivement transmis au moteur.
    private var activeMask: CIImage? {
        useDepth ? depthMask : nil
    }

    // MARK: - Sous-vues

    private var preview: some View {
        GeometryReader { _ in
            ZStack {
                Color.black
                if let image = showOriginal ? original : (processed ?? original) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if showOriginal {
                                Text("Original")
                                    .font(.caption.weight(.semibold))
                                    .padding(6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(8)
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.1) {
                            showOriginal = true
                        } onPressingChanged: { pressing in
                            if !pressing { showOriginal = false }
                        }
                } else {
                    ContentUnavailableView(
                        "Aucune photo",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Importez une photo pour lui appliquer le rendu d'un objectif vintage. Maintenez l'aperçu appuyé pour comparer avec l'original.")
                    )
                }

                if savedBanner {
                    VStack {
                        Spacer()
                        Label("Enregistrée dans Photos", systemImage: "checkmark.circle.fill")
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: savedBanner)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            LensChipBar(selected: $lens)

            if depthMask != nil {
                Toggle(isOn: $useDepth) {
                    Label("Bokeh selon la profondeur (Portrait)",
                          systemImage: "person.and.background.dotted")
                        .font(.caption)
                }
                .tint(.orange)
                .padding(.horizontal)
            }

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
        }
        .padding(.vertical, 12)
        .background(.black.opacity(0.35))
    }

    // MARK: - Traitement

    private func loadPickedImage(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = await decode(data) else { return }
            // Le masque est ALIGNÉ sur l'image affichée : certaines photos
            // (exports d'Optyx notamment) embarquent leur carte en
            // orientation capteur et pleine trame — sans rotation ni
            // recadrage centré, le masque arrivait pivoté ou décalé et
            // l'édition partait dans le mauvais axe.
            let imageSize = image.size
            let mask = await Task.detached(priority: .userInitiated) {
                DepthExtractor.backgroundMask(from: data)
                    .map { DepthExtractor.aligned($0, with: imageSize) }
            }.value
            fullResolution = image.normalized(maxDimension: 3200)
            original = image.normalized(maxDimension: 1200)
            originalData = data
            depthMask = mask
            useDepth = mask != nil
            processed = nil
        }
    }

    /// Décode l'image importée ; les fichiers RAW (Apple ProRAW / DNG) que
    /// UIImage ne sait pas ouvrir sont développés via CIRAWFilter.
    private func decode(_ data: Data) async -> UIImage? {
        if let image = UIImage(data: data) { return image }
        return await Task.detached(priority: .userInitiated) {
            guard let rawFilter = CIRAWFilter(imageData: data, identifierHint: nil),
                  let output = rawFilter.outputImage,
                  let cgImage = LensEngine.shared.context
                      .createCGImage(output, from: output.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }

    private func processPreview() async {
        guard let original, let input = CIImage(image: original) else { return }
        let lens = self.lens
        let intensity = self.intensity
        let mask = activeMask
        let result = await Task.detached(priority: .userInitiated) {
            LensEngine.shared.renderUIImage(input, lens: lens, intensity: intensity,
                                            backgroundMask: mask)
        }.value
        if !Task.isCancelled, let result {
            processed = result
        }
    }

    private func saveToLibrary() {
        guard let fullResolution, let input = CIImage(image: fullResolution) else { return }
        isSaving = true
        let lens = self.lens
        let intensity = self.intensity
        let mask = activeMask
        let sourceData = originalData
        let format = exportFormat
        Task.detached(priority: .userInitiated) {
            // Export au format choisi, avec l'EXIF d'origine et les cartes
            // auxiliaires (profondeur, matte portrait) recopiées (HEIC/JPEG).
            // Le type déclaré à Photos suit les octets réellement produits :
            // un JPEG de repli étiqueté HEIC/PNG faisait échouer
            // l'enregistrement — « Enregistrer » ne faisait rien.
            var exportData: Data?
            var exportType = format.utType
            if let result = LensEngine.shared.renderUIImage(input, lens: lens,
                                                            intensity: intensity,
                                                            backgroundMask: mask) {
                if let embedded = PhotoMetadata.vintageImageData(
                    rendered: result,
                    originalData: sourceData,
                    depthData: nil,
                    lens: lens,
                    intensity: intensity,
                    format: format) {
                    exportData = embedded
                } else {
                    exportData = result.jpegData(compressionQuality: 0.92)
                    exportType = .jpeg
                }
            }
            guard let exportData else {
                await MainActor.run { isSaving = false }
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { authStatus in
                guard authStatus == .authorized || authStatus == .limited else {
                    DispatchQueue.main.async { isSaving = false }
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = exportType.identifier
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, data: exportData, options: options)
                } completionHandler: { success, _ in
                    DispatchQueue.main.async {
                        if success {
                            savedBanner = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                savedBanner = false
                            }
                        }
                        isSaving = false
                    }
                }
            }
        }
    }
}
