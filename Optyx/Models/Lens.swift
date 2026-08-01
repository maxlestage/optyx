import CoreGraphics
import Foundation

// MARK: - Paramètres du disque de bokeh

/// Les 14 réglages du disque de bokeh. C'est le SEUL jeu de paramètres du moteur :
/// les scènes animées du catalogue et le rendu d'une photo du studio consomment la
/// même structure et le même profil de disque. La version précédente de l'app avait
/// deux chemins de rendu distincts, et l'utilisateur a passé une douzaine
/// d'itérations à répéter « ça ne se voit pas, ce n'est pas comme le site » : ce
/// qu'il voyait dans la liste n'était tout simplement pas ce qui était appliqué.
///
/// Toutes les valeurs sont dans [0, 1] SAUF `size`, que le Canon f/0.95 pousse à 1.2.
struct BokehParams: Hashable {

    /// Rotation différentielle du champ hors mise au point : les disques loin de
    /// l'axe tournent plus vite que ceux du centre, et l'arrière-plan s'enroule en
    /// spirale. Ce n'est pas un effet de style mais la conséquence de la courbure de
    /// champ et de l'astigmatisme d'un double Gauss non corrigé (Biotar, Helios).
    var swirl: Float = 0

    /// Diamètre du cercle de confusion, c'est-à-dire l'ouverture perçue : un point
    /// lumineux hors mise au point s'étale d'autant plus que le diaphragme est grand.
    /// Seule valeur du catalogue à dépasser 1 (Canon « Dream Lens », f/0.95). Ne
    /// JAMAIS la borner à 1 côté shader : l'énormité des disques est tout l'intérêt
    /// de cet objectif, la brider le ramènerait au rendu d'un 50 mm f/1.4 quelconque.
    var size: Float = 0.6

    /// Liseré lumineux sur le pourtour du disque, dû à l'aberration sphérique
    /// sous-corrigée qui concentre les rayons marginaux au bord. C'est ce qui
    /// distingue un bokeh « nerveux » d'un bokeh crémeux.
    var rim: Float = 0

    /// Douceur du bord du disque : sur-correction sphérique (bord fondu, bokeh
    /// crémeux) contre sous-correction (bord franc, bokeh dessiné). Le paramètre
    /// contrôle la largeur de la transition, pas la taille.
    var soft: Float = 0.3

    /// Frange chromatique : le profil du disque est évalué à trois échelles
    /// légèrement différentes pour R, G et B. C'est l'aberration chromatique
    /// longitudinale, qui borde les points lumineux de vert devant et de magenta
    /// derrière le plan de netteté.
    var fringe: Float = 0

    /// Œil de chat : le vignettage mécanique du barillet tronque les disques
    /// périphériques en amande, orientée vers le centre du cadre. Le décalage
    /// doit rester borné à une longueur de 1, sinon les disques des coins sont
    /// entièrement rognés et disparaissent de l'image.
    var cat: Float = 0

    /// Voile de diffusion enveloppant les hautes lumières — la lumière parasite
    /// des verres anciens non traités multicouche. C'est le glow du Noctilux à f/1,
    /// pas un flou : il ne doit pas réduire la netteté du sujet.
    var haze: Float = 0

    /// Creusement du disque en anneau : l'aberration sphérique non corrigée d'un
    /// triplet vide le centre du disque et empile l'énergie sur le bord. C'est le
    /// bokeh « bulles de savon » du Trioplan, à 1 chez lui seul.
    var ring: Float = 0

    /// Ascension lente des disques dans le cadre, comme des bulles qui montent.
    /// Purement scénique : sert l'animation du catalogue, sans effet sur une photo fixe.
    var rise: Float = 0

    /// Dérive latérale du champ, imitant un panoramique de caméra. Comme `rise`,
    /// c'est une animation de scène et non une propriété optique.
    var pan: Float = 0

    /// Scintillement des points lumineux restés nets. Sur les objectifs très
    /// corrigés (Summicron, Noct-Nikkor), les hautes lumières ne s'étalent pas :
    /// elles palpitent. C'est le seul mouvement visible d'une scène « nette ».
    var twinkle: Float = 0

    /// Aigrettes de diffraction rayonnant des points lumineux, dessinées par les
    /// lamelles du diaphragme. Signature des optiques nocturnes fermées.
    var spike: Float = 0

