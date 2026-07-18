import CoreImage
import SwiftUI
import PhotosUI

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
        "\(lens.id)-\(intensity)-\(original?.hashValue ?? 0)"
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
            fullResolution = image.normalized(maxDimension: 3200)
            original = image.normalized(maxDimension: 1200)
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
        let result = await Task.detached(priority: .userInitiated) {
            LensEngine.shared.renderUIImage(input, lens: lens, intensity: intensity)
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
        Task.detached(priority: .userInitiated) {
            let result = LensEngine.shared.renderUIImage(input, lens: lens, intensity: intensity)
            await MainActor.run {
                if let result {
                    UIImageWriteToSavedPhotosAlbum(result, nil, nil, nil)
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
