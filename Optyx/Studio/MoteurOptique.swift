import CoreImage
import UIKit

// MARK: - Moteur optique
//
// Le rendu photo d'Optyx, entièrement en Core Image. INTERNE et non privé : le
// studio l'appelle sur une photo importée, le viseur caméra l'appellera sur une
// image de flux. Il ne doit exister qu'UN seul moteur — deux moteurs dont un
// mort finissent toujours par diverger, c'est déjà arrivé dans ce dépôt.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE PRINCIPE, qui commande tout ce fichier
// ─────────────────────────────────────────────────────────────────────────────
//
// Un vrai objectif ancien, sur une photo de plage en plein jour, ne fabrique PAS
// de bulles de savon : il n'y a aucune source ponctuelle à transformer en
// disque. Ce qu'il fait, c'est SÉPARER le sujet du fond, TEINTER les couleurs,
// ASSOMBRIR les coins et VOILER légèrement les hautes lumières. Une app qui
// invente des anneaux là où l'optique n'en produit aucun fabrique un artefact.
//
// La chaîne se compose donc de trois étages, dont seul le troisième est
// conditionnel :
//
//   A. SIGNATURE TONALE — toujours active. Dérive de couleur propre au verre,
//      contraste, saturation, vignettage, grain. Ne déplace aucun pixel, donc
//      structurellement incapable de produire un artefact.
//   B. DÉFOCALISATION DE L'ARRIÈRE-PLAN — toujours active. `CIBokehBlur`, masqué
//      pour que le centre du cadre reste net. C'est le trait le plus
//      reconnaissable d'un 58 mm f/2, et le seul qui se lise sur N'IMPORTE
//      QUELLE photo.
//   C. DISQUES DE BOKEH — seulement quand la photo les MÉRITE, c'est-à-dire
//      quand elle porte de vraies sources ponctuelles isolées. Sur la plage :
//      étage vide, et c'est le comportement CORRECT. Sur une rue de nuit :
//      spectaculaire.
//
// Ce conditionnement n'est PAS un interrupteur arbitraire : il tombe tout seul
// parce que la détection des points est stricte (§ DÉTECTION) et parce qu'un
// garde-fou de couverture éteint l'étage quand les « points » couvrent trop de
// cadre pour en être. Aucun point isolé → couche noire → `CIScreenBlendMode`
// avec du noir est l'identité exacte. Auto-régulé et honnête.
//
// ─────────────────────────────────────────────────────────────────────────────
// RÈGLES TRANSVERSES — ne jamais les enfreindre
// ─────────────────────────────────────────────────────────────────────────────
//
// R1 — ALPHA. Aucune addition d'images. Composition uniquement par
//      `CIScreenBlendMode`, `CIMaximumCompositing`, `CIMultiplyCompositing`,
//      `CIBlendWithMask` et `CISoftLightBlendMode`. Sommer deux calques
//      prémultipliés d'alpha 1 donne un alpha 2 que la composition suivante
//      réinterprète : c'est le bug qui a noirci deux fois l'ancienne app. Toute
//      `CIColorMatrix` laisse sa ligne alpha à (0, 0, 0, 1) et le `w` de son
//      biais à 0 — sauf le grain, qui fixe alpha à 1, ce qui est également sûr.
//
// R2 — ÉTENDUE. Tout filtre à support spatial est précédé de
//      `.clampedToExtent()` et suivi de `.cropped(to: cadre)`. Sans le clamp,
//      l'extérieur du cadre vaut « noir transparent » : l'érosion verrait une
//      bordure sombre tout autour de l'image et TOUTE la périphérie passerait le
//      test d'entourage. Piège majeur pour l'étage C.
//
// R3 — ÉCHELLE. Toute longueur ET tout plafond s'expriment en fraction du grand
//      (ou du petit) côté, la conversion en pixels vient en dernier. L'ancien
//      moteur bornait en pixels absolus, et l'aperçu 1200 px cessait d'être
//      l'export 3200 px dès que la borne mordait.
//
// R4 — DIFFÉRENCE MORPHOLOGIQUE. `CIDifferenceBlendMode` n'est autorisé qu'entre
//      deux dilatations EMBOÎTÉES de la même source, floutées à la MÊME largeur.
//      Dans ce cas dilate(m, R) ≥ dilate(m, ρR) partout : la différence est une
//      soustraction exacte, elle vaut 0 sur tout plateau et ne peut produire
//      qu'une couronne. C'est le verrou structurel contre les liserés.
//
// R5 — SENS DE LA PANNE. Quand une mesure échoue (lecture GPU, filtre nil), on
//      DÉSACTIVE l'étage C. Le mode de défaillance acceptable est « pas de
//      disques », jamais « disques faux ».

enum MoteurOptique {

    // MARK: - Contexte partagé