    /// Grain argentique superposé au rendu. Attention au piège de nommage : ce
    /// drapeau de rendu (angenieux uniquement) n'a rien à voir avec le trait
    /// d'affichage « Grain » présent chez huit objectifs sur neuf.
    var grain: Float = 0

    /// Fondu global du calque optique sur l'image source — le curseur d'intensité.
    /// La composition doit rester en maximum ou en écran : mélanger en alpha normal
    /// resommerait des canaux déjà prémultipliés (alpha 1 + 1 + 1 = 3) et noircirait
    /// l'image deux fois. C'est exactement le bug qui a coulé la version précédente.
    var opacity: Float = 1
}

// MARK: - Éléments d'affichage

/// Une ligne de la fiche technique (terme / valeur).
///
/// Un tuple `(String, String)` serait plus court mais les tuples ne conforment pas à
/// `Hashable`, donc `Lens` ne pourrait plus l'être. Conséquence assumée du
/// `let id = UUID()` : la conformité `Hashable` synthétisée inclut l'UUID, donc deux
/// `Spec` de contenu identique sont considérées différentes. C'est sans importance
/// ici — ces valeurs ne servent qu'à identifier des lignes dans un `ForEach`, jamais
/// à dédoublonner ni à comparer du contenu.
struct Spec: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
}

/// Une caractéristique affichée en barre horizontale, valeur dans [0, 1].
///
/// Les libellés ne forment pas un ensemble fixe et chaque objectif en porte entre 5
/// et 7, déjà triés par valeur décroissante : un radar à axes fixes est donc
/// impossible, seule une liste de barres rend la donnée telle qu'elle est.
/// Même remarque que `Spec` sur l'UUID et l'égalité.
struct Trait: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: Double
}

// MARK: - Objectif

/// Un objectif du catalogue. Les treize premières propriétés sont les données du
/// site ; les cinq dernières décrivent l'habillage de sa scène et portent des
/// valeurs par défaut pour que l'initialiseur mémberwise reste utilisable sans elles.
struct Lens: Identifiable, Hashable {
    let id: String
    let name: String
    /// Focale et ouverture, en toutes lettres : « 58 mm f/2 ».
    let focal: String

    /// FOCALE RÉELLE du verre, en millimètres pour un capteur 24×36.
    ///
    /// Elle est déduite de `focal`, qui reste la source unique — la chaîne
    /// affichée sur la fiche et le nombre utilisé par la caméra ne peuvent donc
    /// pas diverger. Le repli à 50 mm couvre le cas de l'Angénieux, dont la
    /// fiche annonce « zoom 25–250 mm » : on retient la position de référence
    /// choisie pour la simulation, la plus employée en tournage.
    var focaleMM: Double {
        // Premier nombre de la chaîne, avant « mm ». « 58 mm f/2 » → 58,
        // « zoom 25–250 mm » → 25, qu'on écarte au profit de 50.
        if focal.hasPrefix("zoom") { return 50 }
        let chiffres = focal.prefix { $0.isNumber }
        return Double(chiffres) ?? 50
    }

    /// FACTEUR DE ZOOM qui donne à cet objectif son cadrage réel.
    ///
    /// L'objectif principal d'un iPhone couvre l'équivalent d'un 26 mm. Un
    /// Trioplan 100 mm voit donc presque quatre fois plus serré, et un
    /// Summicron 50 mm environ deux fois. Sans cette correspondance, les neuf
    /// verres cadrent identique — ce qui est faux, et se remarque tout de
    /// suite : la focale est la première chose qu'on perçoit d'un objectif,
    /// avant même son bokeh.
    ///
    /// Borné à 1 par le bas : descendre sous 1 exigerait l'ultra grand-angle,
    /// une caméra PHYSIQUEMENT différente, dont le champ, la distorsion et le
    /// bruit ne correspondent à aucun des neuf verres.
    var zoomEquivalent: CGFloat {
        max(1, CGFloat(focaleMM / 26.0))
    }
    let origin: String
    let era: String
    let story: String
    /// Phrase d'accroche, guillemets français inclus dans la donnée.
    let signature: String
    /// Couleur d'accent en hexadécimal, telle qu'écrite sur le site (minuscules,
    /// préfixe `#`). Consommer avec `Color(hex:)`, jamais avec `Color.orange` ou un
    /// autre alias système : ceux-là se résolvent différemment selon l'apparence et
    /// feraient dériver la teinte de l'objectif.
    let accent: String
    /// Couleurs des disques de bokeh (3 teintes, sauf Angénieux qui n'en a que 2).
    let palette: [String]
    let bokeh: BokehParams
    let specs: [Spec]
    let facts: [String]
    let traits: [Trait]

