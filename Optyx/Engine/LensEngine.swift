import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Moteur de rendu : applique le profil optique d'un objectif vintage
/// à une image via une chaîne de filtres Core Image.
///
/// Chaîne : tonalité → température → tourbillon → douceur des bords
/// → bulles de savon → halo → aberration chromatique → vignettage → grain.
final class LensEngine {

    static let shared = LensEngine()

    let context: CIContext

    private init() {
        context = CIContext(options: [.cacheIntermediates: false])
    }

    // MARK: - Rendu principal

    /// - Parameters:
    ///   - input: image source.
    ///   - lens: profil de l'objectif simulé.
    ///   - intensity: intensité globale de la simulation (0…1).
    ///   - backgroundMask: masque d'arrière-plan (blanc = fond) issu d'une
    ///     carte de profondeur Portrait ; remplace le masque radial pour le
    ///     tourbillon, la douceur et les bulles quand il est fourni.
    func render(_ input: CIImage, lens: LensProfile, intensity: Double,
                backgroundMask: CIImage? = nil) -> CIImage {
        let extent = input.extent
        guard !extent.isEmpty, intensity > 0 else { return input }

        let k = intensity
        let dim = min(extent.width, extent.height)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let depthMask = backgroundMask.map { fitMask($0, to: extent) }
        var img = input

        img = applyTone(img, lens: lens, k: k)
        img = applyWarmth(img, lens: lens, k: k)
        img = applySwirl(img, lens: lens, k: k, extent: extent, center: center, dim: dim,
                         customMask: depthMask)
        img = applyEdgeSoftness(img, lens: lens, k: k, extent: extent, center: center, dim: dim,
                                customMask: depthMask)
        img = applyBubbleBokeh(img, lens: lens, k: k, extent: extent, dim: dim,
                               customMask: depthMask)
        img = applyGlow(img, lens: lens, k: k, dim: dim, extent: extent)
        img = applyChromaticAberration(img, lens: lens, k: k, extent: extent, center: center)
        img = applyVignette(img, lens: lens, k: k, center: center, dim: dim)
        img = applyGrain(img, lens: lens, k: k, extent: extent)

        return img.cropped(to: extent)
    }

    /// Rend l'image en UIImage (pour affichage ou sauvegarde).
    func renderUIImage(_ input: CIImage, lens: LensProfile, intensity: Double,
                       backgroundMask: CIImage? = nil) -> UIImage? {
        let output = render(input, lens: lens, intensity: intensity,
                            backgroundMask: backgroundMask)
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Étapes de la chaîne

    /// Contraste, saturation et noirs voilés.
    private func applyTone(_ img: CIImage, lens: LensProfile, k: Double) -> CIImage {
        var out = img

        let controls = CIFilter.colorControls()
        controls.inputImage = out
        controls.contrast = Float(1.0 - 0.22 * lens.fade * k)
        controls.saturation = Float(1.0 + (lens.saturation - 1.0) * k)
        controls.brightness = 0
        out = controls.outputImage ?? out

        if lens.fade > 0.01 {
            let lift = CGFloat(0.07 * lens.fade * k)
            let poly = CIFilter.colorPolynomial()
            poly.inputImage = out
            let coeff = CIVector(x: lift, y: 1 - lift, z: 0, w: 0)
            poly.redCoefficients = coeff
            poly.greenCoefficients = coeff
            poly.blueCoefficients = coeff
            poly.alphaCoefficients = CIVector(x: 0, y: 1, z: 0, w: 0)
            out = poly.outputImage ?? out
        }
        return out
    }

    /// Dérive chaude (verre au thorium, traitements anciens).
    private func applyWarmth(_ img: CIImage, lens: LensProfile, k: Double) -> CIImage {
        guard lens.warmth > 0.01 else { return img }
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = img
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 6500 + 2200 * lens.warmth * k, y: 4 * lens.warmth * k)
        return filter.outputImage ?? img
    }

