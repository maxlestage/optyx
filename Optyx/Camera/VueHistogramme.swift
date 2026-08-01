import SwiftUI

/// Répartition des tons par canal, normalisée 0…1.
///
/// `Equatable` pour que SwiftUI ne redessine pas un tracé identique — la mesure
/// arrive plusieurs fois par seconde et une scène immobile produit deux fois de
/// suite les mêmes valeurs.
struct DonneesHistogramme: Equatable {
    var rouge: [Float]
    var vert: [Float]
    var bleu: [Float]

    static let vide = DonneesHistogramme(rouge: [], vert: [], bleu: [])
    var estVide: Bool { rouge.count < 2 }
}

/// Histogramme RVB superposé, tracé en mode ÉCRAN comme sur un boîtier.
///
/// Le mode écran n'est pas un choix esthétique : avec trois courbes opaques, la
/// dernière tracée masquerait les deux autres, et un histogramme dont un canal
/// est caché ne sert à rien. En écran, les recouvrements s'éclaircissent — le
/// gris signale les tons neutres, une teinte franche un canal isolé.
struct VueHistogramme: View {
    let donnees: DonneesHistogramme

    var body: some View {
        Canvas { contexte, taille in
            contexte.blendMode = .screen
            let canaux: [(valeurs: [Float], couleur: Color)] = [
                (donnees.rouge, .red),
                (donnees.vert, .green),
                (donnees.bleu, Color(red: 0.35, green: 0.55, blue: 1.0)),
            ]
            for canal in canaux {
                let valeurs = canal.valeurs
                guard valeurs.count > 1 else { continue }
                var trace = Path()
                trace.move(to: CGPoint(x: 0, y: taille.height))
                for (index, valeur) in valeurs.enumerated() {
                    let x = taille.width * CGFloat(index) / CGFloat(valeurs.count - 1)
                    let y = taille.height * CGFloat(1 - min(1, valeur))
                    trace.addLine(to: CGPoint(x: x, y: y))
                }
                trace.addLine(to: CGPoint(x: taille.width, y: taille.height))
                trace.closeSubpath()
                contexte.fill(trace, with: .color(canal.couleur.opacity(0.65)))
            }
        }
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        // Purement informatif : il ne doit jamais intercepter un toucher destiné
        // au viseur qu'il recouvre.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
