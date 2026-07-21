import CoreImage
import CoreVideo
import UIKit

/// Extrait des photos Portrait un masque d'arrière-plan
/// (blanc = fond à traiter, noir = sujet à préserver), à partir du matte
/// « effets portrait » ou, à défaut, de la carte de disparité/profondeur.
enum DepthExtractor {

    /// Masque d'arrière-plan orienté comme l'image affichée, ou nil si la
    /// photo n'embarque aucune donnée de profondeur.
    static func backgroundMask(from data: Data) -> CIImage? {
        // 1. Matte portrait : découpe du sujet la plus précise (sujet blanc).
        if let matte = CIImage(data: data, options: [.auxiliaryPortraitEffectsMatte: true,
                                                     .applyOrientationProperty: true]) {
            return softened(matte.applyingFilter("CIColorInvert"))
        }

        // 2. Carte de disparité : valeur faible = loin.
        if let disparity = CIImage(data: data, options: [.auxiliaryDisparity: true,
                                                         .applyOrientationProperty: true]),
           let mask = normalizedFarMask(disparity, farIsSmall: true) {
            return mask
        }

        // 3. Carte de profondeur : valeur grande = loin.
        if let depth = CIImage(data: data, options: [.auxiliaryDepth: true,
                                                     .applyOrientationProperty: true]),
           let mask = normalizedFarMask(depth, farIsSmall: false) {
            return mask
        }

        return nil
    }

    /// Plage de valeurs d'une carte de profondeur/disparité.
    struct DepthRange {
        let min: Float
        let max: Float
    }

    /// Étalonnage ABSOLU du flux direct : la disparité LiDAR / double
    /// capteur est en 1/mètres — le masque suit la vraie distance, pas la
    /// composition de la scène. Net en deçà de ~0,9 m (disparité ≥ 1.15),
    /// effet plein au-delà de ~3,3 m (disparité ≤ 0.30), rampe entre les
    /// deux. Constantes fixes = aucune mesure, aucun lissage, aucune
    /// oscillation possible de la normalisation.
    /// Précision (doc Apple `AVDepthData.depthDataAccuracy`) : le LiDAR
    /// livre `.absolute` (vrais 1/m) ; les doubles capteurs sans LiDAR
    /// livrent souvent `.relative` — l'ordre des distances reste garanti
    /// (masque monotone, stable, borné), seuls les seuils métriques
    /// peuvent glisser. Dans les deux cas : jamais d'artefact.
    static let liveAbsoluteRange = DepthRange(min: 0.30, max: 1.15)

    /// Normalise une carte de profondeur/disparité en masque 0…1 où
    /// l'arrière-plan (loin) tend vers le blanc.
    static func normalizedFarMask(_ map: CIImage, farIsSmall: Bool) -> CIImage? {
        guard let range = range(of: map) else { return nil }
        let mask = farMask(map, range: range, farIsSmall: farIsSmall)
        // Masque quasi vide (scène sans arrière-plan visible : sujet proche
        // qui remplit le cadre) : appliqué tel quel, il supprimerait les
        // effets gradués sur TOUTE l'image — « aucun objectif ne fait
        // rien ». Mieux vaut pas de masque : le rendu repasse au masque
        // radial et la signature de l'objectif reste visible.
        if let coverage = averageLuminance(of: mask), coverage < 0.06 {
            return nil
        }
        return mask
    }

    /// Luminance moyenne d'un masque (0…1) — sert à mesurer la fraction
    /// d'arrière-plan réellement couverte. Aller-retour GPU→CPU d'un seul
    /// pixel ; la caméra l'exécute sur sa file d'analyse.
    static func averageLuminance(of image: CIImage,
                                 context: CIContext = LensEngine.shared.context) -> Float? {
        guard !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent),
        ])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output,
                       toBitmap: &pixel,
                       rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)
        return pixel[0]
    }

    /// Mesure le min/max de la carte — seule étape avec un aller-retour
    /// GPU→CPU. La caméra la met en cache, ne la rafraîchit que
    /// périodiquement et l'exécute sur sa file d'analyse avec un contexte
    /// dédié pour ne pas bloquer le chemin des trames.
    static func range(of map: CIImage,
                      context: CIContext = LensEngine.shared.context,
                      minSpan: Float = 0.02) -> DepthRange? {
        guard !map.extent.isEmpty, !map.extent.isInfinite else { return nil }

        // Min/max est une statistique d'extrêmes : un seul pixel aberrant
        // (reflet spéculaire, bord de sujet) déplace la mesure d'une trame
        // à l'autre et fait pulser la normalisation du masque. Un très
        // léger flou écrase ces pixels isolés — plage stable sur une
        // scène statique, sans changer l'échelle générale.
        let measured = map.clampedToExtent()
            .applyingGaussianBlur(sigma: 2)
            .cropped(to: map.extent)

        let minMax = CIFilter(name: "CIAreaMinMax", parameters: [
            kCIInputImageKey: measured,
            kCIInputExtentKey: CIVector(cgRect: measured.extent),
        ])
        guard let minMaxImage = minMax?.outputImage else { return nil }

        // Le filtre renvoie une image 2×1 : pixel 0 = minimum, pixel 1 = maximum.
        var pixels = [Float](repeating: 0, count: 8)
        context.render(minMaxImage,
                       toBitmap: &pixels,
                       rowBytes: 32,
                       bounds: CGRect(x: 0, y: 0, width: 2, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)
        let minValue = pixels[0]
        let maxValue = pixels[4]
        // Plage trop étroite (scène plate, mur uni) : la normalisation ne
        // ferait qu'amplifier le bruit du capteur — masque instable qui
        // fait scintiller les effets. Mieux vaut pas de masque du tout.
        // `minSpan` est fourni par l'appelant : la caméra applique une
        // hystérésis (seuil d'acquisition haut, seuil de maintien bas)
        // pour qu'une scène à la limite ne fasse pas apparaître et
        // disparaître le masque en boucle.
        guard maxValue - minValue > minSpan else { return nil }
        return DepthRange(min: minValue, max: maxValue)
    }

    /// Construit le masque à partir d'une plage donnée —
    /// pure chaîne de filtres, sans lecture CPU.
    static func farMask(_ map: CIImage, range: DepthRange, farIsSmall: Bool) -> CIImage {
        let scale = CGFloat(1.0 / (range.max - range.min))
        let bias = CGFloat(-range.min) * scale
        var mask = map.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
        ])

        // Borne 0…1 INDISPENSABLE avec une plage absolue : les disparités
        // hors plage sont la norme (objet à 0,5 m → 2.0 ; ciel → 0). Sans
        // clamp, un proche donne un masque négatif et le gamma d'un
        // négatif produit du NaN — taches corrompues à l'image.
        mask = mask.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])

        if farIsSmall {
            mask = mask.applyingFilter("CIColorInvert")
        }

        // Accentue la séparation sujet/fond puis adoucit les transitions.
        mask = mask.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.6])
        return softened(mask)
    }

    private static func softened(_ mask: CIImage) -> CIImage {
        let sigma = max(2.0, mask.extent.width * 0.006)
        return mask.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: mask.extent)
    }
}