    /// Bokeh tourbillonnant : moyenne de copies légèrement pivotées autour
    /// du centre (flou tangentiel croissant avec le rayon), limitée aux bords
    /// par un masque radial pour préserver la netteté du sujet.
    /// Avec une carte de profondeur, l'amplitude du tourbillon croît avec
    /// la distance au plan de netteté.
    private func applySwirl(_ img: CIImage, lens: LensProfile, k: Double,
                            extent: CGRect, center: CGPoint, dim: CGFloat,
                            customMask: CIImage? = nil) -> CIImage {
        let strength = lens.swirl * k
        guard strength > 0.02 else { return img }

        let clamped = img.clampedToExtent()
        let offsets: [Double] = [-1.0, -0.6, -0.2, 0.2, 0.6, 1.0]
        let weight = CGFloat(1.0 / Double(offsets.count))

        /// Copie tourbillonnée pour une amplitude donnée (1 = nominale).
        func swirledLayer(amplitude: Double) -> CIImage? {
            let maxAngle = 0.045 * strength * amplitude
            var accumulated: CIImage?
            for offset in offsets {
                let angle = CGFloat(offset * maxAngle)
                let transform = CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: angle)
                    .translatedBy(x: -center.x, y: -center.y)
                let rotated = clamped.transformed(by: transform).cropped(to: extent)
                let weighted = scaled(rotated, by: weight)
                if let acc = accumulated {
                    let add = CIFilter.additionCompositing()
                    add.inputImage = weighted
                    add.backgroundImage = acc
                    accumulated = add.outputImage
                } else {
                    accumulated = weighted
                }
            }
            guard let swirled = accumulated else { return nil }
            let sigma = (1.2 + 2.5 * strength) * (0.4 + 0.6 * amplitude)
            return swirled.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
        }

        if let customMask {
            // Tourbillon gradué : chaque bande de distance reçoit une
            // amplitude croissante, le sujet reste intact.
            var out = img
            for band in depthBands(customMask) {
                guard let layer = swirledLayer(amplitude: band.factor) else { continue }
                let blend = CIFilter.blendWithMask()
                blend.inputImage = layer
                blend.backgroundImage = out
                blend.maskImage = band.weight
                out = blend.outputImage ?? out
            }
            return out
        }

