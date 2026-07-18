import SwiftUI

/// Barre horizontale de sélection d'objectif, partagée entre
/// la caméra et le studio.
struct LensChipBar: View {
    @Binding var selected: LensProfile

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LensProfile.catalog) { lens in
                    Button {
                        selected = lens
                    } label: {
                        VStack(spacing: 2) {
                            Text(lens.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(lens.focal)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(selected.id == lens.id
                                           ? Color.orange.opacity(0.85)
                                           : Color.white.opacity(0.12))
                        )
                        .foregroundStyle(selected.id == lens.id ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}
