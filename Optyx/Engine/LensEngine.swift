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
        // Masque des effets gradués : profondeur ∪ champ. Les aberrations
        // d'un vrai objectif (tourbillon, douceur, franges, bulles) sont
        // des effets de CHAMP : elles frappent les bords du cadre quelle
        // que soit la distance du sujet. Le masque de profondeur seul les
        // éteignait dès que la scène entière était proche (lit, selfie :
        // tout sous ~1 m → masque noir partout, « aucun objectif ne fait
        // rien »), car le garde-fou amont ne coupe le masque que sous 6 %
        // de couverture. L'union avec le masque radial garantit la
        // signature aux bords dans TOUTES les scènes ; la profondeur
        // continue de graduer l'arrière-plan et le centre du cadre — le
        // sujet — reste net (masque à 0 des deux côtés).
        let effectMask = depthMask.map { mask in
            maxed(mask, radialMask(extent: extent, center: center,
                                   inner: dim * 0.18, outer: dim * 0.55))
        }
        // Bandes de distance calculées UNE fois par trame et partagées :
        // chaque effet gradué qui recalculait les siennes produisait des
        // sous-graphes identiques mais distincts, que Core Image ne peut
        // pas fusionner — travail triplé pour rien.
        let bands = effectMask.map { depthBands($0) }

        // Masque DÉDIÉ à la défocalisation, distinct de celui des
        // aberrations. Deux raisons : le fond doit fondre selon la
        // DISTANCE, pas selon la position dans le cadre ; et l'union
        // radiale des aberrations atteint 1 sur près d'un tiers de la
        // surface, ce qui noierait l'épaule d'un sujet qui touche le bord.
        //
        // Sans profondeur — le cas des photos importées au Studio — on ne
        // sait pas où est le sujet : on retombe sur un masque radial à
        // PLEINE amplitude, sinon le fond serait moins flou qu'avant et
        // le remède empirerait le mal.
        let defocusMask: CIImage = {
            let wideFloor = radialMask(extent: extent, center: center,
                                       inner: dim * 0.24, outer: dim * 0.72)
            guard let depthMask else { return wideFloor }
            // Avec profondeur : plancher plus tardif et de demi-amplitude,
            // la distance mesurée gouverne le reste.
            let gentleFloor = dimmed(radialMask(extent: extent, center: center,
                                                inner: dim * 0.40, outer: dim * 0.95),
                                     to: 0.5)
            return maxed(ramp(depthMask, from: 0.55, to: 0.95), gentleFloor)
        }()

        var img = input

        img = applyTone(img, lens: lens, k: k)
        img = applyWarmth(img, lens: lens, k: k)
        img = applyCineTone(img, lens: lens, k: k)
        img = applySwirl(img, lens: lens, k: k, extent: extent, center: center, dim: dim,
                         customMask: effectMask, bands: bands)
        // Les points de lumière sont repérés sur l'image NETTE : après la
        // défocalisation il n'en resterait aucun, et les disques de bokeh
        // — la signature de chaque verre — disparaîtraient purement et
        // simplement à mesure que le flou s'intensifie.
        let sharpForPoints = img
        img = applyDefocus(img, lens: lens, k: k, extent: extent, center: center, dim: dim,
                           mask: defocusMask, graded: depthMask != nil)
        img = applyEdgeSoftness(img, lens: lens, k: k, extent: extent, center: center, dim: dim)
        img = applyHighlightBokeh(img, lens: lens, k: k, extent: extent, dim: dim,
                                  customMask: effectMask, bands: bands,
                                  pointSource: sharpForPoints)
        // Le glow reçoit lui aussi l'union : gater le halo par la seule
        // profondeur l'éteignait entièrement dans les scènes proches.
        img = applyGlow(img, lens: lens, k: k, dim: dim, extent: extent,
                        customMask: effectMask)
        img = applyChromaticAberration(img, lens: lens, k: k, extent: extent, center: center,
                                       customMask: effectMask, bands: bands)
        // Le micro-contraste vient APRÈS les flous : appliqué avant, la
        // défocalisation effaçait exactement ce qu'il venait d'accentuer.
        // Et avant le grain, sinon la netteté amplifierait le bruit.
        img = applyPunch(img, lens: lens, k: k)
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

        // Image PLUS CLAIRE : gain d'exposition qui COMPENSE ce que le
        // profil mange en lumière (voile + vignettage + douceur), jusqu'à
        // +0,4 EV à pleine intensité. Proportionnel au caractère du
        // profil : le profil Neutre (tout à zéro) reste rigoureusement
        // identique à ce que voit le capteur — c'est sa promesse — et les
        // profils discrets (Summicron) ne sont pas surexposés.
        let dimming = min(1.0, lens.fade + lens.vignette + lens.softness)
        if dimming > 0.01 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = out
            exposure.ev = Float(0.40 * dimming * k)
            out = exposure.outputImage ?? out
        }

        // Lumière naturelle : le voile vintage reste une nuance, pas un
        // filtre gris — perte de contraste et noirs levés réduits au
        // minimum ; l'exposition et les couleurs de la photo sont
        // préservées, le caractère vient des effets optiques.
        let controls = CIFilter.colorControls()
        controls.inputImage = out
        // Le voile devient un vrai voile : à 0,04 la perte de contraste
        // était de 1 % au plus, invisible. À 0,10 elle atteint 3 % sur
        // l'Angénieux — perceptible, sans virer au gris. Le coefficient
        // reste modeste à dessein : CIColorControls travaille en espace
        // LINÉAIRE, où l'effet perçu sur les noirs est bien supérieur à
        // ce que la valeur laisse croire.
        controls.contrast = Float(1.0 - 0.10 * lens.fade * k)
        controls.saturation = Float(1.0 + (lens.saturation - 1.0) * k)
        controls.brightness = 0
        out = controls.outputImage ?? out

        if lens.fade > 0.01 {
            let lift = CGFloat(0.015 * lens.fade * k)
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

    /// Micro-contraste des verres précis (Summicron, Noct-Nikkor) :
    /// netteté de luminance et punch — l'opposé des rêveurs. C'est ce qui
    /// rend ces profils immédiatement reconnaissables face au flux brut.
    private func applyPunch(_ img: CIImage, lens: LensProfile, k: Double) -> CIImage {
        let strength = lens.punch * k
        guard strength > 0.02 else { return img }
        // Coefficients francs : le passage Neutre → Summicron doit se
        // voir immédiatement, pas s'apprécier à la loupe.
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = img
        sharpen.sharpness = Float(1.1 * strength)
        var out = sharpen.outputImage ?? img
        let controls = CIFilter.colorControls()
        controls.inputImage = out
        controls.contrast = Float(1.0 + 0.15 * strength)
        controls.saturation = 1
        controls.brightness = 0
        out = controls.outputImage ?? out
        return out
    }

    /// Virage bicolore cinéma (Angénieux) : les ombres glissent vers le
    /// bleu-vert pendant que la dérive chaude réchauffe les tons clairs —
    /// le contraste orange/teal des pellicules étalonnées en laboratoire.
    private func applyCineTone(_ img: CIImage, lens: LensProfile, k: Double) -> CIImage {
        let strength = lens.cine * k
        guard strength > 0.02 else { return img }
        let mono = CIFilter.colorControls()
        mono.inputImage = img
        mono.saturation = 0
        mono.contrast = 1
        guard let gray = mono.outputImage else { return img }
        // Masque d'ombres : plein dans les noirs, nul dès les tons moyens.
        let shadows = inverted(ramp(gray, from: 0.15, to: 0.55))
        let teal = CIImage(color: CIColor(red: 0, green: 0.35, blue: 0.38, alpha: 1))
            .cropped(to: img.extent)
        // Dose franche : le contraste orange/teal doit se reconnaître au
        // premier regard, c'est l'affiche du profil ciné.
        let weighted = multiplied(scaled(teal, by: CGFloat(0.60 * strength)), shadows)
            .cropped(to: img.extent)
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = weighted
        screen.backgroundImage = img
        return screen.outputImage ?? img
    }

    /// Dérive chaude (verre au thorium, traitements anciens).
    private func applyWarmth(_ img: CIImage, lens: LensProfile, k: Double) -> CIImage {
        // Axe COMPLET : une valeur négative refroidit. Un verre soviétique
        // tire vers le vert-bleu, un verre allemand vers l'ambre — les
        // opposer se lit instantanément sur un mur uni, là où aucun bokeh
        // n'existe. Un profil à zéro saute le filtre entièrement.
        guard abs(lens.warmth) > 0.01 else { return img }
        // Dérive dorée AFFIRMÉE : la chaleur du thorium est la signature du
        // Takumar — elle doit se voir au premier coup d'œil, sans virer au
        // filtre orange uniforme.
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = img
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 6500 + 2200 * lens.warmth * k, y: 3.5 * lens.warmth * k)
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
        // Le seuil porte sur le PROFIL, pas sur le produit profil × molette :
        // sinon la molette d'intensité devenait un interrupteur qui coupait
        // l'effet en cours de course. Les verres sans tourbillon (Takumar,
        // Noct-Nikkor, Angénieux) sont écartés une fois pour toutes ; les
        // autres suivent la molette de façon continue.
        guard lens.swirl >= 0.20, strength > 0.05 else { return img }

        let clamped = img.clampedToExtent()

        /// Copie tourbillonnée pour une amplitude donnée (1 = nominale).
        func swirledLayer(amplitude: Double) -> CIImage? {
            // TORSION GÉOMÉTRIQUE à profil CROISSANT : le centre reste
            // immobile, la couronne tourne — c'est le sens d'un vrai
            // tourbillon, et c'est ce qui fait COURBER les lignes droites
            // d'un mur, seule signature lisible sur un aplat sans la
            // moindre haute lumière.
            //
            // CITwirlDistortion fait l'inverse (rotation maximale AU
            // CENTRE, nulle au rayon) : on la compose donc avec une
            // rotation globale opposée. Les deux rotations partagent le
            // même centre, elles s'additionnent donc exactement — un point
            // à distance r tourne de T·f(r) − T, soit zéro au centre et −T
            // aux coins. Aucun noyau maison à compiler.
            let twist = CGFloat(0.16 * strength * min(amplitude, 1.4))
            let halfDiagonal = hypot(extent.width, extent.height) / 2
            let twirl = CIFilter.twirlDistortion()
            twirl.inputImage = clamped
            twirl.center = center
            twirl.radius = Float(halfDiagonal)
            twirl.angle = Float(twist)
            let twisted = twirl.outputImage?.clampedToExtent() ?? clamped
            let unrotate = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -twist)
                .translatedBy(x: -center.x, y: -center.y)
            let base = twisted.transformed(by: unrotate).clampedToExtent()

            // Filé de rotation par-dessus la torsion : c'est lui qui étire
            // les hautes lumières en arcs. Amplitude réduite depuis que la
            // torsion porte l'essentiel de l'effet géométrique — la somme
            // des deux reste franche, sans exiger seize copies.
            let maxAngle = 0.16 * strength * min(amplitude, 1.4)
            // Échantillonnage adaptatif sur l'angle EFFECTIF — amplitude
            // des bandes de profondeur comprise (jusqu'à ×1.5) : à grand
            // angle, trop peu de copies se dissocient en répliques
            // fantômes au lieu de fusionner en arc continu ; à angle
            // discret, 2 copies suffisent (profils « ciné »).
            let count: Int
            switch maxAngle {
            case ..<0.05: count = 2
            case ..<0.12: count = 4
            case ..<0.20: count = 6
            case ..<0.30: count = 8
            case ..<0.42: count = 12
            default: count = 16
            }
            let offsets = (0..<count).map { -1.0 + 2.0 * Double($0) / Double(count - 1) }
            // Moyenne COURANTE par interpolation (dissolve) et non par
            // addition de copies à opacité réduite : la réduction d'alpha
            // suivie d'une somme perd de la luminosité dans les tampons
            // prémultipliés — la zone tourbillonnée sortait sombre, et
            // d'autant plus que le nombre de copies était grand. Le grand
            // rond sombre autour du sujet, c'était elle. L'interpolation
            // garde l'alpha à 1 à chaque étape : moyenne exacte,
            // luminosité intacte, quel que soit le nombre de copies.
            var accumulated: CIImage?
            for (index, offset) in offsets.enumerated() {
                let angle = CGFloat(offset * maxAngle)
                let transform = CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: angle)
                    .translatedBy(x: -center.x, y: -center.y)
                let rotated = base.transformed(by: transform).cropped(to: extent)
                if let acc = accumulated {
                    let mix = CIFilter.dissolveTransition()
                    mix.inputImage = acc
                    mix.targetImage = rotated
                    mix.time = Float(1.0 / Double(index + 1))
                    accumulated = mix.outputImage ?? acc
                } else {
                    accumulated = rotated
                }
            }
            guard let swirled = accumulated else { return nil }
            // Flou tangentiel avec PLANCHER calé sur l'écart réel entre
            // copies (arc parcouru / nombre de copies, au rayon des
            // bords) : quel que soit l'angle, les répliques discrètes
            // fusionnent en arc continu — fini les ondulations
            // concentriques sur les textures (sable, murs) et les
            // contours dédoublés aux amplitudes moyennes.
            let gapBlur = Double(dim) * maxAngle / Double(count) * 0.35
            let sigma = max((1.2 + 3.4 * strength) * (0.4 + 0.7 * min(amplitude, 1.4)), gapBlur)
            return swirled.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
        }

        /// Arcs lumineux incrustés par-dessus le filé : les hautes
        /// lumières PONCTUELLES s'étirent en arcs brillants autour du
        /// centre — la signature visible du tourbillon, celle des visuels,
        /// même quand le filé des textures reste discret.
        func arcOverlay(on result: CIImage, mask: CIImage?) -> CIImage {
            guard strength > 0.3,
                  let points = pointHighlights(of: img, extent: extent, dim: dim)
            else { return result }
            let colored = multiplied(img, points).cropped(to: extent)
            let maxAngle = 0.38 * strength
            let count = 14
            let offsets = (0..<count).map { -1.0 + 2.0 * Double($0) / Double(count - 1) }
            var accumulated: CIImage?
            for (index, offset) in offsets.enumerated() {
                let angle = CGFloat(offset * maxAngle)
                let transform = CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: angle)
                    .translatedBy(x: -center.x, y: -center.y)
                let rotated = colored.clampedToExtent()
                    .transformed(by: transform).cropped(to: extent)
                if let acc = accumulated {
                    let mix = CIFilter.dissolveTransition()
                    mix.inputImage = acc
                    mix.targetImage = rotated
                    mix.time = Float(1.0 / Double(index + 1))
                    accumulated = mix.outputImage ?? acc
                } else {
                    accumulated = rotated
                }
            }
            guard var arcs = accumulated else { return result }
            // Même plancher de fusion que le filé : le flou doit combler
            // l'écart réel entre copies (arc / nombre de copies), sinon
            // chaque point devient un CHAPELET de répliques discrètes —
            // chenilles blanches en pointillés au lieu d'arcs continus.
            let fuse = max(2.5, Double(dim) * maxAngle / Double(count) * 0.35)
            arcs = arcs.clampedToExtent().applyingGaussianBlur(sigma: fuse)
                .cropped(to: extent)
            // La moyenne dilue chaque point sur la longueur de l'arc :
            // gain de compensation contenu — trop fort, il brûlait les
            // arcs en blanc et lavait l'image entière.
            arcs = dimmed(arcs, to: 3.0)
            if let mask {
                arcs = multiplied(arcs, mask).cropped(to: extent)
            }
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = arcs
            screen.backgroundImage = result
            return screen.outputImage ?? result
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
            return arcOverlay(on: out, mask: customMask)
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
        return arcOverlay(on: blend.outputImage ?? img, mask: mask)
    }

    /// DÉFOCALISATION DE L'ARRIÈRE-PLAN — la séparation sujet/fond.
    ///
    /// C'est le trait qui fait lire « objectif ouvert » sur n'importe
    /// quelle scène, mur nu compris : aucun point de lumière n'est requis,
    /// contrairement aux disques de bokeh. Le sigma vient de l'ouverture
    /// calculée du verre (`aperture`), pas d'un coefficient global : entre
    /// le zoom ciné et le Trioplan 100 mm, le rapport est de 1 à 3,7 —
    /// aucune valeur unique ne pouvait convenir aux neuf.
    ///
    /// Le flou est GRADUÉ quand la profondeur est disponible : le fond
    /// lointain reçoit une seconde passe, en cascade (les variances
    /// s'additionnent). C'est ce gradient, plus que la valeur absolue,
    /// que l'œil lit comme du relief.
    private func applyDefocus(_ img: CIImage, lens: LensProfile, k: Double,
                              extent: CGRect, center: CGPoint, dim: CGFloat,
                              mask: CIImage, graded: Bool) -> CIImage {
        let strength = lens.aperture * k
        // Garde exprimée en PIXELS : un sigma sous 1 px ne se voit à aucune
        // résolution, et le seuil suit l'image au lieu d'être arbitraire.
        guard strength * dim > 1.0 else { return img }

        // Plafond absolu à 40 px : proportionnel à `dim`, le rayon
        // atteindrait 74 px en 4K, où le flou coûte cher sans rien ajouter
        // — au-delà, le fond est déjà une pâte uniforme.
        let maxRadius = min(dim * strength, 40)

        // PYRAMIDE DE DÉFOCALISATION. Sur un vrai objectif, le cercle de
        // confusion croît continûment avec la distance : il n'existe pas
        // « une » zone floue mais un dégradé. Deux niveaux laissaient une
        // marche visible entre le sujet net et le fond ; trois donnent un
        // fondu que l'œil lit comme de la profondeur.
        //
        // Chaque niveau est empilé sur la sortie du précédent, en ne
        // touchant que la tranche de distance qui lui revient — le rayon
        // effectif s'y accumule, comme le fait le cercle de confusion.
        // Les tranches se recouvrent volontairement : une frontière nette
        // entre deux niveaux se verrait comme un contour.
        let levels: [(radius: CGFloat, from: CGFloat, to: CGFloat)] = graded
            ? [(maxRadius * 0.45, 0.10, 0.45),
               (maxRadius * 0.70, 0.40, 0.75),
               (maxRadius, 0.70, 1.00)]
            : [(maxRadius * 0.60, 0.10, 0.55),
               (maxRadius, 0.50, 1.00)]

        var out = img
        for level in levels {
            let blurred = defocusedCopy(of: out, lens: lens,
                                        radius: level.radius, extent: extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = blurred
            blend.backgroundImage = out
            blend.maskImage = ramp(mask, from: level.from, to: level.to)
            out = blend.outputImage ?? out
        }
        return out.cropped(to: extent)
    }

    /// Copie DÉFOCALISÉE — le passage du filtre au verre.
    ///
    /// Un flou gaussien étale un point de lumière en tache terne : il
    /// répartit son énergie sur une cloche, et le sommet s'effondre. Un
    /// objectif, lui, projette ce point en un DISQUE net et brillant, dont
    /// le bord concentre la lumière — c'est ce disque, et lui seul, qu'on
    /// appelle bokeh.
    ///
    /// `CIBokehBlur` fait exactement cela : disques d'énergie conservée,
    /// avec un anneau de bord réglable. Il rend donc gratuitement, et pour
    /// TOUTE l'image, ce que la chaîne fabriquait péniblement par
    /// morphologie sur les seules hautes lumières détectées — d'où le
    /// caractère « bulles de savon » du Trioplan, obtenu ici en réglant
    /// l'anneau plutôt qu'en dessinant des contours.
    ///
    /// Repli explicite sur le flou gaussien si le filtre est indisponible :
    /// l'API rend un optionnel, la chaîne ne doit jamais s'interrompre.
    private func defocusedCopy(of img: CIImage, lens: LensProfile,
                               radius: CGFloat, extent: CGRect) -> CIImage {
        // Le rayon d'un disque vaut environ le double du sigma d'une
        // gaussienne d'étalement comparable.
        let discRadius = max(1, radius * 2)

        // TRAVAIL EN RÉSOLUTION RÉDUITE. Le coût d'un bokeh croît avec le
        // carré du rayon : à 80 px il devient le poste le plus lourd de la
        // trame. Or une image déjà défocalisée ne contient, par
        // définition, aucun détail fin — la réduire avant de la flouter ne
        // perd rien et divise le coût d'autant. On vise un rayon de
        // travail d'une douzaine de pixels, quelle que soit la résolution
        // de départ : c'est ce qui rend le rendu identique du viseur à
        // l'export 3200 px, là où un rayon en pixels absolus donnerait
        // deux images différentes.
        let scale = min(1, 14 / discRadius)
        let source = img.clampedToExtent()
        let small = scale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source

        let bokeh = CIFilter.bokehBlur()
        bokeh.inputImage = small.clampedToExtent()
        bokeh.radius = Float(min(500, max(1, discRadius * scale)))
        // L'anneau de bord EST la signature du verre : marqué sur le
        // triplet Trioplan dont l'aberration sphérique n'est pas corrigée,
        // absent des formules modernes bien corrigées.
        bokeh.ringAmount = Float(min(1, lens.bubble))
        bokeh.ringSize = Float(0.10 + 0.10 * min(1, lens.bubble))
        bokeh.softness = 1.0

        guard let blurred = bokeh.outputImage else {
            // Repli : l'API rend un optionnel, la chaîne ne doit jamais
            // s'interrompre.
            return source.applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        guard scale < 1 else { return blurred.cropped(to: extent) }
        return blurred
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
    }

    /// Perte de piqué vers les bords du CHAMP — une aberration radiale,
    /// distincte de la défocalisation : elle touche les coins quelle que
    /// soit la distance, et reste discrète.
    private func applyEdgeSoftness(_ img: CIImage, lens: LensProfile, k: Double,
                                   extent: CGRect, center: CGPoint, dim: CGFloat) -> CIImage {
        let strength = lens.softness * k
        guard strength > 0.02 else { return img }
        let sigma = dim * 0.008 * strength
        let blurred = img.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)
        let mask = radialMask(extent: extent, center: center,
                              inner: dim * 0.34, outer: dim * 0.80)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = blurred
        blend.backgroundImage = img
        blend.maskImage = mask
        return blend.outputImage ?? img
    }

    /// Bokeh des hautes lumières : chaque point de lumière hors du plan
    /// de netteté devient un DISQUE brillant qui garde sa couleur.
    ///
    /// C'est le trait le plus reconnaissable d'un objectif ouvert, et
    /// celui qu'aucun flou ne sait produire : un flou gaussien étale un
    /// point lumineux en tache terne, là où le verre en fait un disque
    /// net et éclatant. Les points sont donc dilatés en disques, bordés
    /// du liseré des verres anciens (l'aberration sphérique concentre la
    /// lumière sur le bord) — et carrément creusés en anneau pour le
    /// Trioplan, dont c'est la signature (« bulles de savon »).
    ///
    /// Avec une carte de profondeur, le diamètre croît avec la distance
    /// au plan de netteté, comme sur un vrai objectif.
    private func applyHighlightBokeh(_ img: CIImage, lens: LensProfile, k: Double,
                                     extent: CGRect, dim: CGFloat,
                                     customMask: CIImage? = nil,
                                     bands: [(factor: Double, weight: CIImage)]? = nil,
                                     pointSource: CIImage? = nil) -> CIImage {
        let strength = lens.bokeh * k
        guard strength > 0.15 else { return img }
        // Au-delà de la moitié, le disque est creux : c'est une bulle.
        let hollow = lens.bubble > 0.5

        // Détection sur l'image NETTE fournie par render() : le flou de
        // défocalisation a déjà effacé les points de lumière de `img`.
        // Avec un masque de profondeur, seules les hautes lumières de
        // l'ARRIÈRE-PLAN engendrent des disques : celles du sujet
        // (chemise blanche, reflets du visage) produisaient des taches
        // collées à la silhouette au lieu de venir du fond.
        let detectSource = pointSource ?? img
        let source = customMask.map { multiplied(detectSource, $0) } ?? detectSource
        guard let highlights = pointHighlights(of: source, extent: extent, dim: dim)
        else { return img }

        // Le disque hérite de la COULEUR de sa source : bokeh chaud sous
        // une lampe, froid sous un néon — un disque blanc uniforme
        // trahissait immédiatement la simulation.
        let colored = multiplied(source, highlights).cropped(to: extent)

        let baseRadius = Float(max(6, dim * 0.030 * (0.4 + strength)))

        /// Disques construits à partir des points de lumière.
        func discLayer(radius: Float) -> CIImage? {
            let dilate = CIFilter.morphologyMaximum()
            dilate.inputImage = colored.clampedToExtent()
            dilate.radius = radius
            guard let dilated = dilate.outputImage else { return nil }
            // La morphologie de Core Image travaille sur un octogone :
            // sans adoucissement, les disques sortent à facettes.
            var discs = dilated.applyingGaussianBlur(sigma: Double(radius) * 0.14)

            let gradient = CIFilter.morphologyGradient()
            gradient.inputImage = discs
            gradient.radius = max(1.5, radius * 0.18)
            if let rim = gradient.outputImage?
                .applyingGaussianBlur(sigma: 1.5).cropped(to: extent) {
                // Maximum et non addition : sommer deux couches ferait
                // monter l'alpha au-dessus de 1 et le rendu prémultiplié
                // assombrirait toute la zone.
                discs = hollow ? rim : maxed(discs.cropped(to: extent), scaled(rim, by: 0.6))
            }
            // Gain réduit depuis que la défocalisation produit elle-même
            // de vrais disques : cette couche ne fait plus que renforcer
            // les points les plus vifs. À pleine puissance, les deux
            // rayons légèrement différents dessineraient un double anneau.
            return scaled(discs.cropped(to: extent),
                          by: CGFloat(min(1.0, 0.8 * strength)))
        }

        guard let customMask else {
            // Sans profondeur : une seule taille de disques, partout.
            guard let discs = discLayer(radius: baseRadius) else { return img }
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = discs
            screen.backgroundImage = img
            return screen.outputImage ?? img
        }

        // Sauf pour les verres les plus ouverts, la variation de diamètre
        // d'une bande à l'autre ne se voit pas : une seule couche pondérée
        // par la profondeur suffit — et coûte une morphologie au lieu de
        // trois, ce qui compte dans le viseur.
        if strength < 0.75 {
            guard var discs = discLayer(radius: baseRadius) else { return img }
            discs = multiplied(discs, customMask).cropped(to: extent)
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = discs
            screen.backgroundImage = img
            return screen.outputImage ?? img
        }

        // Couches réparties sur les bandes de distance partagées :
        // proches du plan de netteté → petits disques, lointaines → larges.
        var out = img
        for band in bands ?? depthBands(customMask) {
            guard var discs = discLayer(radius: max(3, baseRadius * Float(band.factor)))
            else { continue }
            discs = multiplied(discs, band.weight).cropped(to: extent)
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = discs
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
        // La sortie anticipée doit tenir compte des DEUX effets rendus
        // ici : un profil qui n'aurait que du voile et pas de halation
        // sortirait sinon sans rien faire.
        guard strength > 0.02 || lens.veil * k > 0.02 else { return img }
        // Le halo naît des HAUTES LUMIÈRES seulement. Donner l'image
        // entière à CIBloom (et la remplacer par sa version bloomée)
        // noyait toute la photo sous un voile laiteux dès que le glow
        // montait (Dream Lens, Noctilux) : brouillard blanc sur tout le
        // cadre, plus aucun détail visible. Désormais : extraction des
        // tons clairs, bloom de ces tons seuls, et incrustation écran du
        // halo par-dessus l'image INTACTE — le glow entoure les lumières
        // (halation), il ne voile plus l'image.
        // Avec un masque de profondeur, les hautes lumières du sujet
        // (chemise blanche, visage) sont éteintes avant le bloom : pas de
        // halo collé à la silhouette ; le halo du fond est pondéré par le
        // masque.
        let source = customMask.map { multiplied(img, $0) } ?? img
        // Seuil à 0,55 : assez bas pour qu'une lampe ou une fenêtre
        // suffisent dans une pièce sombre, assez haut pour qu'un ciel ou
        // un sable de plage entiers ne « bloomen » pas — à 0,45, les
        // scènes de jour se noyaient sous un voile blanc.
        // Intensité et rayon généreux : le halo doit envelopper les
        // lumières d'un voile VAPOREUX et LUMINEUX (Dream Lens,
        // Noctilux), incrusté en écran par-dessus l'image intacte — il
        // éclaircit, jamais ne grise.
        let highlights = ramp(source, from: 0.55, to: 0.92)
        let bloom = CIFilter.bloom()
        bloom.inputImage = highlights.clampedToExtent()
        // Intensité contenue : le halo est une aura, pas un projecteur —
        // à 2,5 le débordement d'une chemise blanche dessinait un liseré
        // d'ange autour du sujet en plein jour.
        bloom.intensity = Float(1.6 * strength)
        // Rayon plafonné à 100 : au-delà, CIBloom sort de sa plage
        // documentée — sur un export 3200 px le rayon calculé la
        // dépassait, halo incohérent entre viseur et photo enregistrée.
        bloom.radius = Float(min(100, dim * 0.032 * (0.5 + strength)))
        guard let halo = bloom.outputImage?.cropped(to: extent) else { return img }

        // VOILE ONIRIQUE (Orton) : copie floue incrustée en écran sur
        // tout le cadre — la promesse du Dream Lens se voit sur n'importe
        // quelle scène, même sans haute lumière. Il a désormais son PROPRE
        // paramètre au lieu d'un seuil sur `glow` : la halation autour des
        // hautes lumières et le voile général sont deux phénomènes
        // distincts, qui méritent deux réglages. L'incrustation écran
        // ÉCLAIRCIT toujours, elle ne peut pas griser : rien à voir avec
        // l'ancien voile laiteux qui remplaçait l'image par sa version
        // bloomée.
        var out = img
        let veilStrength = lens.veil * k
        if veilStrength > 0.02 {
            let dreamy = img.clampedToExtent()
                .applyingGaussianBlur(sigma: dim * 0.020 * veilStrength)
                .cropped(to: extent)
            let veil = dimmed(dreamy, to: 0.42 * CGFloat(veilStrength))
            let orton = CIFilter.screenBlendMode()
            orton.inputImage = veil
            orton.backgroundImage = out
            out = orton.outputImage ?? out
        }

        // HALATION = DÉBORDEMENT DANS L'OMBRE : le halo ne s'ajoute
        // qu'en dehors des zones claires qui l'engendrent, ET pondéré par
        // l'obscurité de la zone qui le reçoit — une lampe déborde
        // pleinement dans une pièce sombre, à peine sur une mer de midi.
        // Incruster le bloom d'une plage entière sur elle-même noyait les
        // photos de jour sous une marée blanche.
        let luma = CIFilter.colorControls()
        luma.inputImage = img
        luma.saturation = 0
        let ambient = (luma.outputImage ?? img).clampedToExtent()
            .applyingGaussianBlur(sigma: dim * 0.03)
            .cropped(to: extent)
        let spill = multiplied(multiplied(halo, inverted(highlights)),
                               inverted(ambient)).cropped(to: extent)

        let weighted = customMask.map {
            multiplied(spill, boosted($0, floor: 0.35)).cropped(to: extent)
        } ?? spill
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = weighted
        screen.backgroundImage = out
        return screen.outputImage ?? out
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
        // Garde sur le PROFIL : les verres dont le décalage resterait sous
        // le pixel (Summicron, Noct-Nikkor) sont écartés une fois pour
        // toutes. Le second seuil, lui, ne dépend que de la molette — sans
        // cette séparation, l'intensité se comportait en interrupteur.
        guard lens.chroma >= 0.13, strength > 0.02 else { return img }
        // Franges renforcées : sous 0.010 le décalage restait sous le seuil
        // de visibilité sur un écran de téléphone.
        let baseDelta = 0.014 * strength

        /// Image dont les franges sont décalées d'un delta donné.
        func aberrated(delta: Double) -> CIImage? {
            let clamped = img.clampedToExtent()
            // Alpha = 1 sur les TROIS canaux : les tampons intermédiaires
            // de Core Image sont prémultipliés (RVB ≤ alpha) — un canal à
            // alpha 0 verrait ses couleurs écrasées à zéro sur l'appareil,
            // et seul le vert survivrait (image entièrement verte).
            let red = channel(clamped, r: 1, g: 0, b: 0, keepAlpha: true)
                .transformed(by: scaleAround(center, factor: 1 + delta))
                .cropped(to: extent)
            let green = channel(clamped, r: 0, g: 1, b: 0, keepAlpha: true)
                .cropped(to: extent)
            let blue = channel(clamped, r: 0, g: 0, b: 1, keepAlpha: true)
                .transformed(by: scaleAround(center, factor: 1 - delta))
                .cropped(to: extent)

            // Assemblage par MAXIMUM et non par addition : les canaux sont
            // disjoints (max = somme composante par composante) mais
            // l'alpha reste à 1. L'addition portait l'alpha à 3, et le
            // rendu prémultiplié compensait en divisant les couleurs par
            // trois — TOUTE la zone couverte par la couche d'aberration
            // sortait trois fois trop sombre : image terne sans
            // profondeur, et grand rond sombre au-delà du rayon où le
            // masque profondeur ∪ champ atteint 100 %.
            let maxRG = CIFilter.maximumCompositing()
            maxRG.inputImage = red
            maxRG.backgroundImage = green
            guard let rg = maxRG.outputImage else { return nil }

            let maxRGB = CIFilter.maximumCompositing()
            maxRGB.inputImage = blue
            maxRGB.backgroundImage = rg
            return maxRGB.outputImage
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
        // Vignettage MAISON plutôt que CIVignetteEffect : le rayon de ce
        // filtre est plafonné (~2000 px) — correct dans le viseur
        // (900 px), il était silencieusement réduit sur les exports
        // 3200 px et l'assombrissement avalait un tiers de l'image : le
        // grand rond sombre des photos enregistrées, absent du viseur.
        // Ici : copie légèrement assombrie mélangée par un masque radial
        // calé sur la demi-diagonale RÉELLE de l'image — rendu identique
        // à toutes les résolutions, et un simple souffle dans les angles
        // (assombrissement max ~14 % au fin fond des coins) : le
        // vignettage signe les angles sans manger la lumière du cadre.
        // Amplitude et portée d'un vrai vignettage : c'est le SEUL effet
        // de toute la chaîne qui se lise sur n'importe quelle scène, mur
        // nu compris, et le moins cher (un gradient et deux filtres
        // ponctuels). À 14 % il ne se voyait pas ; à 32 %, modulés par le
        // profil (0,20 pour le Summicron, 0,65 pour le Noctilux), il
        // signe le cadre. Le gamma resserre la chute sur les angles :
        // le centre de l'image reste intact.
        let corner = hypot(extent.width, extent.height) / 2
        let darkened = dimmed(img, to: 1 - 0.32 * CGFloat(strength))
        let mask = radialMask(extent: extent, center: center,
                              inner: corner * 0.42, outer: corner * 1.02)
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.8])
        let blend = CIFilter.blendWithMask()
        blend.inputImage = darkened
        blend.backgroundImage = img
        blend.maskImage = mask
        guard let vignetted = blend.outputImage else { return img }

        guard let customMask else { return vignetted }
        let depthBlend = CIFilter.blendWithMask()
        depthBlend.inputImage = vignetted.cropped(to: extent)
        depthBlend.backgroundImage = img
        depthBlend.maskImage = boosted(customMask, floor: 0.5)
        return depthBlend.outputImage ?? vignetted
    }

    /// Copie assombrie : RVB multiplié par `factor`, alpha inchangé.
    private func dimmed(_ img: CIImage, to factor: CGFloat) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = img
        matrix.rVector = CIVector(x: factor, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: factor, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: factor, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? img
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
        // out = 0.5 + (bruit − 0.5) × amplitude. Amplitude franche : le
        // grain ciné de l'Angénieux est une texture qui se voit, pas un
        // soupçon.
        let amp = CGFloat(0.50 * strength)
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
        // DEUX bandes et non trois : la différence entre la bande médiane
        // et ses voisines n'était pas perceptible, alors qu'elle coûtait
        // une chaîne complète d'effets par trame. Les deux bandes qui
        // restent portent un écart franc — c'est ce qui finance le
        // nouveau flou d'arrière-plan sans dépasser le budget GPU.
        let rampNear = ramp(mask, from: 0.25, to: 0.55)
        let rampFar = ramp(mask, from: 0.60, to: 0.92)
        return [
            (0.7, multiplied(rampNear, inverted(rampFar))),
            (1.3, rampFar),
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

    /// Masque des hautes lumières PONCTUELLES d'une image : seuil de
    /// luminance puis ouverture morphologique soustraite — les points de
    /// lumière (lampes, reflets, guirlandes) restent, les grandes plages
    /// claires (ciel, écrans, vêtements blancs) disparaissent, elles qui
    /// se retrouvaient sinon cerclées d'un liseré. Partagé par les bulles
    /// de savon et les arcs du tourbillon.
    private func pointHighlights(of img: CIImage, extent: CGRect,
                                 dim: CGFloat) -> CIImage? {
        let mono = CIFilter.colorControls()
        mono.inputImage = img
        mono.saturation = 0
        mono.contrast = 1
        guard let gray = mono.outputImage else { return nil }

        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = gray
        // Seuil exigeant, mais plus praticable qu'à 0,70 : à ce niveau,
        // une lampe d'intérieur ordinaire n'était même pas reconnue. La
        // protection contre les fausses sources (anneaux sur les nuages,
        // chapelets sur les surfaces claires) ne vient PAS de ce seuil
        // mais de l'exigence d'entourage sombre, plus bas — inchangée.
        threshold.threshold = 0.58
        guard let thresholded = threshold.outputImage else { return nil }

        // Ouverture (érosion puis dilatation légèrement plus large) :
        // efface les points, conserve les grandes plages — soustraites du
        // masque initial, il ne reste que les points. La dilatation
        // élargie couvre entièrement le bord des grandes plages, sinon un
        // filet d'un pixel y survivrait.
        // Rayon plafonné à 83 px : proportionnel, il atteindrait 86 px en
        // 4K, au-delà de la plage où la morphologie de Core Image reste
        // raisonnable — et son coût croît avec le rayon.
        let openRadius = Float(min(83, max(4, dim * 0.020)))
        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = thresholded.clampedToExtent()
        erode.radius = openRadius
        let reDilate = CIFilter.morphologyMaximum()
        reDilate.inputImage = erode.outputImage
        reDilate.radius = openRadius * 1.2
        guard let broad = reDilate.outputImage?.cropped(to: extent) else { return nil }
        let compact = multiplied(thresholded, inverted(broad))

        // Un point de lumière n'existe que SUR FOND PLUS SOMBRE — une
        // bulle de savon n'est visible que là. L'ouverture élimine les
        // grandes surfaces mais laisse passer leurs bords fins et longs
        // (festons de nuages, reflets du sable mouillé), qui se faisaient
        // cercler. L'entourage moyen (grand flou) tranche : entourage
        // clair → pas un point, juste le détail d'une surface claire.
        let surroundings = gray.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(openRadius) * 3.0)
            .cropped(to: extent)
        // Rampe stricte : l'entourage doit être franchement sombre. Un
        // éclat niché dans un environnement moyen (horizon, mer de jour)
        // ne fait pas de bulle — sur un vrai objectif non plus.
        let isolation = ramp(inverted(surroundings), from: 0.45, to: 0.70)
        return multiplied(compact, isolation).cropped(to: extent)
    }

    /// Union de deux masques : maximum pixel à pixel.
    private func maxed(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.maximumCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
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