        guard let swirled = swirledLayer(amplitude: 1.0) else { return img }
        let mask = radialMask(extent: extent, center: center,
                              inner: dim * 0.20, outer: dim * 0.60)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = swirled
        blend.backgroundImage = img
        blend.maskImage = mask
        return blend.outputImage ?? img
    }

    /// Perte de piqué progressive vers les bords du champ.
    private func applyEdgeSoftness(_ img: CIImage, lens: LensProfile, k: Double,
                                   extent: CGRect, center: CGPoint, dim: CGFloat,
                                   customMask: CIImage? = nil) -> CIImage {
        let strength = lens.softness * k
        guard strength > 0.02 else { return img }
        let filter = CIFilter.maskedVariableBlur()
        filter.inputImage = img.clampedToExtent()
        filter.mask = customMask ?? radialMask(extent: extent, center: center,
                                               inner: dim * 0.28, outer: dim * 0.72)
        filter.radius = Float(dim * 0.012 * strength)
        return filter.outputImage?.cropped(to: extent) ?? img
    }

    /// Bokeh « bulles de savon » : les hautes lumières sont dilatées en
    /// disques dont on ne garde que le contour, incrusté en mode écran.
    /// Avec une carte de profondeur, le diamètre des bulles croît avec la
    /// distance au plan de netteté, comme sur un vrai objectif.
    private func applyBubbleBokeh(_ img: CIImage, lens: LensProfile, k: Double,
                                  extent: CGRect, dim: CGFloat,
                                  customMask: CIImage? = nil) -> CIImage {
        let strength = lens.bubble * k
        guard strength > 0.02 else { return img }

        let mono = CIFilter.colorControls()
        mono.inputImage = img
        mono.saturation = 0
        mono.contrast = 1
        guard let gray = mono.outputImage else { return img }

        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = gray
        threshold.threshold = 0.80
        guard let highlights = threshold.outputImage else { return img }

        let baseRadius = Float(max(4, dim * 0.014))

        /// Anneaux construits à partir des hautes lumières pour un diamètre donné.
        func ringLayer(discRadius: Float) -> CIImage? {
            let dilate = CIFilter.morphologyMaximum()
            dilate.inputImage = highlights.clampedToExtent()
            dilate.radius = discRadius
            guard let discs = dilate.outputImage else { return nil }

            let ring = CIFilter.morphologyGradient()
            ring.inputImage = discs
            ring.radius = max(1.5, discRadius * 0.18)
            guard var rings = ring.outputImage else { return nil }

            rings = rings.applyingGaussianBlur(sigma: 1.0).cropped(to: extent)
            return scaled(rings, by: CGFloat(0.75 * strength),
                          tint: (r: 1.0, g: 0.96, b: 0.88))
        }

        guard let customMask else {
            // Sans profondeur : une seule taille de bulles, partout.
            guard let rings = ringLayer(discRadius: baseRadius) else { return img }
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = rings
            screen.backgroundImage = img
            return screen.outputImage ?? img
        }

        // Trois couches de bulles réparties sur les bandes de distance
        // partagées : proches du plan de netteté → petites, lointaines → larges.
        var out = img
        for band in depthBands(customMask) {
            guard var rings = ringLayer(discRadius: max(3, baseRadius * Float(band.factor)))
            else { continue }
            rings = multiplied(rings, band.weight).cropped(to: extent)
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = rings
            screen.backgroundImage = out
            out = screen.outputImage ?? out
        }
        return out
    }

    /// Halo lumineux / voile onirique autour des hautes lumières.
    private func applyGlow(_ img: CIImage, lens: LensProfile, k: Double,
                           dim: CGFloat, extent: CGRect) -> CIImage {
        let strength = lens.glow * k
        guard strength > 0.02 else { return img }
        let bloom = CIFilter.bloom()
        bloom.inputImage = img.clampedToExtent()
        bloom.intensity = Float(0.9 * strength)
        bloom.radius = Float(dim * 0.02 * (0.5 + strength))
        return bloom.outputImage?.cropped(to: extent) ?? img
    }

    /// Aberration chromatique latérale : les canaux rouge et bleu sont
    /// très légèrement dilatés/contractés autour du centre.
    private func applyChromaticAberration(_ img: CIImage, lens: LensProfile, k: Double,
                                          extent: CGRect, center: CGPoint) -> CIImage {
        let strength = lens.chroma * k
        guard strength > 0.02 else { return img }
        let delta = 0.0035 * strength

        let clamped = img.clampedToExtent()
        let red = channel(clamped, r: 1, g: 0, b: 0, keepAlpha: false)
            .transformed(by: scaleAround(center, factor: 1 + delta))
            .cropped(to: extent)
        let green = channel(clamped, r: 0, g: 1, b: 0, keepAlpha: true)
            .cropped(to: extent)
        let blue = channel(clamped, r: 0, g: 0, b: 1, keepAlpha: false)
            .transformed(by: scaleAround(center, factor: 1 - delta))
            .cropped(to: extent)

        let addRG = CIFilter.additionCompositing()
        addRG.inputImage = red
        addRG.backgroundImage = green
        guard let rg = addRG.outputImage else { return img }

        let addRGB = CIFilter.additionCompositing()
        addRGB.inputImage = blue
        addRGB.backgroundImage = rg
        guard let rgb = addRGB.outputImage else { return img }

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = rgb
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? img
    }

    private func applyVignette(_ img: CIImage, lens: LensProfile, k: Double,
                               center: CGPoint, dim: CGFloat) -> CIImage {
        let strength = lens.vignette * k
        guard strength > 0.02 else { return img }
        let filter = CIFilter.vignetteEffect()
        filter.inputImage = img
        filter.center = center
        filter.radius = Float(dim * 0.75)
        filter.intensity = Float(1.1 * strength)
        filter.falloff = 0.5
        return filter.outputImage ?? img
    }

    /// Grain argentique en incrustation lumière douce.
    private func applyGrain(_ img: CIImage, lens: LensProfile, k: Double,
                            extent: CGRect) -> CIImage {
        let strength = lens.grain * k
        guard strength > 0.02 else { return img }

        guard let noise = CIFilter.randomGenerator().outputImage else { return img }
        let mono = CIFilter.colorControls()
        mono.inputImage = noise
        mono.saturation = 0
        guard let gray = mono.outputImage else { return img }

        // Recentre le bruit autour du gris moyen avec une amplitude réduite :
        // out = 0.5 + (bruit − 0.5) × amplitude
        let amp = CGFloat(0.35 * strength)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = gray
        matrix.rVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: amp, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: amp, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let bias = 0.5 - amp / 2
        matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        guard let grain = matrix.outputImage?.cropped(to: extent) else { return img }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = img
        return blend.outputImage ?? img
    }

    // MARK: - Utilitaires

    /// Bandes de distance mutuellement exclusives découpées dans le masque
    /// de profondeur : (facteur d'intensité, poids). Proche du plan de
    /// netteté → effet léger, lointain → effet fort. Les rampes se
    /// recouvrent pour des fondus doux entre bandes.
    private func depthBands(_ mask: CIImage) -> [(factor: Double, weight: CIImage)] {
        let rampNear = ramp(mask, from: 0.25, to: 0.45)
        let rampMid = ramp(mask, from: 0.55, to: 0.70)
        let rampFar = ramp(mask, from: 0.80, to: 0.92)
        return [
            (0.6, multiplied(rampNear, inverted(rampMid))),
            (1.0, multiplied(rampMid, inverted(rampFar))),
            (1.5, rampFar),
        ]
    }

    /// Rampe linéaire bornée : 0 sous `lo`, 1 au-dessus de `hi`.
    /// Sert à découper le masque de profondeur en bandes de distance.
    private func ramp(_ mask: CIImage, from lo: CGFloat, to hi: CGFloat) -> CIImage {
        let scale = 1 / max(hi - lo, 0.001)
        let bias = -lo * scale
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = mask
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
        guard let out = matrix.outputImage else { return mask }

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = out
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? out
    }

    private func inverted(_ img: CIImage) -> CIImage {
        img.applyingFilter("CIColorInvert")
    }

    private func multiplied(_ a: CIImage, _ b: CIImage) -> CIImage {
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = a
        multiply.backgroundImage = b
        return multiply.outputImage ?? a
    }

    /// Redimensionne un masque (ex. carte de profondeur, résolution réduite)
    /// pour qu'il couvre exactement l'étendue de l'image traitée.
    private func fitMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let source = mask.extent
        guard !source.isEmpty, !source.isInfinite else { return mask.cropped(to: extent) }
        let sx = extent.width / source.width
        let sy = extent.height / source.height
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                          tx: extent.minX - source.minX * sx,
                                          ty: extent.minY - source.minY * sy)
        return mask.transformed(by: transform).cropped(to: extent)
    }

    /// Masque radial : noir au centre (image nette), blanc vers les bords.
    private func radialMask(extent: CGRect, center: CGPoint,
                            inner: CGFloat, outer: CGFloat) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(inner)
        gradient.radius1 = Float(outer)
        gradient.color0 = CIColor.black
        gradient.color1 = CIColor.white
        return (gradient.outputImage ?? CIImage.empty()).cropped(to: extent)
    }

    /// Extrait un canal couleur ; `keepAlpha` conserve l'alpha sur ce canal
    /// pour que la somme des trois canaux garde un alpha de 1.
    private func channel(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat,
                         keepAlpha: Bool) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = img
        matrix.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: keepAlpha ? 1 : 0)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? img
    }

    /// Multiplie RVB (et alpha) par un facteur, avec teinte optionnelle.
    private func scaled(_ img: CIImage, by factor: CGFloat,
                        tint: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 1, 1)) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = img
        matrix.rVector = CIVector(x: factor * tint.r, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: factor * tint.g, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: factor * tint.b, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: factor)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? img
    }

    private func scaleAround(_ center: CGPoint, factor: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: factor, y: factor)
            .translatedBy(x: -center.x, y: -center.y)
    }
}

// MARK: - Préparation des images

extension UIImage {
    /// Redessine l'image avec l'orientation appliquée, en la limitant
    /// à `maxDimension` pixels sur son plus grand côté.
    func normalized(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        let ratio = min(1, maxDimension / max(largest, 1))
        let target = CGSize(width: (size.width * ratio).rounded(),
                            height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
