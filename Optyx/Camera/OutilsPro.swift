import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Format de cadrage de la photo.
///
/// Le recadrage est appliqué AVANT la chaîne d'effets, jamais après : le
/// vignettage et les masques du moteur sont exprimés en fraction du cadre, et
/// recadrer ensuite couperait un vignettage calculé pour un cadre plus large —
/// les coins du 1:1 seraient clairs alors qu'ils devraient être les plus
/// sombres.
enum FormatPhoto: String, CaseIterable, Identifiable {
    case natif = "4:3"
    case film = "3:2"
    case carre = "1:1"
    case large = "16:9"
    case xpan = "65:24"

    var id: String { rawValue }

    /// Rapport grand côté / petit côté. `nil` = on garde le cadre du capteur.
    var rapport: CGFloat? {
        switch self {
        case .natif: return nil
        case .film: return 3.0 / 2.0
        case .carre: return 1
        case .large: return 16.0 / 9.0
        case .xpan: return 65.0 / 24.0
        }
    }

    /// Libellé long, avec l'héritage argentique du format — c'est là que se
    /// trouve l'intérêt du choix, pas dans le rapport lui-même.
    var titre: String {
        switch self {
        case .natif: return "4:3 · natif"
        case .film: return "3:2 · film 135"
        case .carre: return "1:1 · 6×6"
        case .large: return "16:9"
        case .xpan: return "65:24 · XPan"
        }
    }
}

/// Réglages des aides visuelles du viseur.
///
/// RÈGLE ABSOLUE : ces aides ne touchent QUE l'affichage. Elles sont posées sur
/// une copie destinée à l'écran, après que le tampon enregistré a été écrit. Ni
/// les photos ni les vidéos ne les portent — des zébras gravés dans un fichier
/// seraient une catastrophe silencieuse, découverte des semaines plus tard.
struct ReglagesOutils: Equatable {
    var zebras = false
    var peaking = false
    var grille = false
    /// L'histogramme n'est PAS une aide dessinée : c'est une vue SwiftUI posée
    /// par-dessus le viseur, et son coût est une mesure GPU→CPU, pas un nœud de
    /// plus dans le graphe. Il est donc exclu de `aucuneAideDessinee`.
    var histogramme = false

    var aucuneAideDessinee: Bool { !zebras && !peaking && !grille }
}

/// Aides visuelles du viseur : zébras, focus peaking, grille des tiers.
enum OutilsPro {

    /// Superpose les aides demandées. Rend l'image inchangée si aucune ne l'est
    /// — le graphe Core Image n'est alors pas allongé d'un seul nœud.
    static func aides(sur image: CIImage, reglages: ReglagesOutils) -> CIImage {
        guard !reglages.aucuneAideDessinee else { return image }
        let cadre = image.extent
        guard !cadre.isEmpty, !cadre.isInfinite else { return image }

        // Transparent, et non noir : c'est le fond sur lequel chaque aide est
        // découpée avant d'être composée. Un fond noir voilerait l'image
        // partout où l'aide est absente.
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: cadre)
        var sortie = image