    /// Identifiant de scène du site (`swirl`, `swirl-soft`, `bubbles`, `crisp`,
    /// `night`, `dream`, `gold`, `stars`, `cine`). Conservé en chaîne brute :
    /// `swirl-soft` contient un tiret, qu'aucune conversion naïve vers un
    /// identifiant Swift ne franchit proprement.
    var scene: String = ""
    /// Seconde palette, froide, propre à l'Angénieux : son rendu ciné oppose deux
    /// teintes complémentaires. Vide partout ailleurs.
    var duo: [String] = []
    /// Bandes CinemaScope noires en haut et en bas de la scène.
    var bars: Bool = false
    /// Halo de soleil dans un angle de la scène.
    var sun: Bool = false
    /// Respiration lente de la scène (échelle et opacité), pour les objectifs
    /// dont le rendu est déjà mou : sans elle, leur vignette paraît figée.
    var breathe: Bool = false
}

// MARK: - Catalogue

extension Lens {

    /// Les neuf objectifs, dans l'ordre du site. Pas d'entrée « Neutre » : le site
    /// n'en a pas, et la comparaison avant/après se fait au curseur d'intensité.
    static let catalog: [Lens] = [

        Lens(
            id: "helios-44-2",
            name: "Helios 44-2",
            focal: "58 mm f/2",
            origin: "URSS · monture M42",
            era: "1958 – années 1990",
            story: "Copie soviétique du Zeiss Biotar, produit à des millions d'exemplaires. Son bokeh tourbillonnant culte transforme les arrière-plans en spirale autour du sujet. Très abordable, c'est la porte d'entrée du monde vintage.",
            signature: "« L'arrière-plan tournoie. Littéralement. »",
            accent: "#b8d977",
            palette: ["#dff5ab", "#f4e4a6", "#b6d47f"],
            bokeh: BokehParams(swirl: 1, size: 0.55, rim: 0.38, soft: 0.3, fringe: 0.055, cat: 0.62, haze: 0.04),
            specs: [
                Spec(label: "Formule optique", value: "6 éléments en 4 groupes (double Gauss)"),
                Spec(label: "Diaphragme", value: "8 lamelles"),
                Spec(label: "Mise au point mini", value: "0,5 m"),
                Spec(label: "Poids", value: "≈ 230 g"),
                Spec(label: "Fabrication", value: "KMZ, MMZ, Valdaï — plusieurs millions d'exemplaires"),
                Spec(label: "Cote actuelle", value: "≈ 30–80 € en occasion")
            ],
            facts: [
                "Né des réparations de guerre : les plans et l'outillage du Zeiss Biotar ont été transférés d'Allemagne vers l'URSS après 1945.",
                "Le tourbillon vient d'un défaut assumé — la courbure de champ et l'astigmatisme étirent le bokeh en arcs autour du sujet.",
                "Monté d'origine sur les reflex Zenit, il reste l'objectif vintage le plus vendu au monde — la porte d'entrée idéale."
            ],
            traits: [
                Trait(label: "Tourbillon", value: 1),
                Trait(label: "Vignettage", value: 0.45),
                Trait(label: "Aberration chromatique", value: 0.35),
                Trait(label: "Douceur des bords", value: 0.3),
                Trait(label: "Halo / glow", value: 0.3),
                Trait(label: "Dérive chaude", value: 0.25),
                Trait(label: "Grain", value: 0.2)
            ],
            scene: "swirl"
        ),

        Lens(
            id: "zeiss-biotar",
            name: "Zeiss Biotar",
            focal: "58 mm f/2",
            origin: "Allemagne · M42 / Exakta",
            era: "1936 – 1960",
            story: "L'original allemand dont l'Helios est la copie. Même tourbillon, mais avec un rendu un peu plus doux et raffiné. Plus rare et nettement plus cher que son clone soviétique.",
            signature: "« Le même vertige, en gants de velours. »",
            accent: "#a8c4b8",
            palette: ["#dcecdf", "#efe9d2", "#bfd3c6"],
            bokeh: BokehParams(swirl: 0.68, size: 0.6, rim: 0.28, soft: 0.42, fringe: 0.04, cat: 0.5, haze: 0.08),
            specs: [
                Spec(label: "Formule optique", value: "6 éléments en 4 groupes (double Gauss)"),
                Spec(label: "Conception", value: "Willy Merté, Carl Zeiss Iéna, 1936"),
                Spec(label: "Diaphragme", value: "jusqu'à 17 lamelles selon les versions"),
                Spec(label: "Montures", value: "Exakta, M42"),
                Spec(label: "Cote actuelle", value: "≈ 150–400 € en occasion")
            ],
            facts: [
                "L'original dont l'Helios est la copie : même formule, verre et assemblage allemands d'avant-guerre.",
                "Son grand frère, le Biotar 75 mm f/1.5, est considéré comme le roi absolu du bokeh tourbillonnant — et coté en conséquence.",
                "Les premières versions à 17 lamelles donnent des ronds de bokeh parfaitement circulaires à toutes les ouvertures."
            ],
            traits: [
                Trait(label: "Tourbillon", value: 0.85),
                Trait(label: "Vignettage", value: 0.38),
                Trait(label: "Halo / glow", value: 0.35),
                Trait(label: "Aberration chromatique", value: 0.3),
                Trait(label: "Douceur des bords", value: 0.25),
                Trait(label: "Grain", value: 0.15)
            ],
            scene: "swirl-soft",
            breathe: true
        ),

        Lens(
            id: "trioplan",
            name: "Meyer-Optik Görlitz Trioplan",
            focal: "100 mm f/2.8",
            origin: "Allemagne (RDA) · M42 / Exakta",
            era: "1916 – 1970",
            story: "Un triplet optique tout simple dont l'aberration sphérique non corrigée produit le fameux bokeh « bulles de savon » : chaque point lumineux hors mise au point devient un anneau brillant.",
            signature: "« Chaque lumière devient une bulle de savon. »",
            accent: "#e8c98a",
            palette: ["#ffe9c0", "#f6c874", "#fff2d8"],
            bokeh: BokehParams(size: 0.95, rim: 0.8, soft: 0.16, fringe: 0.06, cat: 0.22, haze: 0.04, ring: 1, rise: 0.34),
            specs: [
                Spec(label: "Formule optique", value: "3 éléments en 3 groupes (triplet de Cooke)"),
                Spec(label: "Diaphragme", value: "jusqu'à 15 lamelles"),
                Spec(label: "Mise au point mini", value: "≈ 1,1 m"),
                Spec(label: "Montures", value: "M42, Exakta"),
                Spec(label: "Cote actuelle", value: "≈ 250–600 € en occasion")
            ],
            facts: [
                "Trois lentilles seulement : c'est l'aberration sphérique non corrigée de cette formule minimaliste qui dessine les anneaux.",
                "Tombé dans l'oubli, il est devenu culte vers 2010 quand les photographes macro ont redécouvert ses « bulles de savon ».",
                "La marque Meyer Optik Görlitz a été ressuscitée en 2015 par financement participatif pour le refabriquer à l'identique."
            ],
            traits: [
                Trait(label: "Bulles de savon", value: 1),
                Trait(label: "Aberration chromatique", value: 0.45),
                Trait(label: "Halo / glow", value: 0.45),
                Trait(label: "Douceur des bords", value: 0.3),
                Trait(label: "Vignettage", value: 0.3),
                Trait(label: "Dérive chaude", value: 0.2)
            ],
            scene: "bubbles"
        ),

        Lens(
            id: "summicron-50",
            name: "Leica Summicron",
            focal: "50 mm f/2",
            origin: "Allemagne · monture M / LTM",
            era: "1953 – aujourd’hui",
            story: "Le classique du reportage : micro-contraste superbe, rendu précis mais jamais clinique. Un « défaut » discret : un léger vignettage et une signature douce à pleine ouverture.",
            signature: "« Le piqué qui a écrit l'histoire du reportage. »",
            accent: "#e8e4dc",
            palette: ["#f4f1e8", "#ffe4b4", "#c8d8ee"],
            // haze est écrit 0 à dessein sur les deux objectifs nets (ici et le
            // Noct-Nikkor) : c'est une absence de voile revendiquée, pas un oubli.
            bokeh: BokehParams(size: 0.24, rim: 0.16, soft: 0.12, fringe: 0.012, cat: 0.14, haze: 0, twinkle: 0.32),
            specs: [
                Spec(label: "Formule optique", value: "7 éléments en 6 groupes"),
                Spec(label: "Verre", value: "verres au lanthane haute réfraction"),
                Spec(label: "Diaphragme", value: "10 lamelles"),
                Spec(label: "Montures", value: "vissante Leica (LTM) puis M"),
                Spec(label: "Cote actuelle", value: "≈ 400–1 500 € selon version")
            ],
            facts: [
                "À sa sortie en 1953, c'était l'objectif standard le plus piqué jamais mesuré — la référence des laboratoires pendant des années.",
                "Le nom vient de « summit » (sommet) : la gamme Leica classe ses ouvertures par noms — Summicron pour f/2.",
                "C'est l'objectif de prédilection de générations de photoreporters, d'Henri Cartier-Bresson aux agences modernes."
            ],
            traits: [
                Trait(label: "Micro-contraste", value: 0.7),
                Trait(label: "Vignettage", value: 0.2),
                Trait(label: "Halo / glow", value: 0.15),
                Trait(label: "Douceur des bords", value: 0.1),
                Trait(label: "Grain", value: 0.1)
            ],
            scene: "crisp"
        ),

        Lens(
            id: "noctilux",
            name: "Leica Noctilux",
            focal: "50 mm f/1",
            origin: "Allemagne · monture M",
            era: "1976 – 2008",
            story: "Le roi de la nuit chez Leica. À f/1, l'image baigne dans un glow onirique, le vignettage est massif et la zone de netteté se réduit à un fil. Un rendu immédiatement reconnaissable.",
            signature: "« La nuit lui appartient, à f/1. »",
            accent: "#ffd894",
            palette: ["#ffe0a2", "#ffc478", "#bcd0ff"],
            bokeh: BokehParams(swirl: 0.2, size: 0.88, rim: 0.42, soft: 0.46, fringe: 0.045, cat: 0.56, haze: 0.14),
            specs: [
                Spec(label: "Formule optique", value: "7 éléments en 6 groupes, sans asphérique"),
                Spec(label: "Conception", value: "Walter Mandler, Leitz Canada, 1976"),
                Spec(label: "Diaphragme", value: "16 lamelles"),
                Spec(label: "Poids", value: "≈ 630 g — un monstre pour un 50 mm"),
                Spec(label: "Cote actuelle", value: "≈ 4 000–8 000 € en occasion")
            ],
            facts: [
                "Premier f/1 de série au monde en photo 24×36 — conçu au Canada, pas à Wetzlar, par le légendaire Walter Mandler.",
                "À pleine ouverture, la profondeur de champ à 1 m est d'environ 2 cm : la mise au point est un art à part entière.",
                "Son glow à f/1 n'est pas un défaut corrigé depuis : les versions modernes l'ont éliminé, et les puristes le regrettent."
            ],
            traits: [
                Trait(label: "Halo / glow", value: 0.95),
                Trait(label: "Vignettage", value: 0.65),
                Trait(label: "Douceur des bords", value: 0.45),
                Trait(label: "Tourbillon", value: 0.25),
                Trait(label: "Aberration chromatique", value: 0.25),
                Trait(label: "Grain", value: 0.15)
            ],
            scene: "night",
            breathe: true
        ),

        Lens(
            id: "canon-dream",
            name: "Canon « Dream Lens »",
            focal: "50 mm f/0.95",
            origin: "Japon · monture Canon 7",
            era: "1961 – 1970",
            story: "Quasi mythique, très peu produit. À f/0.95, le monde devient un rêve : halos généreux, contraste évanescent, netteté fragile. C'est précisément ce voile onirique qui fait sa légende.",
            signature: "« Le monde, vu à travers un rêve. »",
            accent: "#f2ddd2",
            palette: ["#fff2df", "#ffdce8", "#e4e9ff"],
            // size: 1.2 — seule valeur du catalogue hors de [0, 1]. Voir BokehParams.size.
            bokeh: BokehParams(swirl: 0.22, size: 1.2, rim: 0.2, soft: 0.72, fringe: 0.075, cat: 0.44, haze: 0.3),
            specs: [
                Spec(label: "Formule optique", value: "7 éléments en 5 groupes"),
                Spec(label: "Monture", value: "baïonnette du télémétrique Canon 7"),
                Spec(label: "Poids", value: "≈ 605 g"),
                Spec(label: "Production", value: "≈ 20 000 exemplaires (1961–1970)"),
                Spec(label: "Cote actuelle", value: "≈ 2 000–4 000 € en occasion")
            ],
            facts: [
                "« L'objectif le plus lumineux du monde » à sa sortie en 1961 — un demi-diaphragme devant l'œil humain, disait la publicité Canon.",
                "Son surnom de « Dream Lens » vient des photographes : à f/0.95, netteté fragile, halos et contraste évanescent font des images de rêve.",
                "Une version TV (monture C) équipait les caméras de surveillance et de télévision — souvent convertie aujourd'hui pour Leica M."
            ],
            traits: [
                Trait(label: "Halo / glow", value: 1),
                Trait(label: "Douceur des bords", value: 0.8),
                Trait(label: "Aberration chromatique", value: 0.5),
                Trait(label: "Vignettage", value: 0.5),
                Trait(label: "Tourbillon", value: 0.3),
                Trait(label: "Grain", value: 0.2)
            ],
            scene: "dream",
            breathe: true
        ),

        Lens(
            id: "super-takumar",
            name: "Pentax Super Takumar",
            focal: "50 mm f/1.4",
            origin: "Japon · monture M42",
            era: "1964 – 1975",
            story: "Son verre au thorium, légèrement radioactif, jaunit avec les décennies et donne aux images une chaleur dorée inimitable. Construction magnifique, mise au point soyeuse.",
            signature: "« L'or du thorium, patiné par soixante ans. »",
            accent: "#ffc55e",
            palette: ["#ffd07a", "#ffb152", "#ffe9ae"],
            bokeh: BokehParams(swirl: 0.06, size: 0.62, rim: 0.32, soft: 0.4, fringe: 0.03, cat: 0.3, haze: 0.16),
            specs: [
                Spec(label: "Formule optique", value: "7 éléments en 6 groupes (version courante)"),
                Spec(label: "Particularité", value: "verre au thorium légèrement radioactif"),
                Spec(label: "Mise au point mini", value: "0,45 m"),
                Spec(label: "Poids", value: "≈ 245 g"),
                Spec(label: "Cote actuelle", value: "≈ 50–150 € en occasion")
            ],
            facts: [
                "Le thorium du verre jaunit avec les décennies — c'est cette patine dorée, unique à chaque exemplaire, qui fait sa signature.",
                "Le jaunissement se corrige en exposant la lentille aux UV quelques jours… mais beaucoup préfèrent garder l'or.",
                "La rarissime première version à 8 éléments (1964) est l'un des 50 mm les plus recherchés des collectionneurs."
            ],
            traits: [
                Trait(label: "Dérive chaude", value: 1),
                Trait(label: "Halo / glow", value: 0.35),
                Trait(label: "Vignettage", value: 0.3),
                Trait(label: "Douceur des bords", value: 0.2),
                Trait(label: "Aberration chromatique", value: 0.15),
                Trait(label: "Grain", value: 0.15)
            ],
            scene: "gold",
            sun: true
        ),

        Lens(
            id: "noct-nikkor",
            name: "Noct-Nikkor",
            focal: "58 mm f/1.2",
            origin: "Japon · monture F",
            era: "1977 – 1997",
            story: "Conçu pour photographier la nuit : sa lentille asphérique polie à la main dompte le coma des points lumineux. Contraste élevé pour son époque, léger halo à pleine ouverture.",
            signature: "« Des étoiles nettes, un contraste qui mord. »",
            accent: "#aec6ff",
            palette: ["#f8f8ff", "#ffe8b4", "#b4caff"],
            // haze: 0 revendiqué, comme pour le Summicron.
            bokeh: BokehParams(size: 0.3, rim: 0.14, soft: 0.1, fringe: 0.018, cat: 0.1, haze: 0, twinkle: 0.45, spike: 0.55),
            specs: [
                Spec(label: "Formule optique", value: "7 éléments en 6 groupes, lentille frontale asphérique"),
                Spec(label: "Fabrication", value: "asphérique polie À LA MAIN par des maîtres opticiens"),
                Spec(label: "Diaphragme", value: "9 lamelles"),
                Spec(label: "Production", value: "≈ 11 000 exemplaires (1977–1997)"),
                Spec(label: "Cote actuelle", value: "≈ 3 000–5 000 € en occasion")
            ],
            facts: [
                "« Noct » pour nocturne : conçu pour photographier les points lumineux de nuit sans les ailes de coma qui les déforment.",
                "Sa lentille asphérique était polie à la main — quelques exemplaires par jour, par une poignée d'artisans chez Nikon.",
                "Longtemps sous-coté, il est devenu l'un des Nikkor manuels les plus chers depuis que les vidéastes l'ont redécouvert."
            ],
            traits: [
                Trait(label: "Micro-contraste", value: 0.85),
                Trait(label: "Halo / glow", value: 0.55),
                Trait(label: "Vignettage", value: 0.4),
                Trait(label: "Grain", value: 0.3),
                Trait(label: "Douceur des bords", value: 0.15)
            ],
            scene: "stars"
        ),

        Lens(
            id: "angenieux",
            name: "Angénieux Cinéma",
            focal: "zoom 25–250 mm",
            origin: "France · montures ciné",
            era: "1956 – aujourd’hui",
            story: "Les zooms de cinéma légendaires de Pierre Angénieux, utilisés d'Hollywood à la Nouvelle Vague. Rendu ciné par excellence : contraste doux, couleurs chaudes, grain présent.",
            signature: "« Hollywood et la Nouvelle Vague dans le même zoom. »",
            accent: "#f0a868",
            // Seul objectif à deux couleurs de palette seulement : le contraste
            // chaud/froid vient de `duo`, pas d'une troisième teinte chaude.
            palette: ["#ffc684", "#ffe6c0"],
            bokeh: BokehParams(size: 0.7, rim: 0.26, soft: 0.46, fringe: 0.035, cat: 0.36, haze: 0.1, pan: 0.55, grain: 1),
            specs: [
                Spec(label: "Gamme", value: "zooms ciné 35 mm et 16 mm (dont le 25–250 mm)"),
                Spec(label: "Inventions", value: "rétrofocus (1950), zooms 10× (années 1960)"),
                Spec(label: "Montures", value: "PL, PV, montures ciné historiques"),
                Spec(label: "Distinctions", value: "plusieurs Oscars techniques (Sci-Tech Awards)"),
                Spec(label: "Cote actuelle", value: "très variable — les zooms ciné vintage se louent plus qu'ils ne s'achètent")
            ],
            facts: [
                "Pierre Angénieux a inventé la formule rétrofocus en 1950 — celle qui équipe encore tous les grands-angles de reflex.",
                "Ses optiques sont allées sur la Lune : les caméras des missions Apollo embarquaient des objectifs Angénieux.",
                "De Godard à Hollywood : le rendu chaud et doux de ses zooms est devenu LE look du cinéma des années 1960–70."
            ],
            traits: [
                Trait(label: "Virage ciné", value: 0.85),
                Trait(label: "Grain", value: 0.6),
                Trait(label: "Halo / glow", value: 0.45),
                Trait(label: "Dérive chaude", value: 0.4),
                Trait(label: "Vignettage", value: 0.35),
                Trait(label: "Douceur des bords", value: 0.25)
            ],
            scene: "cine",
            duo: ["#7cc4c4", "#9adcdc"],
            bars: true
        )
    ]

    /// Repli sur le premier objectif plutôt qu'un optionnel : aucun appelant n'a de
    /// conduite sensée en cas d'identifiant inconnu, et le catalogue n'est jamais vide.
    static func lens(id: String) -> Lens {
        catalog.first { $0.id == id } ?? catalog[0]
    }

    /// Numéro affiché sur la scène, « 01 » à « 09 ».
    var indexLabel: String {
        let position = (Lens.catalog.firstIndex { $0.id == id } ?? 0) + 1
        return String(format: "%02d", position)
    }
}
