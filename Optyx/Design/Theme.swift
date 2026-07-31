import Foundation
import SwiftUI

// MARK: - Couleurs hexadécimales

extension Color {

    /// Construit une couleur à partir d'un hexadécimal du site (« #b8d977 » ou
    /// « b8d977 », casse indifférente, forme courte à 3 chiffres acceptée).
    ///
    /// Cet initialiseur ne peut pas échouer : les accents viennent du catalogue et
    /// sont donc toujours valides, et un initialiseur optionnel obligerait chaque
    /// vue à un déballage qui n'a aucune conduite de repli sensée. En cas de chaîne
    /// invalide on tombe sur un gris franchement visible, qui saute aux yeux en
    /// revue plutôt que de se fondre dans le fond noir.
    ///
    /// Utiliser systématiquement cet initialiseur plutôt que `Color.orange`,
    /// `Color.gray` ou tout autre alias système : ceux-là sont dynamiques et se
    /// résolvent différemment selon l'apparence, ce qui ferait dériver la marque
    /// alors que le site fixe des valeurs sRGB constantes.
    init(hex: String, opacity: Double = 1) {
        var chaine = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if chaine.hasPrefix("#") {
            chaine.removeFirst()
        }
        if chaine.count == 3 {
            var doublee = ""
            for caractere in chaine {
                doublee.append(caractere)
                doublee.append(caractere)
            }
            chaine = doublee
        }
        guard chaine.count == 6, let valeur = UInt32(chaine, radix: 16) else {
            self = Color.gray
            return
        }
        self.init(hex: valeur, opacity: opacity)
    }

    /// Variante littérale, pour les constantes écrites en dur dans le code
    /// (`Color(hex: 0x131313)`). Les deux surcharges ne sont jamais ambiguës :
    /// un littéral texte ne peut pas produire un `UInt32`, ni l'inverse.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Thème

/// Toutes les constantes visuelles du site, transposées à 1 rem = 16 pt. Les tailles
/// du site sont fixes (rem, jamais de mise à l'échelle utilisateur) et
/// `Font.system(size:)` l'est aussi : la correspondance est exacte, il n'y a rien à
/// recalculer. Aucune valeur ne doit être réinventée dans une vue — c'est ainsi que
/// la version précédente s'était mise à diverger du site écran par écran.
enum Theme {

    // MARK: Couleurs

    enum Couleur {
        /// Orange de marque. C'est exactement `systemOrange` en apparence sombre,
        /// mais il est fixé en dur : `Color.orange` vire au ton clair si la vue est
        /// jamais rendue en apparence claire (aperçus Xcode, capture, partage).
        static let orange = Color(hex: 0xFF9F0A)

        /// Noir pur. Le site le pose hors contenu (encoche, barre d'accueil, rebond
        /// de défilement) et n'applique le dégradé qu'au contenu.
        static let fond = Color.black

        static let panneau = Color(hex: 0x131313)
        static let puce = Color(hex: 0x1C1C1E)
        static let texte = Color(hex: 0xF4F2EE)
        static let texteSecondaire = Color(hex: 0xD6D2CB)
        static let texteAttenue = Color(hex: 0xA8A29A)
        static let texteDiscret = Color(hex: 0x6E6862)
        /// Texte posé sur l'orange (puce active, bouton d'appel) : un brun très
        /// sombre, pas du noir — le noir pur sur orange vibre à petite taille.
        static let texteSurAccent = Color(hex: 0x1A1000)
        static let textePuce = Color(hex: 0xDDDDDD)
        static let bordure = Color(hex: 0x222222)
        /// Rail des barres de caractéristique et filets de séparation.
        static let rail = Color(hex: 0x262626)
        /// Numéro « 01 »…« 09 » sur la scène.
        static let numeroCarte = Color.white.opacity(0.55)
    }

    // MARK: Fonds