        if reglages.zebras {
            sortie = zebras(sur: sortie, cadre: cadre, transparent: transparent)
        }
        if reglages.peaking {
            sortie = peaking(sur: sortie, cadre: cadre, transparent: transparent)
        }
        if reglages.grille {
            sortie = grille(sur: sortie, cadre: cadre)
        }
        return sortie
    }

    /// ZÉBRAS — hachures diagonales sur les zones brûlées.
    ///
    /// Seuil à 0,95 et non 1,0 : un capteur écrête progressivement, et attendre
    /// la saturation complète signalerait le problème trop tard pour le
    /// corriger à la prise de vue.
    private static func zebras(sur image: CIImage,
                               cadre: CGRect,
                               transparent: CIImage) -> CIImage {
        let luminance = image.applyingFilter("CIColorControls",
                                             parameters: [kCIInputSaturationKey: 0])
        let brulees = luminance.applyingFilter("CIColorThreshold",
                                               parameters: ["inputThreshold": 0.95])

        let generateur = CIFilter.stripesGenerator()
        generateur.center = .zero
        generateur.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        generateur.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        // Largeur en pixels du cadre de TRAVAIL, pas de l'écran : à 4 px fixes,
        // les hachures deviendraient un aplat gris à l'export 3200 px.
        generateur.width = Float(max(3, min(cadre.width, cadre.height) * 0.006))
        generateur.sharpness = 1

        guard let hachures = generateur.outputImage?
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: cadre) else { return image }

        let decoupe = CIFilter.blendWithMask()
        decoupe.inputImage = hachures
        decoupe.backgroundImage = transparent
        decoupe.maskImage = brulees
        guard let zebre = decoupe.outputImage else { return image }
        return zebre.composited(over: image)
    }

    /// FOCUS PEAKING — surlignage vert des contours nets.
    ///
    /// Il est calculé sur l'image RENDUE, donc APRÈS la défocalisation du
    /// moteur : c'est ce qui en fait un outil honnête. Un peaking calculé sur
    /// le flux brut surlignerait un arrière-plan que l'objectif va rendre flou,
    /// et indiquerait une netteté que la photo n'aura pas.
    private static func peaking(sur image: CIImage,
                                cadre: CGRect,
                                transparent: CIImage) -> CIImage {
        let contours = image
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.30])

        // Vert : la seule teinte qu'aucun des neuf objectifs ne pousse
        // franchement, donc la seule qu'on ne risque pas de confondre avec la
        // dérive du verre. Un peaking rouge serait illisible sur un Takumar.
        let vert = CIImage(color: CIColor(red: 0.25, green: 1, blue: 0.3, alpha: 0.85))
            .cropped(to: cadre)

        let decoupe = CIFilter.blendWithMask()
        decoupe.inputImage = vert
        decoupe.backgroundImage = transparent
        decoupe.maskImage = contours
        guard let surlignage = decoupe.outputImage else { return image }
        return surlignage.composited(over: image)
    }

    /// GRILLE DES TIERS, alignée sur l'image rendue — donc sur le format choisi,
    /// letterbox compris, et non sur l'écran.
    private static func grille(sur image: CIImage, cadre: CGRect) -> CIImage {
        let couleur = CIColor(red: 1, green: 1, blue: 1, alpha: 0.4)
        let epaisseur = max(1, min(cadre.width, cadre.height) * 0.0015)
        var sortie = image
        for tiers in 1...2 {
            let x = cadre.minX + cadre.width * CGFloat(tiers) / 3 - epaisseur / 2
            let verticale = CGRect(x: x, y: cadre.minY,
                                   width: epaisseur, height: cadre.height)
            sortie = CIImage(color: couleur).cropped(to: verticale).composited(over: sortie)

            let y = cadre.minY + cadre.height * CGFloat(tiers) / 3 - epaisseur / 2
            let horizontale = CGRect(x: cadre.minX, y: y,
                                     width: cadre.width, height: epaisseur)
            sortie = CIImage(color: couleur).cropped(to: horizontale).composited(over: sortie)
        }
        return sortie
    }

    /// Recadrage centré au rapport demandé.
    ///
    /// Centré et non ancré : un recadrage ancré en haut ferait glisser le sujet
    /// hors du cadre au changement de format, alors que l'utilisateur vient
    /// justement de le composer.
    static func recadrer(_ image: CIImage, rapport: CGFloat?) -> CIImage {
        guard let rapport, rapport > 0 else { return image }
        let cadre = image.extent
        guard cadre.width > 0, cadre.height > 0 else { return image }

        let portrait = cadre.height >= cadre.width
        // Le rapport est donné grand côté / petit côté : en portrait, le grand
        // côté est la hauteur. L'appliquer sans cette bascule donnerait un
        // « 16:9 » vertical de 9:16, c'est-à-dire l'inverse du format demandé.
        let cible = portrait ? 1 / rapport : rapport
        let actuel = cadre.width / cadre.height

        var largeur = cadre.width
        var hauteur = cadre.height
        if actuel > cible {
            largeur = cadre.height * cible
        } else {
            hauteur = cadre.width / cible
        }
        // Dimensions paires : l'encodeur vidéo les exige, et un recadrage impair
        // ferait échouer l'enregistrement pour ce seul format.
        largeur = CGFloat(max(2, Int(largeur.rounded(.down)) & ~1))
        hauteur = CGFloat(max(2, Int(hauteur.rounded(.down)) & ~1))

        return image.cropped(to: CGRect(x: cadre.midX - largeur / 2,
                                        y: cadre.midY - hauteur / 2,
                                        width: largeur,
                                        height: hauteur))
    }
}
