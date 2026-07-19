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

    /// Normalise une carte de profondeur/disparité en masque 0…1 où
    /// l'arrière-plan (loin) tend vers le blanc.
    static func normalizedFarMask(_ map: CIImage, farIsSmall: Bool) -> CIImage? {
        guard let range = range(of: map) else { return nil }
        return farMask(map, range: range, farIsSmall: farIsSmall)
    }

    /// Mesure le min/max de la carte — seule étape avec un aller-retour
    /// GPU→CPU. La caméra la met en cache, ne la rafraîchit que
    /// périodiquement et l'exécute sur sa file d'analyse avec un contexte
    /// dédié pour ne pas bloquer le chemin des trames.
    static func range(of map: CIImage,
                      context: CIContext = LensEngine.shared.context) -> DepthRange? {
        guard !map.extent.isEmpty, !map.extent.isInfinite else { return nil }

        let minMax = CIFilter(name: "CIAreaMinMax", parameters: [
            kCIInputImageKey: map,
            kCIInputExtentKey: CIVector(cgRect: map.extent),
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
        guard maxValue - minValue > 0.0001 else { return nil }
        return DepthRange(min: minValue, max: maxValue)
    }

    /// Construit le masque à partir d'une plage déjà mesurée —
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
