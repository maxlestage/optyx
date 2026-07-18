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
            swirl: 0.90, bubble: 0.15, softness: 0.35, glow: 0.30, vignette: 0.55,
            chroma: 0.35, warmth: 0.25, fade: 0.35, saturation: 0.95, grain: 0.20
        ),

        LensProfile(
            id: "zeiss-biotar",
            name: "Zeiss Biotar",
            focal: "58 mm f/2",
            origin: "Allemagne · M42 / Exakta",
            era: "1936 – 1960",
            story: "L'original allemand dont l'Helios est la copie. Même tourbillon, mais avec un rendu un peu plus doux et raffiné. Plus rare et nettement plus cher que son clone soviétique.",
            swirl: 0.75, bubble: 0.20, softness: 0.30, glow: 0.35, vignette: 0.45,
            chroma: 0.30, warmth: 0.15, fade: 0.30, saturation: 0.97, grain: 0.15
        ),

        LensProfile(
            id: "trioplan",
            name: "Meyer-Optik Görlitz Trioplan",
            focal: "100 mm f/2.8",
            origin: "Allemagne (RDA) · M42 / Exakta",
            era: "1916 – 1970",
            story: "Un triplet optique tout simple dont l'aberration sphérique non corrigée produit le fameux bokeh « bulles de savon » : chaque point lumineux hors mise au point devient un anneau brillant.",
            swirl: 0.15, bubble: 1.00, softness: 0.40, glow: 0.40, vignette: 0.35,
            chroma: 0.40, warmth: 0.20, fade: 0.40, saturation: 1.02, grain: 0.15
        ),

        LensProfile(
            id: "summicron-50",
            name: "Leica Summicron",
            focal: "50 mm f/2",
            origin: "Allemagne · monture M / LTM",
            era: "1953 – aujourd'hui",
            story: "Le classique du reportage : micro-contraste superbe, rendu précis mais jamais clinique. Un « défaut » discret : un léger vignettage et une signature douce à pleine ouverture.",
            swirl: 0.00, bubble: 0.00, softness: 0.10, glow: 0.15, vignette: 0.25,
            chroma: 0.05, warmth: 0.05, fade: 0.12, saturation: 1.03, grain: 0.10
        ),

        LensProfile(
            id: "noctilux",
            name: "Leica Noctilux",
            focal: "50 mm f/1",
            origin: "Allemagne · monture M",
            era: "1976 – 2008",
            story: "Le roi de la nuit chez Leica. À f/1, l'image baigne dans un glow onirique, le vignettage est massif et la zone de netteté se réduit à un fil. Un rendu immédiatement reconnaissable.",
            swirl: 0.25, bubble: 0.10, softness: 0.50, glow: 0.80, vignette: 0.70,
            chroma: 0.25, warmth: 0.10, fade: 0.30, saturation: 0.92, grain: 0.15
        ),

        LensProfile(
            id: "canon-dream",
            name: "Canon « Dream Lens »",
            focal: "50 mm f/0.95",
            origin: "Japon · monture Canon 7",
            era: "1961 – 1970",
            story: "Quasi mythique, très peu produit. À f/0.95, le monde devient un rêve : halos généreux, contraste évanescent, netteté fragile. C'est précisément ce voile onirique qui fait sa légende.",
            swirl: 0.30, bubble: 0.15, softness: 0.70, glow: 1.00, vignette: 0.65,
            chroma: 0.45, warmth: 0.15, fade: 0.50, saturation: 0.88, grain: 0.20
        ),

        LensProfile(
            id: "super-takumar",
            name: "Pentax Super Takumar",
            focal: "50 mm f/1.4",
            origin: "Japon · monture M42",
            era: "1964 – 1975",
            story: "Son verre au thorium, légèrement radioactif, jaunit avec les décennies et donne aux images une chaleur dorée inimitable. Construction magnifique, mise au point soyeuse.",
            swirl: 0.10, bubble: 0.10, softness: 0.20, glow: 0.30, vignette: 0.35,
            chroma: 0.15, warmth: 0.85, fade: 0.25, saturation: 1.00, grain: 0.15
        ),

        LensProfile(
            id: "noct-nikkor",
            name: "Noct-Nikkor",
            focal: "58 mm f/1.2",
            origin: "Japon · monture F",
            era: "1977 – 1997",
            story: "Conçu pour photographier la nuit : sa lentille asphérique polie à la main dompte le coma des points lumineux. Contraste élevé pour son époque, léger halo à pleine ouverture.",
            swirl: 0.10, bubble: 0.05, softness: 0.15, glow: 0.45, vignette: 0.50,
            chroma: 0.10, warmth: 0.00, fade: 0.15, saturation: 1.05, grain: 0.25
        ),

        LensProfile(
            id: "angenieux",
            name: "Angénieux Cinéma",
            focal: "zoom 25–250 mm",
            origin: "France · montures ciné",
            era: "1956 – aujourd'hui",
            story: "Les zooms de cinéma légendaires de Pierre Angénieux, utilisés d'Hollywood à la Nouvelle Vague. Rendu ciné par excellence : contraste doux, couleurs chaudes, grain présent.",
            swirl: 0.05, bubble: 0.10, softness: 0.25, glow: 0.40, vignette: 0.40,
            chroma: 0.20, warmth: 0.30, fade: 0.45, saturation: 0.90, grain: 0.45
        ),
    ]

    /// Caractéristiques affichées dans la fiche détaillée (label, valeur).
    var traits: [(String, Double)] {
        [
            ("Tourbillon", swirl),
            ("Bulles de savon", bubble),
            ("Douceur des bords", softness),
            ("Halo / glow", glow),
            ("Vignettage", vignette),
            ("Aberration chromatique", chroma),
            ("Dérive chaude", warmth),
            ("Voile / contraste bas", fade),
            ("Grain", grain),
        ]
    }
}
