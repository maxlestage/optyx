import CoreGraphics
import Foundation

// Signature TONALE d'un objectif : la dérive de couleur du verre, sa saturation,
// son contraste et son vignettage.
//
// C'est l'étage A du moteur, et le seul qui soit TOUJOURS actif. Il ne déplace
// aucun pixel : il ne peut donc structurellement produire aucun artefact — ni
// anneau, ni liseré, ni traînée. C'est la partie du rendu qui marche sur
// n'importe quelle photo, y compris une plage en plein soleil sans la moindre
// source ponctuelle. Tout ce qui suit dans le moteur peut s'éteindre faute de
// matière ; cet étage, jamais.

// MARK: - Analyse d'un hexadécimal

/// Hexadécimal du catalogue → composantes sRGB.
///
/// L'analyse est refaite ici plutôt qu'empruntée à `Color(hex:)` du thème :
/// celui-ci produit une `Color` SwiftUI, dont on ne peut pas ressortir les
/// composantes de façon fiable.
enum CouleurHex {

    static func composantes(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var texte = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if texte.hasPrefix("#") { texte.removeFirst() }
        if texte.count == 3 {
            var doublee = ""
            for caractere in texte {
                doublee.append(caractere)
                doublee.append(caractere)
            }
            texte = doublee
        }
        guard texte.count == 6, let valeur = UInt32(texte, radix: 16) else {
            // Blanc plutôt que noir : une teinte de repli neutre laisse les
            // disques visibles, un noir les éteindrait et passerait pour un
            // bug de rendu.
            return (1, 1, 1)
        }
        return (CGFloat((valeur >> 16) & 0xFF) / 255,
                CGFloat((valeur >> 8) & 0xFF) / 255,
                CGFloat(valeur & 0xFF) / 255)
    }
}

// MARK: - Signature tonale

/// Les neuf réglages tonaux d'un verre.
///
/// MÉCANIQUE GAIN / BIAIS, qui est tout l'intérêt de cette table : un gain
/// multiplicatif agit proportionnellement, il teinte donc les HAUTES LUMIÈRES ;
/// un biais additif de 0,010 est négligeable sur un blanc à 1,0 mais représente
/// +7 % sur une ombre à 0,15, il teinte donc les OMBRES. Gain chaud + biais
/// froid = bichromie chaud/froid, avec une seule matrice linéaire. C'est
/// exactement ce qui donne le rendu ciné de l'Angénieux, sans aucune LUT.
///
/// `CITemperatureAndTint` est PROSCRIT : sa convention est celle du point blanc
/// source, monter `inputTargetNeutral.x` refroidit l'image, et deux itérations
/// de ce dépôt s'y sont déjà perdues. Une `CIColorMatrix` explicite se relit
/// ligne par ligne.
struct SignatureTonale {

    /// Gains multiplicatifs, un par canal. 1 = neutre.
    let gainR: CGFloat
    let gainV: CGFloat
    let gainB: CGFloat

    /// Biais additifs, un par canal, exprimés en fraction de la pleine échelle.
    /// Les valeurs utiles sont de l'ordre de 0,002 à 0,018.
    let biaisR: CGFloat
    let biaisV: CGFloat
    let biaisB: CGFloat

    /// Saturation et contraste, au sens de `CIColorControls`. 1 = neutre.
    let saturation: CGFloat
    let contraste: CGFloat

    /// Amplitude du vignettage global, dans [0, 1].
    let vignettage: CGFloat

    // MARK: Table des neuf verres

