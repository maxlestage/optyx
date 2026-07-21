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
        // Masque des effets gradués : plancher à 30 % — la profondeur
        // MODULE les effets (30 % sur le sujet proche, 100 % au loin),
        // elle ne les coupe plus. Sans plancher, une scène entièrement
        // proche (chambre, draps) éteignait tourbillon, bulles, douceur
        // et franges : « ça ne fait pas les effets ». Le glow et le
        // vignettage gardent leurs propres planchers sur le masque brut.
        let effectMask = depthMask.map { boosted($0, floor: 0.3) }
        // Bandes de distance calculées UNE fois par trame et partagées :
        // chaque effet gradué qui recalculait les siennes produisait des
        // sous-graphes identiques mais distincts, que Core Image ne peut
        // pas fusionner — travail triplé pour rien.
        let bands = effectMask.map { depthBands($0) }
        var img = input

        img = applyTone(img, lens: lens, k: k)
        img = applyWarmth(img, lens: lens, k: k)
        img = applySwirl(img, lens: lens, k: k, extent: extent, center: center, dim: dim,
                         customMask: effectMask, bands: bands)
        img = applyEdgeSoftness(img, lens: lens, k: k, extent: extent, center: center, dim: dim,
                                customMask: effectMask)
        img = applyBubbleBokeh(img, lens: lens, k: k, extent: extent, dim: dim,
                               customMask: effectMask, bands: bands)
        img = applyGlow(img, lens: lens, k: k, dim: dim, extent: extent,
                        customMask: depthMask)
        img = applyChromaticAberration(img, lens: lens, k: k, extent: extent, center: center,
                                       customMask: effectMask, bands: bands)
        img = applyVignette(img, lens: lens, k: k, center: center, dim: dim,
                            extent: extent, customMask: depthMask)
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

        // Lumière naturelle : le voile vintage reste une nuance, pas un
        // filtre gris — perte de contraste et noirs levés divisés par
        // deux ; l'exposition et les couleurs de la photo sont préservées,
        // le caractère vient des effets optiques.
        let controls = CIFilter.colorControls()
        controls.inputImage = out
        controls.contrast = Float(1.0 - 0.06 * lens.fade * k)
        controls.saturation = Float(1.0 + (lens.saturation - 1.0) * k)
        controls.brightness = 0
        out = controls.outputImage ?? out

        if lens.fade > 0.01 {
            let lift = CGFloat(0.02 * lens.fade * k)
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
        // Dérive contenue : la chaleur du thorium doit se sentir sans
        // orangir toute la photo — la lumière reste naturelle.
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = img
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 6500 + 900 * lens.warmth * k, y: 1.5 * lens.warmth * k)
        return filter.outputImage ?? img
    }

    /// Bokeh tourbillonnant : moyenne de copies légèrement pivotées autour
    /// du centre (flou tangentiel croissant avec le rayon), limitée aux bords
    /// par un masque radial pour préserver la netteté du sujet.
    /// Avec une carte de profondeur, l'amplitude du tourbillon croît avec
    /// la distance au plan de netteté.
    private func applySwirl(_ img: CIImage, lens: LensProfile, k: Double,
                            extent: CGRect, center: CGPoint, dim: CGFloat,
                            customMask: CIImage? = nil,
                            bands: [(factor: Double, weight: CIImage)]? = nil) -> CIImage {
        let strength = lens.swirl * k
        guard strength > 0.02 else { return img }

        let clamped = img.clampedToExtent()
        // Échantillonnage adaptatif : un tourbillon discret est visuellement
        // identique avec 2 rotations qu'avec 6 — inutile de payer le coût
        // plein pour un effet à peine perceptible (profils « ciné »).
        let offsets: [Double]
        if strength < 0.15 {
            offsets = [-1.0, 1.0]
        } else if strength < 0.4 {
            offsets = [-1.0, -0.33, 0.33, 1.0]
        } else if strength < 0.6 {
            offsets = [-1.0, -0.6, -0.2, 0.2, 0.6, 1.0]
        } else {
            // Grande amplitude : 8 copies pour que les répliques discrètes
            // fusionnent en arc continu au lieu de dédoubler les hautes
            // lumières.
            offsets = [-1.0, -0.71, -0.43, -0.14, 0.14, 0.43, 0.71, 1.0]
        }
        let weight = CGFloat(1.0 / Double(offsets.count))

        /// Copie tourbillonnée pour une amplitude donnée (1 = nominale).
        func swirledLayer(amplitude: Double) -> CIImage? {
            // 0.09 rad : la rotation moyenne est géométriquement nulle au
            // centre du cadre (sujet, horizon) — une amplitude timide rend
            // le tourbillon invisible partout sauf dans les coins, que le
            // vignettage recouvre. Le flou tangentiel accru fusionne les
            // copies discrètes aux bords.
            let maxAngle = 0.16 * strength * amplitude
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
            let sigma = (1.2 + 3.2 * strength) * (0.4 + 0.6 * amplitude)
            return swirled.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
        }

        if let customMask {
            // Tourbillon discret : la graduation par bande serait invisible,
            // une seule couche masquée par la profondeur suffit (÷3 le coût).
            if strength < 0.2 {
                guard let layer = swirledLayer(amplitude: 1.0) else { return img }
                let blend = CIFilter.blendWithMask()
                blend.inputImage = layer
                blend.backgroundImage = img
                blend.maskImage = customMask
                return blend.outputImage ?? img
            }

            // Tourbillon gradué : chaque bande de distance reçoit une
            // amplitude croissante, le sujet reste intact.
            var out = img
            for band in bands ?? depthBands(customMask) {
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
        // Zone nette resserrée : le tourbillon entre dans le champ dès le
        // premier tiers du cadre au lieu d'attendre les bords.
        let mask = radialMask(extent: extent, center: center,
                              inner: dim * 0.15, outer: dim * 0.50)
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
        // Flou gaussien + mélange masqué plutôt que CIMaskedVariableBlur :
        // ce dernier est le filtre le plus lent de Core Image (échantillonnage
        // à rayon variable par pixel), alors qu'avec un masque déjà adouci le
        // fondu net → flou est visuellement identique — pour une fraction
        // du coût, sur tous les profils.
        // Douceur renforcée : le fondu net → flou doit se voir, pas se
        // deviner.
        let sigma = dim * 0.016 * strength
        let blurred = img.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)
        let mask = customMask ?? radialMask(extent: extent, center: center,
                                            inner: dim * 0.28, outer: dim * 0.72)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = blurred
        blend.backgroundImage = img
        blend.maskImage = mask
        return blend.outputImage ?? img
    }

    /// Bokeh « bulles de savon » : les hautes lumières sont dilatées en
    /// disques dont on ne garde que le contour, incrusté en mode écran.
    /// Avec une carte de profondeur, le diamètre des bulles croît avec la
    /// distance au plan de netteté, comme sur un vrai objectif.
    private func applyBubbleBokeh(_ img: CIImage, lens: LensProfile, k: Double,
                                  extent: CGRect, dim: CGFloat,
                                  customMask: CIImage? = nil,
                                  bands: [(factor: Double, weight: CIImage)]? = nil) -> CIImage {
        let strength = lens.bubble * k
        // Sous 10 %, les anneaux (incrustés à 0,75 × strength) sont
        // invisibles à l'écran alors que la morphologie coûte cher :
        // autant ne rien faire.
        guard strength > 0.1 else { return img }

        let mono = CIFilter.colorControls()
        // Avec un masque de profondeur, seules les hautes lumières de
        // l'ARRIÈRE-PLAN engendrent des bulles : celles du sujet (chemise
        // blanche, reflets du visage) produisaient des anneaux collés à
        // la silhouette au lieu de venir du fond.
        mono.inputImage = customMask.map { multiplied(img, $0) } ?? img
        mono.saturation = 0
        mono.contrast = 1
        guard let gray = mono.outputImage else { return img }

        // Seuil abaissé et diamètre élargi : davantage de sources de
        // bulles, anneaux plus grands — la signature Trioplan se voit.
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = gray
        threshold.threshold = 0.66
        guard let highlights = threshold.outputImage else { return img }

        let baseRadius = Float(max(7, dim * 0.028))

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
            return scaled(rings, by: CGFloat(min(1.0, 1.45 * strength)),
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

        // Bulles discrètes : la variation de diamètre par bande ne se voit
        // pas, une seule couche pondérée par la profondeur suffit
        // (1 chaîne de morphologie au lieu de 3).
        if strength < 0.35 {
            guard var rings = ringLayer(discRadius: baseRadius) else { return img }
            rings = multiplied(rings, customMask).cropped(to: extent)
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = rings
            screen.backgroundImage = img
            return screen.outputImage ?? img
        }

        // Couches de bulles réparties sur les bandes de distance partagées :
        // proches du plan de netteté → petites, lointaines → larges.
        var out = img
        for band in bands ?? depthBands(customMask) {
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
    /// Avec une carte de profondeur, le halo est atténué sur le sujet
    /// et plein sur l'arrière-plan.
    private func applyGlow(_ img: CIImage, lens: LensProfile, k: Double,
                           dim: CGFloat, extent: CGRect,
                           customMask: CIImage? = nil) -> CIImage {
        let strength = lens.glow * k
        guard strength > 0.02 else { return img }
        // Avec un masque de profondeur, le bloom est alimenté par l'image
        // dont le sujet est éteint (multiplication par le masque) : sinon,
        // les hautes lumières du sujet (chemise blanche, visage) débordent
        // en halo blanc collé à la silhouette — le défaut le plus visible
        // sur les photos Portrait, identique quel que soit l'objectif.
        let source = customMask.map { multiplied(img, $0) } ?? img
        let bloom = CIFilter.bloom()
        bloom.inputImage = source.clampedToExtent()
        // Le glow éclaire, il n'assombrit pas : renforcer sa présence va
        // dans le sens d'une image lumineuse (le halo de silhouette est
        // déjà neutralisé par la source masquée).
        bloom.intensity = Float(1.35 * strength)
        bloom.radius = Float(dim * 0.02 * (0.5 + strength))
        guard let bloomed = bloom.outputImage?.cropped(to: extent) else { return img }

        guard let customMask else { return bloomed }
        // Le bloom du fond est réincrusté en mode écran : l'image garde sa
        // luminosité d'origine partout (le sujet n'est pas assombri par la
        // source éteinte), seul le halo du fond s'ajoute.
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = multiplied(subtracted(bloomed, minus: source),
                                       boosted(customMask, floor: 0.35))
            .cropped(to: extent)
        screen.backgroundImage = img
        return screen.outputImage ?? img
    }

    /// Aberration chromatique latérale : les canaux rouge et bleu sont
    /// très légèrement dilatés/contractés autour du centre.
    /// Avec une carte de profondeur, le décalage des franges croît
    /// réellement avec la distance au plan de netteté.
    private func applyChromaticAberration(_ img: CIImage, lens: LensProfile, k: Double,
                                          extent: CGRect, center: CGPoint,
                                          customMask: CIImage? = nil,
                                          bands: [(factor: Double, weight: CIImage)]? = nil) -> CIImage {
        let strength = lens.chroma * k
        guard strength > 0.02 else { return img }
        // Franges renforcées : 0.0035 était sous le seuil de visibilité
        // sur un écran de téléphone.
        let baseDelta = 0.010 * strength

        /// Image dont les franges sont décalées d'un delta donné.
        func aberrated(delta: Double) -> CIImage? {
            let clamped = img.clampedToExtent()
            // Alpha = 1 sur les TROIS canaux : les tampons intermédiaires
            // de Core Image sont prémultipliés (RVB ≤ alpha) — un canal à
            // alpha 0 verrait ses couleurs écrasées à zéro sur l'appareil,
            // et seul le vert survivrait (image entièrement verte).
            // L'alpha sommé (3) est ramené à 1 par le colorClamp final.
            let red = channel(clamped, r: 1, g: 0, b: 0, keepAlpha: true)
                .transformed(by: scaleAround(center, factor: 1 + delta))
                .cropped(to: extent)
            let green = channel(clamped, r: 0, g: 1, b: 0, keepAlpha: true)
                .cropped(to: extent)
            let blue = channel(clamped, r: 0, g: 0, b: 1, keepAlpha: true)
                .transformed(by: scaleAround(center, factor: 1 - delta))
                .cropped(to: extent)

            let addRG = CIFilter.additionCompositing()
            addRG.inputImage = red
            addRG.backgroundImage = green
            guard let rg = addRG.outputImage else { return nil }

            let addRGB = CIFilter.additionCompositing()
            addRGB.inputImage = blue
            addRGB.backgroundImage = rg
            guard let rgb = addRGB.outputImage else { return nil }

            let clamp = CIFilter.colorClamp()
            clamp.inputImage = rgb
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            return clamp.outputImage
        }

        if let customMask {
            // Franges discrètes : la graduation par distance est
            // imperceptible, une seule couche masquée suffit
            // (1 découpe de canaux au lieu de 3).
            if strength < 0.3 {
                guard let layer = aberrated(delta: baseDelta) else { return img }
                let blend = CIFilter.blendWithMask()
                blend.inputImage = layer
                blend.backgroundImage = img
                blend.maskImage = customMask
                return blend.outputImage ?? img
            }

            // Le mélange pondéré de deux images décalées créerait un
            // dédoublement ; chaque bande reçoit donc sa propre couche
            // au décalage réellement mis à l'échelle.
            var out = img
            for band in bands ?? depthBands(customMask) {
                guard let layer = aberrated(delta: baseDelta * band.factor) else { continue }
                let blend = CIFilter.blendWithMask()
                blend.inputImage = layer
                blend.backgroundImage = out
                blend.maskImage = band.weight
                out = blend.outputImage ?? out
            }
            return out
        }

        return aberrated(delta: baseDelta) ?? img
    }

    /// Assombrissement des coins ; avec une carte de profondeur, le sujet
    /// n'est que partiellement assombri, l'arrière-plan l'est pleinement.
    private func applyVignette(_ img: CIImage, lens: LensProfile, k: Double,
                               center: CGPoint, dim: CGFloat,
                               extent: CGRect, customMask: CIImage? = nil) -> CIImage {
        let strength = lens.vignette * k
        guard strength > 0.02 else { return img }
        // Réglage adouci : l'ancien barème (intensité 1.1 × force, rayon
        // 0.75) noircissait presque les coins sur les profils à fort
        // vignettage (Noctilux, Dream Lens) et assombrissait toute la
        // photo. Le rayon élargi repousse l'assombrissement vers les
        // bords, l'intensité réduite le rend translucide — les écarts
        // entre objectifs sont conservés.
        let filter = CIFilter.vignetteEffect()
        filter.inputImage = img
        filter.center = center
        // « Sortir le noir » : le vignettage n'est plus qu'un souffle dans
        // les angles — l'exposition de la photo reste normale partout.
        filter.radius = Float(dim * 0.96)
        filter.intensity = Float(0.32 * strength)
        filter.falloff = 0.3
        guard let vignetted = filter.outputImage else { return img }

        guard let customMask else { return vignetted }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = vignetted.cropped(to: extent)
        blend.backgroundImage = img
        blend.maskImage = boosted(customMask, floor: 0.5)
        return blend.outputImage ?? vignetted
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

    /// Remonte le plancher d'un masque : `floor` sur le sujet, 1 au loin.
    /// Un effet mélangé avec ce masque reste partiellement présent partout.
    private func boosted(_ mask: CIImage, floor: CGFloat) -> CIImage {
        let scale = 1 - floor
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = mask
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: floor, y: floor, z: floor, w: 1)
        return matrix.outputImage ?? mask
    }

    private func multiplied(_ a: CIImage, _ b: CIImage) -> CIImage {
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = a
        multiply.backgroundImage = b
        return multiply.outputImage ?? a
    }

    /// Différence bornée `a − b` (canaux RVB, alpha ramené à 1).
    /// Sert à isoler le halo pur d'un bloom : bloom(source) − source.
    /// L'espace de travail de Core Image (flottant) tolère les valeurs
    /// négatives intermédiaires ; le clamp final les élimine.
    private func subtracted(_ a: CIImage, minus b: CIImage) -> CIImage {
        let negative = CIFilter.colorMatrix()
        negative.inputImage = b
        negative.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
        negative.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        negative.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
        negative.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        negative.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let neg = negative.outputImage else { return a }

        let add = CIFilter.additionCompositing()
        add.inputImage = a
        add.backgroundImage = neg
        guard let sum = add.outputImage else { return a }

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = sum
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? sum
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

    /// Extrait un canal couleur. `keepAlpha` doit rester vrai pour toute
    /// image destinée à un tampon intermédiaire : le rendu prémultiplié
    /// impose RVB ≤ alpha et écraserait les couleurs d'un canal à alpha 0.
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