    enum Fond {
        /// Fond de page. Une ellipse large de 120 % centrée AU-DESSUS du cadre :
        /// un `RadialGradient` circulaire donnerait un halo trop haut et trop
        /// étroit, et le dégradé cesserait de ressembler à celui du site.
        static let page = EllipticalGradient(
            stops: [
                Gradient.Stop(color: Color(hex: 0x1C1917), location: 0),
                Gradient.Stop(color: Color(hex: 0x0A0A0A), location: 0.5),
                Gradient.Stop(color: Color.black, location: 1)
            ],
            center: UnitPoint(x: 0.5, y: -0.05),
            startRadiusFraction: 0,
            endRadiusFraction: 0.6
        )

        /// Cadre de la scène du héros, sous le rendu Metal.
        static let cadreScene = EllipticalGradient(
            stops: [
                Gradient.Stop(color: Color(hex: 0x191512), location: 0),
                Gradient.Stop(color: Color(hex: 0x0B0A09), location: 0.6),
                Gradient.Stop(color: Color(hex: 0x030303), location: 1)
            ],
            center: UnitPoint(x: 0.5, y: 0.42),
            startRadiusFraction: 0,
            endRadiusFraction: 0.425
        )

        /// Remplissage d'une barre de caractéristique et du curseur d'intensité :
        /// de l'orange de marque vers l'accent de l'objectif.
        static func degradeTrait(accent: Color) -> LinearGradient {
            LinearGradient(
                colors: [Theme.Couleur.orange, accent],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    // MARK: Voiles de scène

    enum Voile {
        /// Vignette : à poser sur un rectangle débordant de 10 % de chaque côté,
        /// sinon le coin sombre s'arrête net sur le bord du cadre.
        static let vignette = EllipticalGradient(
            stops: [
                Gradient.Stop(color: Color.clear, location: 0.55),
                Gradient.Stop(color: Color.black.opacity(0.75), location: 1)
            ],
            center: UnitPoint(x: 0.5, y: 0.46),
            startRadiusFraction: 0,
            endRadiusFraction: 0.35
        )
        /// Débordement de la vignette, en fraction de la taille du cadre.
        static let debordementVignette: CGFloat = 0.10

        /// Brume : à composer en `.screen`. En alpha normal elle laverait les noirs
        /// de la scène et le fond passerait du charbon au gris souris.
        static let brume = Color(hex: 0xFFF2E2)
        static let opaciteBrume: Double = 0.22

        static let soleilCentre = Color(hex: 0xFFD882)
        static let soleilBord = Color(hex: 0xFFB450)
        /// Diamètre du soleil en fraction de la largeur de la scène : version carte
        /// puis version héros.
        static let largeurSoleilCarte: CGFloat = 0.34
        static let largeurSoleilHero: CGFloat = 0.46
        /// Le flou CSS vaut deux fois le rayon SwiftUI.
        static let flouSoleilCarte: CGFloat = 2
        static let flouSoleilHero: CGFloat = 3
        static let dureeRespirationSoleil: Double = 7

        /// Hauteur des bandes CinemaScope, en fraction de la hauteur de la scène.
        static let hauteurBandesCarte: CGFloat = 0.14
        static let hauteurBandesHero: CGFloat = 0.12

        /// Grain : `.overlay` EXIGE un `.compositingGroup()` sur la pile, faute de
        /// quoi le mélange se fait contre le fond de fenêtre et le grain vire au gris.
        static let opaciteGrain: Double = 0.35
    }

    // MARK: Typographie

    enum Police {
        static let marque = Font.system(size: 14, weight: .bold)
        static let accrocheHero = Font.system(size: 16)
        static let titreLegende = Font.system(size: 20, weight: .heavy)
        static let signatureLegende = Font.system(size: 15, weight: .semibold)
        static let puce = Font.system(size: 14, weight: .semibold)
        static let valeurIntensite = Font.system(size: 16, weight: .heavy)
        static let numeroCarte = Font.system(size: 13, weight: .bold)
        static let nomObjectif = Font.system(size: 22, weight: .heavy)
        static let focale = Font.system(size: 15, weight: .bold)
        static let signatureCarte = Font.system(size: 16, weight: .bold)
        static let meta = Font.system(size: 13, weight: .semibold)
        static let recit = Font.system(size: 15)
        static let labelTrait = Font.system(size: 13)
        static let resumeFiche = Font.system(size: 14, weight: .bold)
        static let specTerme = Font.system(size: 14)
        static let specValeur = Font.system(size: 14)
        static let anecdote = Font.system(size: 14)
        static let titreFin = Font.system(size: 24, weight: .heavy)
        static let paragrapheFin = Font.system(size: 15)
        static let cta = Font.system(size: 16, weight: .heavy)
        static let credit = Font.system(size: 15)
        static let copyright = Font.system(size: 13)

        /// `clamp(1.8rem, 7.2vw, 3.4rem)` : sur un iPhone de 390 pt le terme
        /// proportionnel tombe sous le minimum, donc 29 pt en compact.
        static func tailleTitreHero(largeur: CGFloat) -> CGFloat {
            min(max(29, largeur * 0.072), 54)
        }

        static func titreHero(largeur: CGFloat) -> Font {
            Font.system(size: tailleTitreHero(largeur: largeur), weight: .heavy)
        }
    }

    /// Approche en points du `letter-spacing` du site (em × taille).
    enum Tracking {
        static let marque: CGFloat = 7
        static let titreLegende: CGFloat = -0.2
        static let numeroCarte: CGFloat = 1.3
        static let nomObjectif: CGFloat = -0.22
        static let meta: CGFloat = 0.78
        static let titreFin: CGFloat = -0.24

        static func titreHero(largeur: CGFloat) -> CGFloat {
            -0.02 * Theme.Police.tailleTitreHero(largeur: largeur)
        }
    }

    /// SwiftUI n'a pas de `line-height` : `lineSpacing` AJOUTE de l'espace au-delà
    /// de la hauteur de ligne par défaut (≈ 1,21 × taille pour SF). D'où
    /// `lineSpacing = arrondi(taille × (lh − 1,21))`.
    ///
    /// Le titre du héros a un `line-height` de 1.08, INFÉRIEUR au défaut : aucun
    /// `lineSpacing` ne peut le produire. Le site coupe déjà la ligne à la main —
    /// empiler deux `Text` dans un `VStack(spacing: interligneTitreHero)`, jamais un
    /// `Text` multiligne, sinon le titre respire trop et perd son côté affiche.
    enum Interligne {
        /// Corps à 15 et 16 pt, `line-height` 1.55.
        static let recit: CGFloat = 5
        /// Anecdotes à 14 pt, `line-height` 1.5.
        static let anecdote: CGFloat = 4
        /// Écart vertical entre les deux lignes du titre du héros.
        static let titreHero: CGFloat = -2
    }

    // MARK: Géométrie

    enum Rayon {
        static let carte: CGFloat = 20
        static let scene: CGFloat = 20
        /// Rail et remplissage des barres de caractéristique.
        static let trait: CGFloat = 3
    }

    enum Espace {
        static let margeSection: CGFloat = 18
        static let largeurMax: CGFloat = 1100
        static let ecartCartes: CGFloat = 26
        static let epaisseurBordure: CGFloat = 1

        // Héros
        static let paddingHero = EdgeInsets(top: 40, leading: 22, bottom: 8, trailing: 22)
        /// Au-delà du point de rupture, le héros descend à 64 pt du haut.
        static let paddingHautHeroLarge: CGFloat = 64
        static let largeurMaxAccroche: CGFloat = 544
        static let hauteurMaxSceneHero: CGFloat = 420
        /// La scène du héros occupe 52 % de la hauteur, plafonnée.
        static let fractionHauteurSceneHero: CGFloat = 0.52

        // Terrain de jeu
        static let paddingRangeePuces = EdgeInsets(top: 12, leading: 18, bottom: 6, trailing: 18)
        static let paddingPuce = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        static let ecartPuces: CGFloat = 10
        static let ecartCurseur: CGFloat = 14
        static let hauteurRailCurseur: CGFloat = 6
        static let diametrePouceCurseur: CGFloat = 30
        static let largeurValeurIntensite: CGFloat = 51

        // Grille et cartes
        static let paddingGrille = EdgeInsets(top: 10, leading: 18, bottom: 30, trailing: 18)
        static let paddingCorpsCarte = EdgeInsets(top: 16, leading: 18, bottom: 20, trailing: 18)
        static let proportionSceneCarte: CGFloat = 4.0 / 3.0
        static let margeTitreSurScene: CGFloat = 18
        static let margeBasTitreSurScene: CGFloat = 14
        static let margeHautNumeroCarte: CGFloat = 14
        static let margeDroiteNumeroCarte: CGFloat = 16

        // Caractéristiques
        static let ecartTraits: CGFloat = 8
        static let ecartColonnesTraits: CGFloat = 12
        static let hauteurRailTrait: CGFloat = 6

        // Fiche technique dépliable
        static let margeHautFiche: CGFloat = 14
        static let paddingHautFiche: CGFloat = 12
        /// Le terme d'une ligne de spec occupe 42 % de la largeur disponible.
        static let fractionTermeSpec: CGFloat = 0.42
        static let ecartLignesSpecs: CGFloat = 8
        static let ecartColonnesSpecs: CGFloat = 10
        static let retraitAnecdotes: CGFloat = 18
        static let ecartAnecdotes: CGFloat = 8

        // Section de fin et pied de page
        static let paddingSectionFin = EdgeInsets(top: 34, leading: 26, bottom: 10, trailing: 26)
        static let largeurMaxSectionFin: CGFloat = 576
        static let paddingCTA = EdgeInsets(top: 14, leading: 26, bottom: 14, trailing: 26)
        static let margeHautCTA: CGFloat = 18
        static let paddingPied = EdgeInsets(top: 30, leading: 20, bottom: 26, trailing: 20)
        static let ecartLignesPied: CGFloat = 8
    }

    /// Le flou d'une ombre CSS vaut le double du rayon SwiftUI.
    enum Ombre {
        static let couleurTitreSurScene = Color.black.opacity(0.8)
        static let rayonTitreSurScene: CGFloat = 9
        static let decalageTitreSurScene: CGFloat = 2

        static let couleurPouceCurseur = Color.black.opacity(0.6)
        static let rayonPouceCurseur: CGFloat = 5
        static let decalagePouceCurseur: CGFloat = 2
    }

    // MARK: Adaptatif

    /// Le contenu ne change JAMAIS d'un palier à l'autre : seul le nombre de
    /// colonnes bouge. Ne pas utiliser `GridItem(.adaptive:)`, qui donnerait trois
    /// colonnes sur un iPhone Max en paysage — un cas que le site n'a jamais.
    static func colonnes(largeur: CGFloat) -> Int {
        if largeur >= 1024 { return 3 }
        if largeur >= 700 { return 2 }
        return 1
    }

    static let ruptureDeuxColonnes: CGFloat = 700
    static let ruptureTroisColonnes: CGFloat = 1024

    /// Durée de la bascule d'ouverture de la fiche technique.
    static let dureeDepliage: Double = 0.2
}

// MARK: - Accent d'objectif dans l'environnement

/// Rejoue la cascade de la variable CSS `--accent` du site : la carte et le terrain
/// de jeu la posent une fois, toutes les vues filles la lisent. La faire descendre
/// en paramètre à travers cinq niveaux de vues serait la garantie qu'un niveau
/// l'oublie et retombe sur l'orange.
private struct AccentObjectifKey: EnvironmentKey {
    static let defaultValue: Color = Theme.Couleur.orange
}

extension EnvironmentValues {
    var accentObjectif: Color {
        get { self[AccentObjectifKey.self] }
        set { self[AccentObjectifKey.self] = newValue }
    }
}
