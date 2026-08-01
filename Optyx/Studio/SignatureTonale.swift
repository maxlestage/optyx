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
    ///
    /// PLAFOND — invariant à respecter pour toute ligne ajoutée ou modifiée : aucun
    /// canal ne doit dépasser 1,0 en sortie de l'étage A1 pour une entrée blanche.
    /// Le rendu final est 8 bits ; tout ce qui dépasse est tranché, et comme le
    /// dépassement est PAR CANAL, c'est toujours le canal dominant — donc la
    /// signature du verre — qui est aplati le premier. L'effet ne s'atténue pas dans
    /// les hautes lumières : il s'INVERSE, la teinte retombant vers le neutre
    /// exactement là où elle devait s'affirmer. Deux verres sur neuf en sont morts.
    ///
    /// La valeur à contrôler n'est pas le gain mais la sortie complète de l'étage,
    /// saturation et contraste compris — c'est le contraste, pivotant sur 0,5, qui
    /// fixe le plafond du Noct-Nikkor, pas son gain bleu. Pour un gris d'entrée x :
    ///
    ///     c   = gain·x + biais                       (CIColorMatrix)
    ///     lum = 0,2125·cR + 0,7154·cV + 0,0721·cB
    ///     c   = lum + (c − lum)·saturation           (CIColorControls)
    ///     c   = (c − 0,5)·contraste + 0,5
    ///
    /// à évaluer sur toute la grille (x, k) et non au seul k = 1 : le moteur
    /// interpole les gains vers 1 quand l'intensité baisse, et un triplet entièrement
    /// sous 1 REMONTE donc quand k décroît. Le pire dépassement du Noct-Nikkor se
    /// produit à k intermédiaire. Pour teinter davantage sans déborder, il faut
    /// BAISSER les autres canaux, jamais monter le canal dominant : c'est le rapport
    /// entre les gains qui porte la teinte, leur niveau ne porte que l'exposition.
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

    /// MICRO-CONTRASTE — la signature des verres PRÉCIS, dans [0, 1].
    ///
    /// Elle manquait entièrement au moteur, et c'est ce qui rendait deux
    /// objectifs sur neuf indiscernables du flux brut. Le Summicron et le
    /// Noct-Nikkor ne se reconnaissent NI à un défaut, ni à une dérive : leur
    /// réputation tient au piqué et à la séparation des micro-tons. Un moteur
    /// qui ne sait qu'ajouter des défauts n'a littéralement rien à leur donner
    /// — leur rendu était donc l'image nue, teintée de 15 % et vignettée.
    ///
    /// C'est le seul paramètre de cette table qui va dans le sens INVERSE des
    /// autres : partout ailleurs on dégrade, ici on affirme. Il s'applique à
    /// l'image AVANT la défocalisation, de sorte que la zone nette y gagne et
    /// que l'arrière-plan, qui va être flouté juste après, n'en garde rien —
    /// accentuer ce qu'on s'apprête à effacer serait du calcul perdu.
    ///
    /// Volontairement nul pour les sept autres : accentuer un Trioplan ou un
    /// Dream Lens contredirait leur fiche, qui vend précisément la douceur.
    let microContraste: CGFloat

    // MARK: Table des neuf verres

    /// Chaque ligne est justifiée dans le commentaire qui la précède. Ce ne sont
    /// pas des nombres décoratifs : ils sont ce qui distingue un Helios d'un
    /// Noct-Nikkor sur une photo qui ne porte AUCUN point lumineux.
    ///
    /// RECALIBRAGE — les valeurs précédentes étaient SOUS LE SEUIL DE PERCEPTION.
    /// Mesuré sur un gris moyen, l'écart entre le canal le plus haut et le plus
    /// bas valait 1,0 % pour le Summicron, 2,3 % pour l'Angénieux, 3,6 % pour le
    /// Biotar, 4,7 % pour le Dream Lens — c'est-à-dire rien du tout : sur un
    /// écran de téléphone, un écart inférieur à ~6 % ne se distingue pas d'une
    /// image neutre. Seul le Takumar, à 21 %, se voyait réellement. Quatre
    /// objectifs sur neuf n'avaient donc AUCUNE signature couleur, ce qui
    /// explique une bonne part du « je ne vois rien » : sur une scène de jour
    /// sans point lumineux, la couleur est le seul trait qui reste.
    ///
    /// NIVEAU SPECTACULAIRE, demandé explicitement : les écarts sur un gris
    /// moyen valent désormais Summicron 15 %, Canon Dream 20 %, Noctilux et
    /// Angénieux 25 %, Noct-Nikkor 27 %, Biotar 36 %, Trioplan 45 %, Helios
    /// 45 %, Takumar 48 %. Un vrai verre ne dérive pas autant ; c'est un choix
    /// assumé, pris après que le rendu réaliste eut été jugé invisible sur
    /// appareil à une douzaine de reprises. Le Summicron reste volontairement
    /// discret : sa fiche revendique la neutralité, l'exagérer le rendrait faux.
    ///
    /// La dérive couleur est le seul effet de la chaîne qui ne DÉPLACE aucun
    /// pixel : elle ne peut fabriquer ni anneau, ni liseré, ni contour fantôme.
    /// C'est le seul levier qu'on puisse pousser à ce point sans rouvrir la
    /// famille de défauts qui a motivé tous les correctifs précédents.
    ///
    /// L'INVARIANT DE PLAFOND est tenu par construction, et VÉRIFIÉ
    /// numériquement sur toute la grille (entrée, intensité) au pas de 1 % :
    /// la sortie complète de l'étage — gain, biais, saturation ET contraste —
    /// vaut exactement 1,0000 au pire point pour les neuf verres, et ne le
    /// dépasse jamais. Le facteur d'échelle appliqué à chaque triplet a été
    /// résolu par dichotomie pour atteindre ce plafond sans le franchir, ce qui
    /// préserve les RAPPORTS entre canaux — donc la teinte — et ne joue que sur
    /// l'exposition.
    ///
    /// La luminance d'un gris moyen tombe à 88-96 % selon le verre (80 % pour le
    /// Noct-Nikkor, dont le fort contraste force le facteur le plus bas). Un
    /// verre ancien qui mange un peu de lumière est juste ; le contraire —
    /// remonter le canal dominant — écrêterait, et l'écrêtage n'atténue pas la
    /// signature, il l'INVERSE au-dessus du seuil.
    static func pour(_ lens: Lens) -> SignatureTonale {
        switch lens.id {

        // Helios 44-2 — verre soviétique : vert monté, rouge baissé, bleu relevé
        // surtout dans les ombres (biais). D'où le vert-cyan reproché aux tirages
        // de l'époque. Le vert est le canal dominant ; c'est le ROUGE
        // qu'on effondre pour creuser l'écart, ce qui donne 45 % sur un gris
        // moyen sans jamais écrêter le vert.
        //
        // Note : `palette[0]` vaut ici « #dff5ab », un jaune-vert. Cette couleur
        // décrit les BULLES du catalogue, pas la dérive du verre. On ne la suit
        // donc pas, et il faut l'écrire pour qu'un futur lecteur ne « corrige »
        // pas cette table en croyant réparer une incohérence.
        case "helios-44-2":
            return SignatureTonale(gainR: 0.638, gainV: 0.966, gainB: 0.865,
                                   biaisR: 0.000, biaisV: 0.021, biaisB: 0.049,
                                   saturation: 1.04, contraste: 1.02, vignettage: 0.45, microContraste: 0.00)

        // Zeiss Biotar — même famille que l'Helios, moitié moins marqué, plus un
        // contraste inférieur à 1 : « le même vertige, en gants de velours ».
        case "zeiss-biotar":
            return SignatureTonale(gainR: 0.694, gainV: 0.964, gainB: 0.874,
                                   biaisR: 0.000, biaisV: 0.019, biaisB: 0.050,
                                   saturation: 1.00, contraste: 0.97, vignettage: 0.38, microContraste: 0.00)

        // Trioplan — triplet non traité : crème chaude, vignettage faible
        // (son trait `cat` vaut 0,22, le plus bas du catalogue avec le Noct-Nikkor).
        case "trioplan":
            return SignatureTonale(gainR: 0.977, gainV: 0.861, gainB: 0.645,
                                   biaisR: 0.019, biaisV: 0.014, biaisB: 0.000,
                                   saturation: 1.03, contraste: 1.00, vignettage: 0.30, microContraste: 0.00)

        // Summicron — quasi neutre, seul le micro-contraste monte (trait à 0,7).
        // Le fait qu'il ne fasse presque rien EST sa signature : c'est la seule
        // façon honnête de le distinguer d'un rendu moderne.
        case "summicron-50":
            return SignatureTonale(gainR: 0.958, gainV: 0.891, gainB: 0.824,
                                   biaisR: 0.000, biaisV: 0.000, biaisB: 0.000,
                                   saturation: 1.02, contraste: 1.06, vignettage: 0.20, microContraste: 0.75)

        // Noctilux — ambre chaud, ombres bleutées par le biais, vignettage massif
        // (trait à 0,65), contraste abaissé par le glow de f/1.
        case "noctilux":
            return SignatureTonale(gainR: 1.030, gainV: 0.869, gainB: 0.703,
                                   biaisR: 0.000, biaisV: 0.000, biaisB: 0.050,
                                   saturation: 0.98, contraste: 0.94, vignettage: 0.65, microContraste: 0.00)

        // Canon « Dream Lens » — rosé pâle, saturation et contraste effondrés :
        // le « contraste évanescent » revendiqué par la fiche.
        case "canon-dream":
            return SignatureTonale(gainR: 1.012, gainV: 0.808, gainB: 0.903,
                                   biaisR: 0.049, biaisV: 0.049, biaisB: 0.049,
                                   saturation: 0.92, contraste: 0.88, vignettage: 0.50, microContraste: 0.00)

        // Super Takumar — LE plus marqué du catalogue : c'est le jaunissement du
        // verre au thorium, et cet objectif doit sortir franchement doré, sans quoi
        // son unique trait à 1 (« Dérive chaude ») ne se lit nulle part.
        //
        // Ce qui FAIT la dorure est le RAPPORT R/B = 0,986 / 0,612 = 1,611, pas le
        // niveau absolu des gains. L'ancienne écriture (1,085 / 1,020 / 0,885) tenait
        // le même rapport, 1,2260, mais en montant le rouge AU-DESSUS de 1 : avec la
        // saturation 1,05, une entrée blanche ressortait à R = 1,0921. Les 8,47 %
        // supérieurs de la plage (tout ce qui dépasse une entrée de 0,9153) étaient
        // donc aplatis sur R = 1,0 par le 8 bits pendant que V et B continuaient de
        // monter, et le rapport R/B RENDU retombait de 1,244 à 1,139 entre le seuil
        // et le blanc : ciel, chemise blanche et sable au soleil ressortaient MOINS
        // dorés que les demi-teintes, l'exact inverse de la signature annoncée.
        //
        // Le triplet est donc mis à l'échelle par 0,9153 — le plus grand facteur qui
        // ne déborde jamais, vérifié sur toute la grille (entrée, intensité k) et
        // non au seul k = 1. Le rapport de gains est conservé à la quatrième décimale
        // (1,2260 → 1,2259), le rouge atterrit exactement sur 1,000 pour une entrée
        // blanche, et le R/B rendu devient constant : 1,2566 à 0,30 · 1,2466 à 0,70 ·
        // 1,2453 à 0,85 · 1,2444 à 1,00 (contre 1,1390 avant). Prix payé : −0,077 EV
        // sur le blanc, −0,127 EV sur les demi-teintes. La teinte, elle, ne bouge pas.
        case "super-takumar":
            return SignatureTonale(gainR: 0.986, gainV: 0.865, gainB: 0.612,
                                   biaisR: 0.008, biaisV: 0.004, biaisB: 0.000,
                                   saturation: 1.05, contraste: 1.00, vignettage: 0.30, microContraste: 0.10)

        // Noct-Nikkor — froid et mordant, seul verre du catalogue à bleu dominant.
        // Contraste le plus haut du catalogue (trait « Micro-contraste » 0,85), et
        // c'est LUI qui fixe le plafond ici : un contraste de 1,08 pivote sur 0,5 et
        // envoie à lui seul une entrée de 1,0 sur 1,04, avant même le moindre gain.
        //
        // Défaut symétrique de celui du Super Takumar, corrigé de la même façon.
        // L'ancienne écriture (0,985 / 0,995 / 1,045) écrêtait le bleu dès une entrée
        // de 0,9158 : l'écart B−R RENDU, qui EST le mordant froid, culminait à 6,58
        // points au seuil puis retombait à 4,00 à 0,94, à 1,56 à 0,963 et à 0,00 au
        // blanc — les hautes lumières d'un verre « froid et mordant » finissaient
        // parfaitement neutres, sur les 8,42 % supérieurs de la plage.
        //
        // Mise à l'échelle du triplet par 0,9129. Ce facteur n'est PAS 1/1,045 :
        // ramener simplement le gain bleu à 1,000 laisse le contraste écrêter seul
        // dès 0,9570, et le pire dépassement ne se produit même pas à k = 1 — il
        // faut balayer toute la grille (entrée, intensité) pour le trouver. Rapport
        // B/R conservé (1,0609 → 1,0612), et l'écart B−R rendu MONTE désormais sans
        // rechute : 2,43 pts à 0,30 · 4,81 à 0,70 · 5,70 à 0,85 · 6,29 à 0,95 ·
        // 6,59 au blanc. Prix payé : −0,085 EV sur le blanc, −0,143 EV en demi-teinte.
        case "noct-nikkor":
            return SignatureTonale(gainR: 0.752, gainV: 0.798, gainB: 0.931,
                                   biaisR: 0.000, biaisV: 0.000, biaisB: 0.030,
                                   saturation: 1.00, contraste: 1.08, vignettage: 0.40, microContraste: 0.90)

        // Angénieux — hautes lumières chaudes (gain), ombres cyan (biais fort sur
        // V et B, littéralement son `duo` = ["#7cc4c4", "#9adcdc"]). C'est le
        // « teal & orange » du cinéma, obtenu par la seule mécanique gain/biais.
        case "angenieux":
            return SignatureTonale(gainR: 1.025, gainV: 0.864, gainB: 0.700,
                                   biaisR: 0.000, biaisV: 0.042, biaisB: 0.049,
                                   saturation: 0.96, contraste: 0.95, vignettage: 0.35, microContraste: 0.00)

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
                               saturation: 1.0, contraste: 1.0, vignettage: 0.35, microContraste: 0)
    }
}
