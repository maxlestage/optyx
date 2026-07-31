import Foundation

/// Profil optique d'un objectif vintage.
/// Chaque paramètre est normalisé entre 0 et 1 et décrit l'intensité
/// d'un "défaut" optique caractéristique reproduit par le moteur de rendu.
struct LensProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let focal: String
    let origin: String
    let era: String
    let story: String

    /// Bokeh tourbillonnant (flou tangentiel croissant vers les bords).
    var swirl: Double
    /// Bokeh « bulles de savon » (anneaux lumineux sur les hautes lumières).
    var bubble: Double
    /// Perte de piqué vers les bords du champ.
    var softness: Double
    /// Halo / voile lumineux autour des hautes lumières (halation).
    var glow: Double
    /// Assombrissement des coins.
    var vignette: Double
    /// Aberration chromatique latérale (franges colorées).
    var chroma: Double
    /// Dérive chaude des couleurs (ex. jaunissement du verre au thorium).
    var warmth: Double
    /// Noirs voilés, contraste réduit.
    var fade: Double
    /// Saturation relative (1 = neutre).
    var saturation: Double
    /// Grain argentique.
    var grain: Double
    /// Micro-contraste : netteté de luminance et punch (verres précis
    /// type Summicron, Noct-Nikkor) — l'opposé des rêveurs.
    var punch: Double = 0
    /// Virage bicolore cinéma : ombres bleu-vert, tons clairs chauds
    /// (pellicule de laboratoire, Angénieux).
    var cine: Double = 0
    /// Taille des disques de bokeh formés par les points de lumière hors
    /// du plan de netteté — en pratique, l'ouverture du verre. Un flou
    /// seul étale ces points en taches ternes ; ce paramètre les rend
    /// sous forme de disques brillants. `bubble` décide s'ils sont
    /// pleins ou creux (bulles de savon).
    var bokeh: Double = 0
    /// FLOU D'ARRIÈRE-PLAN pour une scène de référence, exprimé en
    /// fraction du petit côté de l'image. C'est la profondeur de champ du
    /// verre, et donc la séparation sujet/fond — le trait qui se lit sur
    /// N'IMPORTE QUELLE scène, mur nu compris. À ne pas confondre avec
    /// `softness`, qui reste la perte de piqué vers les bords du CHAMP —
    /// une aberration radiale, pas un effet de distance.
    ///
    /// Les valeurs sont calculées et non choisies : cercle de confusion
    /// c = f²·Δ / (N·s₂·(s₁−f)) pour un sujet à 1,2 m et un fond à 5 m,
    /// rapporté à la hauteur du capteur, puis c/4.
    ///
    /// C'est là sa limite, et la raison de `focalMM`/`fNumber` : une scène
    /// de référence unique ne peut pas décrire un verre. Le même objectif
    /// rend un fond à 20 m bien plus flou qu'un fond à 5 m ; figé sur une
    /// seule distance, ce réglage donnait le même flou aux deux.
    /// `defocusRadiusFraction` refait le calcul par pixel, à partir de la
    /// distance réellement mesurée. Ce champ reste le REPLI quand la
    /// focale n'est pas renseignée.
    var aperture: Double = 0
    /// FOCALE RÉELLE du verre, en millimètres — telle qu'elle est gravée
    /// sur la bague. Avec `fNumber`, elle remplace le réglage `aperture`
    /// par un calcul : c'est l'optique du verre, plus une valeur choisie.
    var focalMM: Double = 0
    /// OUVERTURE RÉELLE (nombre f) du verre à pleine ouverture.
    var fNumber: Double = 0
    /// Voile onirique (effet Orton) : une copie floue incrustée en écran
    /// sur tout le cadre. Distinct de `glow`, qui est la halation autour
    /// des seules hautes lumières — le voile, lui, se voit sur n'importe
    /// quelle scène, ce qui en fait la signature du Dream Lens.
    var veil: Double = 0

    /// RAYON DU DISQUE DE BOKEH d'un point à l'INFINI, exprimé en fraction
    /// du petit côté de l'image — l'amplitude maximale de la
    /// défocalisation, celle que la carte du cercle de confusion module
    /// ensuite entre 0 et 1.
    ///
    /// Déduit de la focale et de l'ouverture réelles, jamais réglé :
    ///
    ///     c∞ / h = (f² / (24·N)) · x_f / (1000 − f·x_f)
    ///
    /// avec h = 24 mm (petit côté du 24×36) et x_f la disparité du plan de
    /// netteté. Le facteur 4 final vient de la convention de
    /// `LensEngine.defocusedCopy`, qui reçoit un rayon puis le double pour
    /// obtenir le rayon du disque : c est un DIAMÈTRE, d'où c/2 pour le
    /// rayon, puis /2 pour la convention — c/4.
    ///
    /// Repli sur `aperture` si la focale n'est pas renseignée : l'ancienne
    /// valeur était calculée avec la même formule, pour un sujet à 1,2 m
    /// et un fond à 5 m. Le chemin d'origine reste donc intact.
    var defocusRadiusFraction: Double {
        guard focalMM > 0, fNumber > 0 else { return aperture }
        let xf = Double(DepthExtractor.focusDisparity)
        let denominator = 1000 - focalMM * xf
        guard denominator > 0 else { return aperture }
        let k = focalMM * focalMM / (24 * fNumber)
        return (k * xf / denominator) / 4
    }
}

