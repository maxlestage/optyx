import SwiftUI

/// Catalogue des objectifs vintage simulés.
struct LensCatalogView: View {
    private var lenses: [LensProfile] {
        LensProfile.catalog.filter { $0.id != "neutral" }
    }

    var body: some View {
        NavigationStack {
            List(lenses) { lens in
                NavigationLink(value: lens) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lens.name)
                            .font(.headline)
                        Text("\(lens.focal) · \(lens.origin)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(lens.era)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
            .navigationTitle("Objectifs")
            .navigationDestination(for: LensProfile.self) { lens in
                LensDetailView(lens: lens)
            }
        }
    }
}

/// Fiche détaillée : histoire, aperçu de bokeh simulé et signature optique.
struct LensDetailView: View {
    let lens: LensProfile
    @State private var preview: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Group {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.06))
                            .aspectRatio(1.5, contentMode: .fit)
                            .overlay(ProgressView())
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text("Simulation de bokeh — scène de test")
                        .font(.caption2)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }

                Text(lens.story)
                    .font(.body)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Signature optique")
                        .font(.headline)
                    ForEach(lens.traits.filter { $0.1 > 0.01 }, id: \.0) { trait in
                        TraitBar(label: trait.0, value: trait.1)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(lens.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let lens = self.lens
            preview = await Task.detached(priority: .userInitiated) {
                BokehPreview.render(lens: lens)
            }.value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lens.focal)
                .font(.title2.weight(.bold))
            Text("\(lens.origin) · \(lens.era)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Jauge horizontale d'une caractéristique optique.
struct TraitBar: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(Color.orange.gradient)
                        .frame(width: max(6, geo.size.width * value))
                }
            }
            .frame(height: 7)
        }
    }
}

#Preview {
    LensCatalogView()
        .preferredColorScheme(.dark)
}