    /// Chaque ligne est justifiée dans le commentaire qui la précède. Ce ne sont
    /// pas des nombres décoratifs : ils sont ce qui distingue un Helios d'un
    /// Noct-Nikkor sur une photo qui ne porte AUCUN point lumineux.
    static func pour(_ lens: Lens) -> SignatureTonale {
        switch lens.id {

        // Helios 44-2 — verre soviétique : vert monté, rouge baissé, bleu relevé
        // surtout dans les ombres (biais). D'où le vert-cyan reproché aux tirages
        // de l'époque, sans faire virer les carnations (le gain bleu reste à 1,010).
        //
        // Note : `palette[0]` vaut ici « #dff5ab », un jaune-vert. Cette couleur
        // décrit les BULLES du catalogue, pas la dérive du verre. On ne la suit
        // donc pas, et il faut l'écrire pour qu'un futur lecteur ne « corrige »
        // pas cette table en croyant réparer une incohérence.
        case "helios-44-2":
            return SignatureTonale(gainR: 0.965, gainV: 1.030, gainB: 1.010,
                                   biaisR: 0.000, biaisV: 0.004, biaisB: 0.010,
                                   saturation: 1.04, contraste: 1.02, vignettage: 0.45)

        // Zeiss Biotar — même famille que l'Helios, moitié moins marqué, plus un
        // contraste inférieur à 1 : « le même vertige, en gants de velours ».
        case "zeiss-biotar":
            return SignatureTonale(gainR: 0.985, gainV: 1.015, gainB: 1.005,
                                   biaisR: 0.000, biaisV: 0.002, biaisB: 0.008,
                                   saturation: 1.00, contraste: 0.97, vignettage: 0.38)

        // Trioplan — triplet non traité : crème chaude, vignettage faible
        // (son trait `cat` vaut 0,22, le plus bas du catalogue avec le Noct-Nikkor).
        case "trioplan":
            return SignatureTonale(gainR: 1.045, gainV: 1.010, gainB: 0.945,
                                   biaisR: 0.006, biaisV: 0.004, biaisB: 0.000,
                                   saturation: 1.03, contraste: 1.00, vignettage: 0.30)

        // Summicron — quasi neutre, seul le micro-contraste monte (trait à 0,7).
        // Le fait qu'il ne fasse presque rien EST sa signature : c'est la seule
        // façon honnête de le distinguer d'un rendu moderne.
        case "summicron-50":
            return SignatureTonale(gainR: 1.005, gainV: 1.000, gainB: 0.995,
                                   biaisR: 0.000, biaisV: 0.000, biaisB: 0.000,
                                   saturation: 1.02, contraste: 1.06, vignettage: 0.20)

        // Noctilux — ambre chaud, ombres bleutées par le biais, vignettage massif
        // (trait à 0,65), contraste abaissé par le glow de f/1.
        case "noctilux":
            return SignatureTonale(gainR: 1.050, gainV: 1.005, gainB: 0.960,
                                   biaisR: 0.000, biaisV: 0.000, biaisB: 0.014,
                                   saturation: 0.98, contraste: 0.94, vignettage: 0.65)

        // Canon « Dream Lens » — rosé pâle, saturation et contraste effondrés :
        // le « contraste évanescent » revendiqué par la fiche.
        case "canon-dream":
            return SignatureTonale(gainR: 1.040, gainV: 0.995, gainB: 1.010,
                                   biaisR: 0.010, biaisV: 0.008, biaisB: 0.012,
                                   saturation: 0.92, contraste: 0.88, vignettage: 0.50)

        // Super Takumar — LE plus marqué du catalogue : rouge +8,5 %, bleu −11,5 %.
        // C'est le jaunissement du verre au thorium, et cet objectif doit sortir
        // franchement doré, sans quoi son unique trait à 1 (« Dérive chaude »)
        // ne se lit nulle part dans l'image.
        case "super-takumar":
            return SignatureTonale(gainR: 1.085, gainV: 1.020, gainB: 0.885,
                                   biaisR: 0.004, biaisV: 0.002, biaisB: 0.000,
                                   saturation: 1.05, contraste: 1.00, vignettage: 0.30)

        // Noct-Nikkor — froid et mordant, seul verre du catalogue à gain bleu
        // dominant. Contraste le plus haut (trait « Micro-contraste » 0,85).
        case "noct-nikkor":
            return SignatureTonale(gainR: 0.985, gainV: 0.995, gainB: 1.045,
                                   biaisR: 0.000, biaisV: 0.000, biaisB: 0.006,
                                   saturation: 1.00, contraste: 1.08, vignettage: 0.40)

        // Angénieux — hautes lumières chaudes (gain), ombres cyan (biais fort sur
        // V et B, littéralement son `duo` = ["#7cc4c4", "#9adcdc"]). C'est le
        // « teal & orange » du cinéma, obtenu par la seule mécanique gain/biais.
        case "angenieux":
            return SignatureTonale(gainR: 1.035, gainV: 1.005, gainB: 0.975,
                                   biaisR: 0.000, biaisV: 0.008, biaisB: 0.018,
                                   saturation: 0.96, contraste: 0.95, vignettage: 0.35)

        default:
            return repli(pour: lens)
        }
    }

    /// Repli pour un identifiant inconnu.
    ///
    /// Plutôt que de ne rien faire — ce qui donnerait un objectif muet et
    /// passerait pour une panne — on dérive une dérive douce de `palette[0]`,
    /// normalisée à moyenne unité pour ne pas éclaircir ni assombrir l'image, et
    /// ramenée à 30 % pour rester dans l'ordre de grandeur de la table ci-dessus.
    private static func repli(pour lens: Lens) -> SignatureTonale {
        let teinte = CouleurHex.composantes(lens.palette.first ?? lens.accent)
        let moyenne = max(0.05, (teinte.0 + teinte.1 + teinte.2) / 3)
        let gain: (CGFloat) -> CGFloat = { c in 1 + (c / moyenne - 1) * 0.30 }
        return SignatureTonale(gainR: gain(teinte.0),
                               gainV: gain(teinte.1),
                               gainB: gain(teinte.2),
                               biaisR: 0, biaisV: 0, biaisB: 0,
                               saturation: 1.0, contraste: 1.0, vignettage: 0.35)
    }
}