extension LensProfile {

    static let neutral = LensProfile(
        id: "neutral",
        name: "Neutre",
        focal: "—",
        origin: "—",
        era: "—",
        story: "Aucune simulation : l'image sort telle que le capteur la voit. Utile pour comparer avec les rendus vintage.",
        swirl: 0, bubble: 0, softness: 0, glow: 0, vignette: 0,
        chroma: 0, warmth: 0, fade: 0, saturation: 1.0, grain: 0
    )

    static let catalog: [LensProfile] = [
        .neutral,

        LensProfile(
            id: "helios-44-2",
            name: "Helios 44-2",
            focal: "58 mm f/2",
            origin: "URSS · monture M42",
            era: "1958 – années 1990",
            story: "Copie soviétique du Zeiss Biotar, produit à des millions d'exemplaires. Son bokeh tourbillonnant culte transforme les arrière-plans en spirale autour du sujet. Très abordable, c'est la porte d'entrée du monde vintage.",
            swirl: 1.00, bubble: 0.15, softness: 0.30, glow: 0.30, vignette: 0.45,
            chroma: 0.35, warmth: -0.3, fade: 0.20, saturation: 1.03, grain: 0.20,
            bokeh: 0.55,
            aperture: 0.0117,
            focalMM: 58, fNumber: 2
        ),

        LensProfile(
            id: "zeiss-biotar",
            name: "Zeiss Biotar",
            focal: "58 mm f/2",
            origin: "Allemagne · M42 / Exakta",
            era: "1936 – 1960",
            story: "L'original allemand dont l'Helios est la copie. Même tourbillon, mais avec un rendu un peu plus doux et raffiné. Plus rare et nettement plus cher que son clone soviétique.",
            swirl: 0.85, bubble: 0.20, softness: 0.25, glow: 0.35, vignette: 0.38,
            chroma: 0.30, warmth: 0.45, fade: 0.18, saturation: 1.00, grain: 0.15,
            bokeh: 0.5,
            aperture: 0.0117,
            focalMM: 58, fNumber: 2
        ),

        LensProfile(
            id: "trioplan",
            name: "Meyer-Optik Görlitz Trioplan",
            focal: "100 mm f/2.8",
            origin: "Allemagne (RDA) · M42 / Exakta",
            era: "1916 – 1970",
            story: "Un triplet optique tout simple dont l'aberration sphérique non corrigée produit le fameux bokeh « bulles de savon » : chaque point lumineux hors mise au point devient un anneau brillant.",
            swirl: 0.15, bubble: 1.00, softness: 0.30, glow: 0.45, vignette: 0.30,
            chroma: 0.45, warmth: 0.2, fade: 0.20, saturation: 1.08, grain: 0.15,
            bokeh: 1.0,
            aperture: 0.0257,
            focalMM: 100, fNumber: 2.8
        ),

        LensProfile(
            id: "summicron-50",
            name: "Leica Summicron",
            focal: "50 mm f/2",
            origin: "Allemagne · monture M / LTM",
            era: "1953 – aujourd'hui",
            story: "Le classique du reportage : micro-contraste superbe, rendu précis mais jamais clinique. Un « défaut » discret : un léger vignettage et une signature douce à pleine ouverture.",
            swirl: 0.00, bubble: 0.00, softness: 0.10, glow: 0.15, vignette: 0.20,
            chroma: 0.05, warmth: 0.0, fade: 0.08, saturation: 1.06, grain: 0.10,
            punch: 0.70,
            bokeh: 0.25,
            aperture: 0.0086,
            focalMM: 50, fNumber: 2
        ),

        LensProfile(
            id: "noctilux",
            name: "Leica Noctilux",
            focal: "50 mm f/1",
            origin: "Allemagne · monture M",
            era: "1976 – 2008",
            story: "Le roi de la nuit chez Leica. À f/1, l'image baigne dans un glow onirique, le vignettage est massif et la zone de netteté se réduit à un fil. Un rendu immédiatement reconnaissable.",
            swirl: 0.25, bubble: 0.10, softness: 0.45, glow: 0.95, vignette: 0.65,
            chroma: 0.25, warmth: 0.0, fade: 0.15, saturation: 0.98, grain: 0.15,
            bokeh: 0.85,
            aperture: 0.0172,
            focalMM: 50, fNumber: 1,
            veil: 0.35
        ),

        LensProfile(
            id: "canon-dream",
            name: "Canon « Dream Lens »",
            focal: "50 mm f/0.95",
            origin: "Japon · monture Canon 7",
            era: "1961 – 1970",
            story: "Quasi mythique, très peu produit. À f/0.95, le monde devient un rêve : halos généreux, contraste évanescent, netteté fragile. C'est précisément ce voile onirique qui fait sa légende.",
            swirl: 0.30, bubble: 0.15, softness: 0.80, glow: 1.00, vignette: 0.50,
            chroma: 0.50, warmth: 0.0, fade: 0.25, saturation: 0.96, grain: 0.20,
            bokeh: 1.0,
            aperture: 0.0181,
            focalMM: 50, fNumber: 0.95,
            veil: 1.0
        ),

        LensProfile(
            id: "super-takumar",
            name: "Pentax Super Takumar",
            focal: "50 mm f/1.4",
            origin: "Japon · monture M42",
            era: "1964 – 1975",
            story: "Son verre au thorium, légèrement radioactif, jaunit avec les décennies et donne aux images une chaleur dorée inimitable. Construction magnifique, mise au point soyeuse.",
            swirl: 0.10, bubble: 0.10, softness: 0.20, glow: 0.35, vignette: 0.30,
            chroma: 0.15, warmth: 1.0, fade: 0.15, saturation: 1.02, grain: 0.15,
            bokeh: 0.45,
            aperture: 0.0123,
            focalMM: 50, fNumber: 1.4
        ),

        LensProfile(
            id: "noct-nikkor",
            name: "Noct-Nikkor",
            focal: "58 mm f/1.2",
            origin: "Japon · monture F",
            era: "1977 – 1997",
            story: "Conçu pour photographier la nuit : sa lentille asphérique polie à la main dompte le coma des points lumineux. Contraste élevé pour son époque, léger halo à pleine ouverture.",
            swirl: 0.10, bubble: 0.05, softness: 0.15, glow: 0.55, vignette: 0.40,
            chroma: 0.10, warmth: -0.2, fade: 0.08, saturation: 1.08, grain: 0.30,
            punch: 0.85,
            bokeh: 0.3,
            aperture: 0.0194,
            focalMM: 58, fNumber: 1.2,
            veil: 0.12
        ),

        LensProfile(
            id: "angenieux",
            name: "Angénieux Cinéma",
            focal: "zoom 25–250 mm",
            origin: "France · montures ciné",
            era: "1956 – aujourd'hui",
            story: "Les zooms de cinéma légendaires de Pierre Angénieux, utilisés d'Hollywood à la Nouvelle Vague. Rendu ciné par excellence : contraste doux, couleurs chaudes, grain présent.",
            swirl: 0.05, bubble: 0.10, softness: 0.25, glow: 0.45, vignette: 0.35,
            chroma: 0.20, warmth: 0.4, fade: 0.30, saturation: 0.93, grain: 0.60,
            cine: 0.85,
            bokeh: 0.45,
            aperture: 0.0069,
            // Position de référence retenue pour la simulation : le zoom
            // couvre 25–250 mm, on simule la focale la plus employée en
            // tournage, à son ouverture utile.
            focalMM: 50, fNumber: 2.5
        ),
    ]

    /// Caractéristiques affichées dans la fiche détaillée (label, valeur).
    var traits: [(String, Double)] {
        [
            ("Flou d'arrière-plan", min(1, defocusRadiusFraction / 0.05)),
            ("Tourbillon", swirl),
            ("Disques de bokeh", bokeh),
            ("Bulles de savon", bubble),
            ("Douceur des bords", softness),
            ("Halo / glow", glow),
            ("Vignettage", vignette),
            ("Aberration chromatique", chroma),
            ("Dérive de couleur", abs(warmth)),
            ("Voile onirique", veil),
            ("Voile / contraste bas", fade),
            ("Grain", grain),
            ("Micro-contraste", punch),
            ("Virage ciné", cine),
        ]
    }
}