    /// Un seul contexte pour toute la durée de vie de l'app.
    ///
    /// `CIContext` compile ses noyaux à la première utilisation et les met en
    /// cache ; en recréer un à chaque mouvement du curseur rendrait chaque
    /// aperçu aussi lent que le premier. Il est documenté comme utilisable
    /// depuis plusieurs fils, ce qui est exactement l'usage ici.
    ///
    /// ESPACE DE TRAVAIL sRGB, et non le linéaire par défaut : tous les seuils
    /// de ce fichier (0,88 pour une haute lumière, 0,72 pour le voile) sont
    /// raisonnés en valeurs sRGB — « ciel bleu franc ≈ 0,63 ; sable clair au
    /// soleil ≈ 0,75 ; t-shirt blanc ≈ 0,97 ». Dans l'espace linéaire par
    /// défaut, ces mêmes nombres désigneraient des luminances tout autres et la
    /// détection se déréglerait silencieusement. Fixer l'espace de travail est
    /// la seule façon de faire coïncider le code et son raisonnement.
    static let contexteImages: CIContext = {
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
            return CIContext(options: [.workingColorSpace: sRGB])
        }
        return CIContext()
    }()

    /// Aperçu réduit : au-delà, chaque mouvement du curseur ferait attendre
    /// l'utilisateur, ce qui revient à lui interdire d'explorer.
    static let coteApercu: CGFloat = 1200

    /// Export. 3200 px sur le plus grand côté suffit à un tirage A3 et garde la
    /// morphologie (l'étape la plus coûteuse) dans des durées acceptables.
    static let coteExport: CGFloat = 3200

    // MARK: - Préparation

    /// Décode et réduit, en normalisant l'orientation.
    ///
    /// Le passage par `UIGraphicsImageRenderer` n'est pas un détour : c'est
    /// `UIImage.draw(in:)` qui applique l'orientation EXIF. Un `CIImage(data:)`
    /// direct livrerait les pixels bruts, et toutes les photos prises en
    /// portrait sortiraient couchées — panne classique et parfaitement
    /// silencieuse.
    static func imageReduite(donnees: Data, coteMax: CGFloat) -> UIImage? {
        guard let source = UIImage(data: donnees) else { return nil }

        let largeurPixels = source.size.width * source.scale
        let hauteurPixels = source.size.height * source.scale
        let plusGrandCote = max(largeurPixels, hauteurPixels)
        guard plusGrandCote > 0 else { return nil }

        // Jamais d'agrandissement : interpoler une petite image ne créerait
        // aucun détail et multiplierait le coût du filtrage.
        let facteur = min(1, coteMax / plusGrandCote)
        let cible = CGSize(width: max(1, (largeurPixels * facteur).rounded()),
                           height: max(1, (hauteurPixels * facteur).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        // Échelle 1 : on raisonne en pixels, pas en points. Laisser l'échelle de
        // l'écran multiplierait silencieusement la taille par 3 sur un iPhone
        // Pro et ferait mentir `coteMax`.
        format.scale = 1
        // Opaque : une photo n'a pas de transparence, et un canal alpha inutile
        // est une invitation de plus au piège du prémultiplié.
        format.opaque = true

        return UIGraphicsImageRenderer(size: cible, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: cible))
        }
    }

    /// Chaîne complète : décodage, réduction, effet optique, retour en `UIImage`.
    ///
    /// Renvoie `nil` si la tâche a été annulée entre deux étapes — l'appelant
    /// jette alors le résultat sans rien afficher.
    static func rendre(donnees: Data, lens: Lens, intensite: Float, coteMax: CGFloat) -> UIImage? {
        guard let reduite = imageReduite(donnees: donnees, coteMax: coteMax) else { return nil }
        if Task.isCancelled { return nil }

        guard let base = CIImage(image: reduite) else { return nil }
        let cadre = base.extent
        guard cadre.width > 0, cadre.height > 0 else { return nil }

        let resultat = appliquer(base, lens: lens, intensite: intensite, cadre: cadre)
        if Task.isCancelled { return nil }

        guard let cg = contexteImages.createCGImage(resultat, from: cadre) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    // MARK: - Graphe d'effets

    /// Applique la signature d'un objectif à une image.
    ///
    /// `cadre` est passé explicitement plutôt que lu dans `base.extent` : un
    /// flux caméra livre parfois une étendue infinie, et tout ce fichier repose
    /// sur un cadre fini pour ses recadrages et ses masques radiaux.
    ///
    /// `disquesAutorises` gouverne le seul étage COÛTEUX de la chaîne. L'étage C
    /// mesure sa propre porte par un `render(toBitmap:)`, c'est-à-dire une lecture
    /// GPU→CPU SYNCHRONE : elle vide le pipeline et sérialise CPU et GPU. Sur le
    /// chemin photo, payée une fois, elle est sans conséquence. Sur le chemin
    /// viseur, où `appliquer` est invoquée à chaque trame, elle est le point dur
    /// du budget d'image. Le paramètre vaut `true` par défaut, donc rien ne change
    /// pour les appelants existants ; l'appelant caméra peut le passer à `false`
    /// (ou ne le remettre à `true` qu'une trame sur N) pour retrouver la fluidité
    /// du viseur sans toucher au rendu de l'export. Les étages A et B — couleur,
    /// défocalisation, vignettage, les trois traits qui doivent se lire sur TOUTE
    /// photo — ne sont jamais concernés.
    static func appliquer(_ base: CIImage,
                          lens: Lens,
                          intensite: Float,
                          cadre: CGRect,
                          disquesAutorises: Bool = true) -> CIImage {

        guard cadre.width >= 8, cadre.height >= 8 else { return base }

        let k = CGFloat(min(max(intensite, 0), 1))
        let p = lens.bokeh

        // Sous 2 % d'intensité l'image renvoyée est la photo nue : recalculer
        // une douzaine de filtres pour un résultat identique au pixel près
        // serait du temps volé à l'utilisateur qui balaie le curseur.
        if k < 0.02 { return base }

        let grandCote = max(cadre.width, cadre.height)
        let petitCote = min(cadre.width, cadre.height)
        let centre = CIVector(x: cadre.midX, y: cadre.midY)
        let sig = SignatureTonale.pour(lens)

        // ─────────────────────────────────────────────────────────────────────
        // A1. MATRICE DE CANAUX — gain (hautes lumières) + biais (ombres), puis
        // saturation et contraste. Voir SignatureTonale.swift pour la mécanique
        // et la justification ligne à ligne des neuf verres.
        // ─────────────────────────────────────────────────────────────────────
        let gR = 1 + (sig.gainR - 1) * k
        let gV = 1 + (sig.gainV - 1) * k
        let gB = 1 + (sig.gainB - 1) * k

        let teintee = base
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gR, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gV, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gB, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: sig.biaisR * k,
                                            y: sig.biaisV * k,
                                            z: sig.biaisB * k,
                                            w: 0)
            ])
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": Float(1 + (sig.saturation - 1) * k),
                "inputContrast": Float(1 + (sig.contraste - 1) * k),
                "inputBrightness": Float(0)
            ])

        // ─────────────────────────────────────────────────────────────────────
        // B1. DÉFOCALISATION DE L'ARRIÈRE-PLAN.
        //
        // ARGUMENT CENTRAL : `CIBokehBlur` porte l'anneau DANS LE NOYAU de
        // convolution, pas dans une différence d'images. Une convolution ne peut
        // créer aucune structure sur un champ plat : l'anneau n'apparaît donc
        // QUE là où il existe réellement une haute lumière ponctuelle dans
        // l'arrière-plan. C'est la manière honnête d'obtenir les bulles du
        // Trioplan. Sur la plage, `ringAmount = 0,89` ne produira rien de
        // visible — parce qu'il n'y a rien à transformer.
        //
        // Le coefficient 0,016 : à 1200 px il donne 10 à 12 px (≈ 0,9 % du grand
        // côté) pour un 58 mm f/2, ce qui sépare visiblement le sujet du fond en
        // comparaison par appui long sans effacer la mer ni le sable. En deçà de
        // ~5 px on retombe sur « on voit rien » — c'est le cas du Summicron et du
        // Noct-Nikkor, et c'est VOULU : ce sont les deux verres nets du
        // catalogue, leur signature est le micro-contraste, pas le flou. Les
        // bornes sont relatives (R3) et ne mordent sur aucun objectif : ce sont
        // des garde-fous, pas des réglages.
        //
        // Le facteur (0,30 + 0,70·k) : à 2 % d'intensité le flou vaut encore
        // 31 % du maximum. Un départ à 0 rendrait la moitié basse du curseur
        // inutile.
        // ─────────────────────────────────────────────────────────────────────
        let rayonFlouRelatif = min(max(0.016 * CGFloat(p.size) * (0.30 + 0.70 * k), 0.0025), 0.030)

        var flou = teintee
            .clampedToExtent()
            .applyingFilter("CIBokehBlur", parameters: [
                "inputRadius": Float(grandCote * rayonFlouRelatif),
                "inputRingAmount": Float(min(0.90, 0.65 * p.ring + 0.30 * p.rim)),
                "inputRingSize": Float(0.08 + 0.14 * p.ring),
                "inputSoftness": Float(0.20 + 0.75 * p.soft)
            ])
            .cropped(to: cadre)

        // ─────────────────────────────────────────────────────────────────────
        // B2. TOURBILLON — torsion GÉOMÉTRIQUE, jamais superposition.
        //
        // L'ancienne chaîne screenait une copie tordue du calque PAR-DESSUS
        // l'image nette : chaque contour clair apparaissait donc deux fois,
        // décalé le long d'un arc. C'est la cause directe du « visage flou et
        // dédoublé » et des « contours fantômes qui suivent les bras ». Ici on
        // TORD la copie défocalisée : là où le masque vaut 1, l'image est
        // déplacée et non ajoutée, donc aucun contour ne peut se dédoubler.
        //
        // MAIS — et c'est le piège qui a reproduit l'artefact — cette garantie ne
        // tient QUE là où le masque SATURE. Partout où il est strictement compris
        // entre 0 et 1, `CIBlendWithMask` interpole linéairement entre l'image et
        // sa copie tournée : c'est un fondu-croisé, c'est-à-dire exactement le
        // régime qui dédouble. Or l'ancien réglage (rayon1 = 1,05·petitCote)
        // plafonnait à 0,75 dans le coin d'un 3:2 — le masque n'atteignait JAMAIS
        // 1 dans le cadre, et TOUTE l'image était en fondu-croisé partiel, avec
        // des déplacements de 200 à 500 px. D'où l'horizon fantôme en travers du
        // ciel et les contours fantômes sur les épaules.
        //
        // Réglage corrigé : le masque sature à 0,58·petitCote, largement à
        // l'intérieur du cadre (le coin d'un 3:2 est à 0,90·petitCote). La bande
        // de fondu ne fait plus que 0,18·petitCote au lieu de 0,60, et au-delà le
        // tourbillon est utilisé SEUL. Dans la bande résiduelle, l'angle réduit
        // (0,45 rad) maintient le déplacement sous ~60 px, du même ordre que le
        // flou de B1, qui l'absorbe.
        //
        // PROFIL : `CIVortexDistortion` tourne le plus AU CENTRE et décroît vers
        // `inputRadius` — l'inverse du tourbillon optique réel, maximal en
        // périphérie. Aucun filtre Core Image n'offre le profil inverse ; on
        // corrige en sélectionnant la couronne utile par un second masque
        // radial, décalé vers l'extérieur. Le centre — donc le visage — est
        // ainsi protégé DEUX fois : par ce masque et par celui de l'étape B3.
        //
        // L'angle est volontairement MODESTE (0,45 rad au maximum). L'ancienne
        // valeur de 2,4 rad n'était étayée par rien, et c'est elle qui rendait le
        // fondu-croisé destructeur. Un tourbillon se lit au mouvement du fond, pas
        // à l'amplitude de la rotation. L'unité est le radian.
        // ─────────────────────────────────────────────────────────────────────
        if p.swirl > 0.02,
           let masqueTourbillon = masqueRadial(cadre: cadre,
                                               rayon0: petitCote * 0.40,
                                               rayon1: petitCote * 0.58) {
            let tordu = flou
                .clampedToExtent()
                .applyingFilter("CIVortexDistortion", parameters: [
                    "inputCenter": centre,
                    "inputRadius": Float(grandCote * 0.75),
                    "inputAngle": Float(CGFloat(p.swirl) * k * 0.45)
                ])
                .cropped(to: cadre)

            flou = tordu.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": flou,
                "inputMaskImage": masqueTourbillon
            ])
        }

        // ─────────────────────────────────────────────────────────────────────
        // B3. MASQUE RADIAL — le centre du cadre reste net.
        //
        // ANCRAGE SUR LA DIAGONALE, et non sur le petit côté. L'ancrage sur le
        // petit côté paraissait neutre entre portrait et paysage ; il ne l'est pas,
        // parce que le rayon du COIN, lui, dépend de la diagonale. En PORTRAIT — le
        // cadrage naturel d'un sujet debout, et celui des captures incriminées — le
        // petit côté est la LARGEUR : pour un 800×1200 le disque net ne faisait que
        // 240 px de rayon, soit 40 % de la hauteur, et une tête cadrée en pied
        // tombait à 0,36 de masque. `CIBlendWithMask` y mélangeait 36 % d'une copie
        // floutée avec le visage net : c'est LITTÉRALEMENT le « visage flou et
        // dédoublé » reproché à la capture Helios. Effet symétrique en paysage : le
        // milieu du bord haut ne recevait que 36 % du flou, donc la séparation
        // sujet/fond — LE trait qui doit se lire sur toute photo — ne se lisait
        // presque pas.
        //
        // Avec la diagonale, le disque net garde la même taille relative dans les
        // deux orientations, et le masque SATURE à l'intérieur du cadre : pour un
        // 800×1200 comme pour un 1200×800, disque net de 375 px de rayon, flou
        // PLEIN dès 663 px alors que le coin est à 721. Le fond est donc vraiment
        // flou au lieu d'être à moitié fondu, et la bande de fondu passe de 440 à
        // 332 px.
        //
        // LIMITE ASSUMÉE : sans carte de profondeur, un sujet décentré verra une
        // partie de son corps floutée. La transition reste large pour que cette
        // erreur soit douce plutôt que franche. C'est le compromis explicite : un
        // flou radial légèrement faux est infiniment moins choquant qu'un anneau
        // inventé au bon endroit.
        // ─────────────────────────────────────────────────────────────────────
        // CORRECTION — l'ancrage sur la DIAGONALE, calibré sur un cadre 3:2,
        // s'effondre sur un cadre très allongé, c'est-à-dire précisément sur le
        // VISEUR d'un iPhone (1206×2622, rapport 2,17).
        //
        // La diagonale d'un tel cadre vaut 2,39 fois sa largeur : le disque net
        // atteignait donc 0,62 fois la largeur, alors que le bord vertical n'est
        // qu'à 0,50. Le masque valait ZÉRO sur TOUTE la largeur de l'image, et ne
        // montait qu'aux extrémités haute et basse. Le flou d'arrière-plan — le
        // trait censé se lire sur n'importe quelle photo — n'existait nulle part
        // dans le viseur.
        //
        // Ancré sur le PETIT CÔTÉ, le masque se comporte à l'identique quel que
        // soit le format, ce qui est la seule propriété qui compte ici :
        //   3:2  (800×1200)  → net jusqu'à 272, bord vertical 0,39, coin 1,00
        //   2,17 (1206×2622) → net jusqu'à 410, bord vertical 0,39, coin 1,00
        // Le disque net couvre 68 % de la largeur : un visage cadré en pied, qui
        // se tient au centre, y reste entièrement.
        let petitCoteCadre = min(cadre.width, cadre.height)

        var fond = teintee
        if let masqueFlou = masqueRadial(cadre: cadre,
                                         rayon0: petitCoteCadre * 0.34,
                                         rayon1: petitCoteCadre * 0.75) {
            fond = flou.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": teintee,
                "inputMaskImage": masqueFlou
            ])
        }

        // ─────────────────────────────────────────────────────────────────────
        // A2. VOILE DE DIFFUSION — la lumière parasite des verres anciens non
        // traités multicouche. Un grand flou gaussien ne peut créer ni anneau ni
        // bande (aucune différence, aucune morphologie) : c'est l'un des rares
        // effets sûrs sur n'importe quelle photo, et c'est lui qui « voile
        // légèrement les hautes lumières » sur la plage. Carte de hautes lumières
        // DOUCE, sans morphologie, et surtout non conditionnée aux points
        // détectés — ce n'est pas le même phénomène.
        //
        // `haze` vaut 0 à dessein chez le Summicron et le Noct-Nikkor : c'est une
        // absence de voile revendiquée dans Lens.swift, pas un oubli.
        // ─────────────────────────────────────────────────────────────────────
        if p.haze > 0.01 {
            let hautesDouces = rampe(
                base.applyingFilter("CIColorControls", parameters: [
                    "inputBrightness": Float(-0.72),
                    "inputSaturation": Float(1),
                    "inputContrast": Float(1)
                ]),
                bas: 0, haut: 0.28)

            let voile = hautesDouces
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    "inputRadius": Float(grandCote * 0.035)
                ])
                .cropped(to: cadre)

            fond = ecran(fond, avec: attenuer(voile,
                                              facteur: min(0.5, CGFloat(p.haze) * k * 1.6)))
        }

        // ─────────────────────────────────────────────────────────────────────
        // C. DISQUES DE BOKEH — conditionnels.
        // ─────────────────────────────────────────────────────────────────────
        var image = fond

        if disquesAutorises {
            let pointsDetectes = detecterPoints(base, cadre: cadre, grandCote: grandCote)
            let porte = porteDeCouverture(pointsDetectes, cadre: cadre)

            if porte >= 0.02 {
                image = ecran(fond, avec: attenuer(
                    calqueOptique(base: base,
                                  points: pointsDetectes,
                                  lens: lens,
                                  k: k,
                                  cadre: cadre,
                                  grandCote: grandCote,
                                  petitCote: petitCote,
                                  centre: centre),
                    facteur: (0.5 + 0.5 * k) * CGFloat(p.opacity) * porte))
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // A3. VIGNETTAGE GLOBAL. Placé APRÈS l'étage C, il atténue aussi les
        // disques périphériques — ce qui est physiquement juste, et rend l'œil de
        // chat partiellement redondant (d'où son amplitude réduite là-bas).
        // ─────────────────────────────────────────────────────────────────────
        if sig.vignettage > 0.01 {
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": centre,
                "inputRadius": Float(petitCote * 0.62),
                "inputIntensity": Float(sig.vignettage * k * 0.85),
                "inputFalloff": Float(0.60)
            ])
        }

        // ─────────────────────────────────────────────────────────────────────
        // A4. GRAIN. Réservé au rendu ciné de l'Angénieux (`grain` = 1 chez lui
        // seul). En lumière douce plutôt qu'en incrustation : le grain doit
        // texturer les demi-teintes sans écraser ni les noirs ni les hautes
        // lumières. Exécuté en tout dernier, sur l'image finie.
        // ─────────────────────────────────────────────────────────────────────
        if p.grain > 0.01, let bruit = CIFilter(name: "CIRandomGenerator")?.outputImage {
            // OSCILLATION du grain, exprimée directement en fraction de la plage
            // 0…1 — et non plus par un coefficient par canal, qui était la source
            // d'une panne majeure.
            //
            // L'ancien code posait `amplitude = grain·k·0,32` puis SOMMAIT les
            // trois canaux du bruit dans chaque ligne de la matrice. L'oscillation
            // réelle valait donc 3·0,32 = 0,96 : le voile balayait presque toute
            // la plage 0…1. En lumière douce, une source proche de 0 pousse vers
            // le noir et une source proche de 1 vers le blanc — le voile ne
            // texturait donc pas l'image, il la REMPLAÇAIT par de la neige. Le
            // biais recentrait bien la moyenne sur 0,5, ce qui rendait la faute
            // invisible à la lecture : seul l'écart-type était monstrueux.
            // L'Angénieux étant le seul verre à `grain` = 1, il était le seul
            // objectif touché — viseur entièrement en neige.
            //
            // 0,14 donne un voile dans [0,43 ; 0,57] : une texture qui se voit à
            // 100 % sans jamais menacer l'image. Le grain d'un tirage argentique
            // est une modulation de quelques pour cent, pas un calque opaque.
            let oscillation = CGFloat(p.grain) * k * 0.14
            // Un tiers par canal, puisque les trois sont sommés : c'est ce
            // facteur 3 qui manquait.
            let parCanal = oscillation / 3
            let socle = (1 - oscillation) / 2
            let voileGrain = bruit
                .cropped(to: cadre)
                // Désaturation puis compression autour de 0,5 : un bruit coloré
                // virerait la photo au bruit vidéo, et un bruit non recentré
                // éclaircirait ou assombrirait toute l'image.
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: parCanal, y: parCanal, z: parCanal, w: 0),
                    "inputGVector": CIVector(x: parCanal, y: parCanal, z: parCanal, w: 0),
                    "inputBVector": CIVector(x: parCanal, y: parCanal, z: parCanal, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: socle, y: socle, z: socle, w: 1)
                ])
            image = voileGrain.applyingFilter("CISoftLightBlendMode", parameters: [
                "inputBackgroundImage": image
            ])
        }

        // Recadrage final obligatoire : les flous et la dilatation ont agrandi
        // l'étendue, et un `createCGImage` sur une étendue élargie livrerait une
        // image plus grande que la photo, bordée de halo.
        return image.cropped(to: cadre)
    }

    // MARK: - Détection des points lumineux

    /// Carte des vraies sources ponctuelles, dans [0, 1].
    ///
    /// C'est ici que se joue tout le procès de l'ancien moteur. Il seuillait la
    /// luminance à 0,58 : sur une photo de plage ensoleillée, le ciel, le t-shirt
    /// blanc, l'écume et le sable clair franchissent TOUS ce seuil. La carte ne
    /// contenait donc pas des points de lumière mais la moitié de l'image, et
    /// toute la chaîne en aval — dilatation, différence, flous de mouvement —
    /// travaillait sur ce faux. D'où les liserés arc-en-ciel sur la silhouette et
    /// les traînées sur le sable.
    ///
    /// Le critère est ici COMPOSÉ de quatre termes, chacun ramené dans [0, 1] par
    /// une rampe et MULTIPLIÉS entre eux — multiplier ne peut que retirer des
    /// candidats, jamais en inventer, et l'alpha reste borné à 1 (R1).
    ///
    /// La carte est calculée sur l'image NUE, avant toute teinte : « cette source
    /// est-elle isolée ? » est une propriété de la PHOTO, pas du verre choisi. La
    /// tentative précédente indexait le rayon d'entourage sur le rayon du disque
    /// à dessiner, ce qui est une inversion de causalité : le Summicron aurait
    /// détecté des points que le Dream Lens aurait rejetés.
    private static func detecterPoints(_ base: CIImage,
                                       cadre: CGRect,
                                       grandCote: CGFloat) -> CIImage {

        // Saturation nulle : un rouge saturé ne doit pas compter comme une haute
        // lumière au seul motif que son canal rouge est écrêté.
        let luminance = base.applyingFilter("CIColorControls", parameters: [
            "inputSaturation": Float(0),
            "inputBrightness": Float(0),
            "inputContrast": Float(1)
        ])

        // Rayon d'analyse, relatif au cadre (R3) : 10,8 px à 1200, 28,8 px à 3200.
        let rayonAnalyse = Float(max(3, grandCote * 0.009))

        let erosion = luminance
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": rayonAnalyse])
            .cropped(to: cadre)

        let ouverture = erosion
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": rayonAnalyse])
            .cropped(to: cadre)

        // Chapeau haut-de-forme blanc : luminance − ouverture.
        let chapeau = luminance.applyingFilter("CIDifferenceBlendMode", parameters: [
            "inputBackgroundImage": ouverture
        ])

        // T1 — LUMINANCE ABSOLUE. 0,88 et non 0,58 : une source ponctuelle sature
        // le capteur. Repères sRGB : ciel bleu franc ≈ 0,63, sable au soleil
        // ≈ 0,75, écume ≈ 0,90, t-shirt blanc ≈ 0,97, spéculaire ponctuel ≈ 1,00
        // (écrêté). La borne haute à 0,99 plutôt que 1,00 laisse une rampe de
        // largeur non nulle : un seuil franc se lirait lui-même comme un contour.
        let t1 = rampe(luminance, bas: 0.88, haut: 0.99)

        // T2 — ENTOURAGE SOMBRE. Rampe DÉCROISSANTE sur l'érosion : au centre
        // d'une grande surface claire le minimum local reste clair, à portée
        // d'une ombre il s'effondre. L'inverse de l'érosion vaut donc « il y a du
        // sombre alentour ». C'est ce qui distingue un POINT de lumière d'une
        // SURFACE lumineuse — et un vrai objectif ne fabrique un disque que pour
        // une source entourée d'ombre.
        let t2 = rampe(erosion, bas: 0.45, haut: 0.12)

        // T3 — CONTRASTE LOCAL. Chapeau haut-de-forme, et surtout PAS le gradient
        // morphologique (dilatation − érosion) : sur un bord franc, la silhouette
        // du sujet devant la mer sombre, le gradient vaut MAXIMUM — il laisserait
        // passer toute la silhouette et reproduirait exactement les liserés
        // arc-en-ciel de la capture incriminée.
        //
        // Le chapeau a la propriété exacte recherchée : l'ouverture d'un demi-plan
        // par un disque EST ce demi-plan (chapeau ≡ 0 le long d'un bord droit),
        // l'ouverture d'une grande région la conserve (chapeau ≡ 0 à l'intérieur),
        // et l'ouverture SUPPRIME une structure qui ne peut pas contenir le disque
        // d'analyse (chapeau à pleine amplitude sur un point isolé). C'est
        // l'opérateur canonique « petites structures claires sur fond quelconque ».
        // Il est monotone (ouverture ≤ luminance), donc la différence ci-dessus
        // est une soustraction exacte, conforme à R4.
        //
        // ANGLE MORT RÉEL de T3, et il est grave : l'ouverture supprime TOUTE
        // structure claire trop fine pour contenir le disque d'analyse. C'est vrai
        // d'un point isolé, mais AUSSI des lamelles de ciel qui passent entre les
        // mèches de cheveux, entre les doigts, entre le bras et le torse. Sur ces
        // lamelles, les trois premiers termes passent tous : T1 parce qu'un ciel
        // ou une mer en plein soleil sont ÉCRÊTÉS (t1 = 1, et non 0,18 comme on
        // pouvait le croire), T2 parce que l'érosion à 10,8 px trouve les cheveux
        // sombres tout à côté, T3 à pleine amplitude. La graine contenait donc un
        // liseré de points TOUT LE LONG du contour du sujet, que C3 dilatait et
        // que C4 creusait en anneaux : les liserés de la capture incriminée. Le
        // garde-fou de couverture ne rattrapait rien, ces lamelles pesant moins de
        // 0,35 % du cadre. C'est T4 qui ferme ce trou.
        let t3 = rampe(chapeau, bas: 0.20, haut: 0.50)

        // T4 — VOISINAGE SOMBRE À GRANDE ÉCHELLE. C'est la traduction littérale du
        // principe physique : une bulle n'existe que là où tout le pourtour est
        // noir. L'érosion de T2 ne regarde qu'à 10,8 px et se laisse abuser par un
        // creux local ; la MOYENNE locale à grande échelle, elle, ne se laisse pas
        // abuser — entre deux mèches de cheveux elle vaut ≈ 0,6 (ciel + cheveux),
        // alors qu'autour d'un lampadaire dans une rue nocturne elle vaut ≈ 0,10.
        // Rampe DÉCROISSANTE : il faut que tout le quartier soit sombre.
        //
        // C'est ce terme qui sépare proprement les deux scènes de référence :
        // plage en plein jour → ambiance 0,5 à 0,7 → t4 ≈ 0 partout → étage C
        // VIDE, ce qui est le comportement CORRECT ; rue de nuit → ambiance 0,08 à
        // 0,15 → t4 = 1 → disques intacts ; portrait en intérieur → t4 ≈ 0,3 à 0,6
        // selon la pièce, et une ampoule dans le champ reste détectée.
        let ambiance = luminance
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                "inputRadius": Float(max(8, grandCote * 0.05))
            ])
            .cropped(to: cadre)
        let t4 = rampe(ambiance, bas: 0.42, haut: 0.14)

        return t1
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": t2])
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": t3])
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": t4])
    }

    /// Garde-fou de COUVERTURE : la porte qui rend l'étage C auto-régulé.
    ///
    /// Renvoie 1 quand les points détectés couvrent au plus 0,25 % du cadre,
    /// 0 au-delà de 1,2 %, avec une rampe continue entre les deux — pas de
    /// basculement visible en bougeant le curseur.
    ///
    /// C'EST UN GARDE-FOU, PAS LE MÉCANISME PRINCIPAL, et c'est la leçon de la
    /// capture de plage. L'ancien réglage (0,35 % à 1,8 %) laissait un large
    /// régime INTERMÉDIAIRE, et c'est précisément là que tombait la photo : le
    /// scintillement d'une mer au soleil produisait ≈ 0,5 à 1,2 % de couverture,
    /// donc une porte à ≈ 0,7, donc l'étage C appliqué aux deux tiers — les
    /// « anneaux fantômes flottant sur la mer ». Une porte qui mesure une SURFACE
    /// ne mesure ni un NOMBRE ni une ISOLATION : une seule grosse réflexion de
    /// soleil dont T3 ne retient que le pourtour donne une couverture minuscule et
    /// laisse la porte grande ouverte.
    ///
    /// La cause est donc traitée en amont, par T4 : sur une mer éclairée
    /// l'ambiance locale vaut 0,5 à 0,7, t4 ≈ 0, et la couverture mesurée tombe
    /// d'elle-même à presque rien. La porte n'a plus qu'à rattraper les cas
    /// résiduels, d'où une rampe COURTE : ouverte à fond sous 0,25 %, franchement
    /// fermée à 1,2 %. Avec le gain 32 en aval, la valeur de panne (0,031) reste
    /// très au-dessus du seuil de fermeture, donc R5 est préservé.
    private static func porteDeCouverture(_ points: CIImage, cadre: CGRect) -> CGFloat {
        let moyenne = points.applyingFilter("CIAreaAverage", parameters: [
            "inputExtent": CIVector(x: cadre.origin.x,
                                    y: cadre.origin.y,
                                    z: cadre.width,
                                    w: cadre.height)
        ])

        // Le gain 32 APRÈS la moyenne est indispensable : sans lui, un rendu
        // 8 bits ne donnerait que 5 niveaux utiles entre 0 % et 2 % de
        // couverture. Avec, la résolution atteint 1,2·10⁻⁴, et tout ce qui
        // dépasse 3,1 % sature — ce qui n'a aucune importance puisque c'est déjà
        // « éteint ».
        let amplifie = attenuer(moyenne, facteur: 32)

        // Buffer initialisé à 255 et non à 0 : si le rendu GPU échoue en silence,
        // la couverture lue vaut 0,031 — au-dessus du seuil de fermeture — et
        // l'étage C est désactivé. C'est le SENS DE LA PANNE imposé par R5 : le
        // mode de défaillance acceptable est « pas de disques », jamais
        // « disques faux ». Un buffer à zéro ouvrirait la porte en grand.
        var pixel: [UInt8] = [255, 255, 255, 255]

        if Task.isCancelled { return 0 }

        pixel.withUnsafeMutableBytes { tampon in
            guard let adresse = tampon.baseAddress else { return }
            contexteImages.render(amplifie,
                                  toBitmap: adresse,
                                  rowBytes: 4,
                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  format: CIFormat.RGBA8,
                                  colorSpace: nil)
        }

        let couverture = CGFloat(pixel[0]) / 255 / 32
        return min(max((0.012 - couverture) / (0.012 - 0.0025), 0), 1)
    }

    // MARK: - Étage C : le calque des disques

    /// Construit le calque lumineux à screener sur l'image.
    ///
    /// Toutes les étapes ci-dessous ne sont dangereuses que si on les nourrit de
    /// faux. Elles sont ici alimentées par la carte stricte de `detecterPoints`,
    /// et de surcroît chacune est structurellement confinée : les différences ne
    /// portent que sur des dilatations emboîtées floutées à la même largeur (R4),
    /// et la frange est un flou différentiel par canal, sans le moindre
    /// déplacement géométrique.
    private static func calqueOptique(base: CIImage,
                                      points: CIImage,
                                      lens: Lens,
                                      k: CGFloat,
                                      cadre: CGRect,
                                      grandCote: CGFloat,
                                      petitCote: CGFloat,
                                      centre: CIVector) -> CIImage {

        let p = lens.bokeh

        // Rayon du cercle de confusion. Relatif, bornes relatives (R3) : l'aperçu
        // 1200 px et l'export 3200 px restent la MÊME image à l'échelle près,
        // même quand la borne mord.
        let rayonRelatif = min(max(0.018 * CGFloat(p.size) * (0.35 + 0.65 * k), 0.0035), 0.055)
        let rayonDisque = grandCote * rayonRelatif
        // Largeur de la transition du bord : `soft` va de 0,10 (bord franc du
        // Summicron) à 0,72 (halo évanescent du Dream Lens).
        let largeurBord = max(1, rayonDisque * (0.10 + 0.55 * CGFloat(p.soft)))

        // C2. GRAINE : l'image nue, masquée par les points détectés, relevée puis
        // teintée de la couleur de bokeh de l'objectif. La teinte est appliquée
        // ICI, à la graine des disques, et non à une carte de luminance :
        // c'est la couleur des BULLES du catalogue, pas la dérive du verre (qui
        // relève de l'étage A).
        let teinte = CouleurHex.composantes(lens.palette.first ?? lens.accent)
        let dose = 0.55 * k
        let graine = base
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": points])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.6 * melange(1, teinte.0, dose), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.6 * melange(1, teinte.1, dose), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.6 * melange(1, teinte.2, dose), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

        // C3. DISQUES. La dilatation morphologique étale chaque point lumineux en
        // un disque de rayon constant — c'est littéralement le cercle de
        // confusion. Le flou de disque adoucit ensuite son bord.
        let etale = dilater(graine, rayon: rayonDisque, cadre: cadre)

        // Version PLATE, sans frange : c'est elle qui sert d'opérande extérieure
        // aux différences ci-dessous, pour que les deux opérandes soient floutées
        // à la même largeur, condition non négociable de R4.
        let disquePlat = flouDisque(etale, rayon: largeurBord, cadre: cadre)

        // C3bis. FRANGE CHROMATIQUE — aberration chromatique LONGITUDINALE, donc
        // un cercle de confusion différent par longueur d'onde. Réalisée par trois
        // largeurs de flou sur la MÊME dilatation, chaque canal isolé par une
        // `CIColorMatrix` puis réuni par `CIMaximumCompositing` (les trois
        // occupent des canaux disjoints : le maximum est une union exacte, et
        // l'alpha reste à 1).
        //
        // L'ancienne frange homothétait le calque autour du centre du cadre, donc
        // déplaçait chaque pixel proportionnellement à sa distance au centre : sur
        // une couche non vide, c'était un fantôme chromatique de toute l'image —
        // les liserés arc-en-ciel de la silhouette et les traînées sur le sable.
        // Même sur une couche correcte, elle aurait produit des disques
        // DÉDOUBLÉS en périphérie plutôt qu'une frange. Ici, rien ne se déplace :
        // magenta au dehors du bord, cyan au dedans, rigoureusement local.
        var couche = disquePlat
        let frange = CGFloat(p.fringe) * k
        if frange > 0.004 {
            let ecart = min(0.9, 1.7 * frange)
            let rouge = canal(flouDisque(etale, rayon: largeurBord * (1 + ecart), cadre: cadre),
                              rouge: 1, vert: 0, bleu: 0)
            let vert = canal(disquePlat, rouge: 0, vert: 1, bleu: 0)
            let bleu = canal(flouDisque(etale, rayon: max(0.5, largeurBord * (1 - ecart)), cadre: cadre),
                             rouge: 0, vert: 0, bleu: 1)
            couche = rouge
                .applyingFilter("CIMaximumCompositing", parameters: ["inputBackgroundImage": vert])
                .applyingFilter("CIMaximumCompositing", parameters: ["inputBackgroundImage": bleu])
        }

        // C4. ANNEAU (bulles de savon). L'aberration sphérique non corrigée d'un
        // triplet vide le centre du disque.
        //
        // L'ancienne construction floutait ses deux opérandes à des largeurs
        // DIFFÉRENTES (rayon·(0,10 + 0,55·soft) d'un côté, rayon·0,22 de l'autre).
        // Deux versions d'un même bord floutées différemment diffèrent LE LONG DE
        // CE BORD : d'où une bande de contour sur toute silhouette assez large.
        // C'était le mécanisme exact de l'artefact. Ici, dilatation emboîtée à
        // 0,60·R et MÊME largeur de flou : la différence vaut 0 sur tout plateau
        // et ne peut produire qu'une couronne autour d'un point. Double verrou —
        // la graine ne contient que des points, ET l'opérateur est structurellement
        // incapable de produire une bande.
        if p.ring > 0.01 {
            let interieur = flouDisque(dilater(graine, rayon: rayonDisque * 0.60, cadre: cadre),
                                       rayon: largeurBord, cadre: cadre)
            let anneau = disquePlat.applyingFilter("CIDifferenceBlendMode", parameters: [
                "inputBackgroundImage": interieur
            ])
            couche = mixerParMaximum(couche, poids: 1 - CGFloat(p.ring),
                                     avec: anneau, poids: CGFloat(p.ring),
                                     cadre: cadre)
        }

        // C5. LISERÉ. L'aberration sphérique sous-corrigée concentre les rayons
        // marginaux sur le pourtour. Troisième dilatation emboîtée, à 0,88·R : un
        // anneau fin de largeur 0,12·R, structurellement confiné comme le
        // précédent. L'ancienne construction — calque moins son propre flou — était
        // un masque flou, c'est-à-dire un générateur de halo de bord par définition.
        if p.rim > 0.02 {
            let interieur = flouDisque(dilater(graine, rayon: rayonDisque * 0.88, cadre: cadre),
                                       rayon: largeurBord, cadre: cadre)
            let lisere = disquePlat.applyingFilter("CIDifferenceBlendMode", parameters: [
                "inputBackgroundImage": interieur
            ])
            couche = ecran(couche, avec: attenuer(lisere, facteur: CGFloat(p.rim) * k))
        }

        // C6. AIGRETTES de diffraction, dessinées par les lamelles du diaphragme.
        // Un `CIMotionBlur` sur une carte LARGE est un générateur de traînées —
        // c'est ce qui striait le sable. Nourri par la carte stricte, il redevient
        // une croix sur des points. Ne concerne qu'un objectif du catalogue : seul
        // le Noct-Nikkor porte `spike` au-dessus de 0,02.
        if p.spike > 0.02 {
            let longueur = Float(rayonDisque * 2.4)
            let horizontale = points
                .clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [
                    "inputRadius": longueur, "inputAngle": Float(0)
                ])
                .cropped(to: cadre)
            let verticale = points
                .clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [
                    "inputRadius": longueur, "inputAngle": Float.pi / 2
                ])
                .cropped(to: cadre)
            let croix = ecran(horizontale, avec: verticale)
            couche = ecran(couche, avec: attenuer(croix, facteur: CGFloat(p.spike) * k * 0.65))
        }

        // C7. ŒIL DE CHAT. Le vignettage mécanique du barillet tronque les disques
        // périphériques. Appliqué au calque SEUL, et à amplitude réduite (0,55 au
        // lieu de 0,9) parce que le vignettage global de l'étage A atténue déjà les
        // disques des bords.
        if p.cat > 0.02 {
            couche = couche.applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": centre,
                "inputRadius": Float(petitCote * 0.62),
                "inputIntensity": Float(CGFloat(p.cat) * k * 0.55),
                "inputFalloff": Float(0.5)
            ])
        }

        return couche.cropped(to: cadre)
    }

    // MARK: - Briques

    /// Rampe linéaire suivie d'un écrêtage : ramène une image dans [0, 1] entre
    /// `bas` et `haut`. Si `haut < bas`, la rampe est DÉCROISSANTE — c'est ainsi
    /// qu'on exprime « il faut que ce soit sombre ».
    ///
    /// Une rampe plutôt qu'un seuil net : une frontière franche se lirait
    /// elle-même comme un contour dans l'image. La ligne alpha reste (0, 0, 0, 1)
    /// et le `w` du biais à 0, conformément à R1.
    private static func rampe(_ image: CIImage, bas: CGFloat, haut: CGFloat) -> CIImage {
        let ecart = haut - bas
        guard abs(ecart) > 0.0001 else { return image }
        let pente = 1 / ecart
        let biais = -bas * pente
        return image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: pente, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: pente, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: pente, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: biais, y: biais, z: biais, w: 0)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
    }

    /// Masque radial : noir ET transparent au centre, blanc ET opaque au-delà.
    ///
    /// La rampe est portée simultanément par la LUMINANCE et par l'ALPHA parce
    /// que la documentation de `CIBlendWithMask` est ambiguë selon les versions
    /// sur le canal réellement utilisé. En faisant coïncider les deux, le masque
    /// est correct quelle que soit la convention — voie conservatrice assumée.
    ///
    /// `CIRadialGradient` produit une image d'étendue INFINIE : le recadrage
    /// n'est pas cosmétique, il est obligatoire.
    private static func masqueRadial(cadre: CGRect, rayon0: CGFloat, rayon1: CGFloat) -> CIImage? {
        guard let filtre = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: cadre.midX, y: cadre.midY),
            "inputRadius0": Float(rayon0),
            "inputRadius1": Float(max(rayon1, rayon0 + 1)),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]), let sortie = filtre.outputImage else {
            // R5 : pas de masque → l'appelant renonce à l'étape plutôt que de
            // l'appliquer sans confinement.
            return nil
        }
        return sortie.cropped(to: cadre)
    }

    /// Dilatation morphologique, clampée puis recadrée (R2).
    private static func dilater(_ image: CIImage, rayon: CGFloat, cadre: CGRect) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": Float(max(1, rayon))])
            .cropped(to: cadre)
    }

    /// Flou de disque, clampé puis recadré (R2).
    private static func flouDisque(_ image: CIImage, rayon: CGFloat, cadre: CGRect) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIDiscBlur", parameters: ["inputRadius": Float(max(0.5, rayon))])
            .cropped(to: cadre)
    }

    /// Superposition en écran. Le seul mode de mélange autorisé pour poser un
    /// calque lumineux sur l'image : il n'assombrit jamais et laisse l'alpha des
    /// deux calques à 1 (1 + 1 − 1·1 = 1).
    private static func ecran(_ fond: CIImage, avec calque: CIImage) -> CIImage {
        calque.applyingFilter("CIScreenBlendMode", parameters: [
            "inputBackgroundImage": fond
        ])
    }

    /// Atténue (ou amplifie) un calque SANS toucher à son alpha.
    private static func attenuer(_ image: CIImage, facteur: CGFloat) -> CIImage {
        let f = min(max(facteur, 0), 64)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    /// Fondu entre deux calques lumineux par maximum pondéré.
    ///
    /// Un vrai fondu linéaire demanderait une addition, donc un alpha à 2. Le
    /// maximum donne le même résultat aux deux extrémités (poids 0 ou 1) et,
    /// entre les deux, une transition parfaitement acceptable sur des calques qui
    /// ne contiennent que de la lumière.
    private static func mixerParMaximum(_ a: CIImage, poids poidsA: CGFloat,
                                        avec b: CIImage, poids poidsB: CGFloat,
                                        cadre: CGRect) -> CIImage {
        attenuer(b, facteur: poidsB)
            .applyingFilter("CIMaximumCompositing", parameters: [
                "inputBackgroundImage": attenuer(a, facteur: poidsA)
            ])
            .cropped(to: cadre)
    }

    /// Isole un canal, alpha inchangé. Sert à la frange chromatique.
    private static func canal(_ image: CIImage, rouge: CGFloat, vert: CGFloat, bleu: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rouge, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: vert, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: bleu, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    private static func melange(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}
