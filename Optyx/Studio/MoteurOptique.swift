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

    /// Grille de référence du GRAIN, en pixels du grand côté.
    ///
    /// `CIRandomGenerator` tire une valeur indépendante par pixel de la grille de
    /// TRAVAIL : sans agrandissement, la cellule de bruit mesure 1 px que le cadre
    /// fasse 900 ou 3200. C'était la seule longueur du moteur exprimée en pixels
    /// absolus, en violation directe de R3, et donc le seul effet dont le viseur
    /// et le fichier n'étaient pas la même image à l'échelle près. Le bruit est
    /// désormais tiré sur cette grille fixe puis agrandi au cadre, si bien que la
    /// cellule vaut toujours 1/900 du grand côté.
    ///
    /// La valeur coïncide avec `ControleurCamera.coteViseur` — non par hasard :
    /// c'est au viseur que l'auteur règle le grain, et un facteur d'agrandissement
    /// exactement égal à 1 y garantit qu'aucun rééchantillonnage ne s'interpose.
    /// La constante est recopiée plutôt qu'importée pour que le moteur ne dépende
    /// pas du contrôleur de caméra ; si l'une bouge, l'autre doit suivre.
    static let coteGrain: CGFloat = 900

    /// Grille de référence de la DÉTECTION DE POINTS, en pixels du grand côté.
    ///
    /// Même principe que `coteGrain`, et même panne à la racine : `detecterPoints`
    /// seuille une LUMINANCE ABSOLUE (T1, rampe 0,88 → 0,99). Or la crête d'une
    /// source ponctuelle ne survit au sous-échantillonnage qu'à proportion de la
    /// réduction subie. Détecter sur le tampon de travail faisait donc de la
    /// détection une propriété de la TAILLE DU TAMPON, pas de la scène.
    ///
    /// Mesuré sur une source carrée de S pixels capteur (grand côté 4032), phase
    /// sous-pixel balayée sur une période complète, seuil S50 = valeur de S où le
    /// t1 moyen atteint 0,5 :
    ///
    ///     détection sur le tampon de travail   viseur 4,05  aperçu 4,48  export 2,05
    ///     détection normalisée à 900           viseur 6,32  aperçu 7,30  export 6,41
    ///
    /// soit un rapport max/min qui tombe de 2,19 à 1,16, et des bandes
    /// d'indécision qui se superposent au lieu d'être disjointes : 5,0-9,8 px au
    /// viseur, 5,2-10,6 à l'aperçu, 5,2-10,1 à l'export, contre 1,7-6,4 / 3,8-7,5 /
    /// 1,5-3,2 auparavant. Concrètement, une guirlande de 5 mm entre 2,6 m et 8,1 m
    /// produisait des disques dans le FICHIER et rien au viseur.
    ///
    /// La valeur coïncide avec `ControleurCamera.coteViseur` et avec `coteGrain`,
    /// pour la même raison qu'eux : c'est au viseur que l'auteur règle le rendu, et
    /// un facteur de réduction exactement égal à 1 y garantit qu'aucun
    /// rééchantillonnage ne s'interpose. La constante est recopiée plutôt
    /// qu'importée pour que le moteur ne dépende pas du contrôleur de caméra ; si
    /// l'une bouge, les autres doivent suivre.
    ///
    /// Cette normalisation forme une PAIRE avec le rééchantillonnage Lanczos du
    /// viseur (`ControleurCamera.captureOutput`) : appliquée seule elle ramène le
    /// rapport à 1,80 seulement, et le Lanczos appliqué seul le porte à 3,09,
    /// c'est-à-dire PIRE que l'état d'origine. Ne pas défaire l'une sans l'autre.
    static let coteDetection: CGFloat = 900

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

        // RÉFÉRENCE DES VIGNETTAGES (A3 et C7). `CIVignetteEffect` est un filtre
        // CIRCULAIRE : son rayon ancré sur le petit côté garde bien la même
        // amplitude au bord et au coin quel que soit le format — vérifié, t vaut
        // 0,806 au milieu du petit côté et 1,000 au coin pour TOUS les rapports —
        // mais la SURFACE saturée, elle, explose avec l'allongement. Grand côté
        // fixé à 1200, part du cadre au vignettage MAXIMAL (d ≥ 0,62·petitCôté) :
        //   1,00 → 3,2 %   1,333 → 18,4 %   1,50 → 27,5 %   2,17 → 49,9 %
        //   3,00 → 63,7 %  5,00 → 78,2 %    8,00 → 86,4 %
        // Le viseur (4:3) n'est pas concerné, mais le studio accepte n'importe
        // quelle image du sélecteur, donc un panoramique iPhone : les trois quarts
        // d'un tel cadre étaient assombris au maximum — l'image détruite, pas
        // stylisée. C'est le mécanisme du bug de format, transposé à l'import.
        //
        // La borne est choisie neutre sur les cadres réellement produits par
        // l'appareil : 0,60·diagonale d'un 4:3 vaut exactement 0,60·(5/3) =
        // 1,000·petitCôté, et 0,849·petitCôté sur un carré, donc `max` retient le
        // petit côté et rien ne bouge. Sur le cadre du viseur, 674×900 — rapport
        // 1,3353 et non 4/3 pile, à cause de l'arrondi aux dimensions paires — le
        // rapport vaut 1,0009 : le vignettage change de 0,09 %, soit rien. La borne
        // ne se relâche que sur les formats allongés, où elle plafonne la surface
        // saturée :
        //   1,00 → 3,2 %  1,333 → 18,4 %  1,50 → 19,7 %  2,17 → 22,6 %
        //   3,00 → 24,0 % 5,00 → 25,0 %   8,00 → 25,4 %
        let refVignettage = max(petitCote, 0.60 * hypot(cadre.width, cadre.height))
        let sig = SignatureTonale.pour(lens)

        // ─────────────────────────────────────────────────────────────────────
        // A1. MATRICE DE CANAUX — gain (hautes lumières) + biais (ombres), puis
        // saturation et contraste. Voir SignatureTonale.swift pour la mécanique
        // et la justification ligne à ligne des neuf verres.
        // ─────────────────────────────────────────────────────────────────────
        let gR = 1 + (sig.gainR - 1) * k
        let gV = 1 + (sig.gainV - 1) * k
        let gB = 1 + (sig.gainB - 1) * k

        var teintee = base
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
        // A1 bis. MICRO-CONTRASTE — la signature des verres PRÉCIS.
        //
        // C'est le seul étage qui AFFIRME au lieu de dégrader, et son absence
        // laissait le Summicron et le Noct-Nikkor sans aucune signature propre :
        // un moteur qui ne sait qu'ajouter des défauts n'a rien à donner à deux
        // verres dont toute la réputation tient au piqué. Leur rendu était
        // l'image nue, teintée et vignettée — d'où « certains objectifs ne font
        // rien ».
        //
        // Placé AVANT la défocalisation : la zone nette en profite, et
        // l'arrière-plan, flouté juste après, n'en garde rien. Accentuer ce
        // qu'on s'apprête à effacer serait du calcul perdu.
        //
        // `CISharpenLuminance` et non `CIUnsharpMask` : le premier ne touche que
        // la luminance, le second accentue aussi la chrominance et fabrique des
        // franges colorées sur les bords francs — exactement la famille
        // d'artefacts que ce moteur a mis plusieurs itérations à éliminer.
        //
        // Le rayon suit le cadre (R3) : à 0,004 du grand côté il vaut 3,6 px au
        // viseur et 12,8 px à l'export, donc la même accentuation RELATIVE dans
        // les deux — un rayon en pixels absolus donnerait un fichier exporté
        // visiblement moins net que le viseur qui l'a promis.
        if sig.microContraste > 0.01 {
            teintee = teintee
                .clampedToExtent()
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": Float(sig.microContraste * k * 1.4),
                    "inputRadius": Float(max(1.2, grandCote * 0.004))
                ])
                .cropped(to: cadre)
        }

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
        // LE RÉGLAGE PRÉCÉDENT (masqueRadial, r0 = 0,40·petitCote, r1 =
        // 0,58·petitCote, angle 0,45 rad) ÉTAIT ENCORE FAUX, et de deux façons
        // indépendantes. Les nombres, refaits sur le cadre réel du viseur 674×900 :
        //
        //   • r1 = 0,58·petitCote est SUPÉRIEUR à 0,50·petitCote, la distance du
        //     centre au milieu du bord vertical. Le masque y vaut 0,556 — jamais 1.
        //     Il ne sature donc sur AUCUN point de la bande centrale, exactement le
        //     défaut structurel de B3 avant correction. Surface encore en
        //     fondu-croisé strict (0 < m < 1) : 36,7 % du cadre au viseur, 32,6 %
        //     en 3:2, 36,7 % à l'export — invariant, donc présent partout.
        //   • Le commentaire justifiait ce résidu en affirmant que le déplacement
        //     « reste sous ~60 px, du même ordre que le flou de B1, qui l'absorbe ».
        //     Mesuré, avec le profil documenté θ(r) = angle·(1 − r/R) : le
        //     déplacement 2r·sin(θ/2) est maximal en r = R/2 et vaut 75,8 px pour
        //     l'Helios à k = 1, contre un flou B1 de 7,92 px. Pas « du même ordre » :
        //     9,57 fois plus. Biotar : 51,6 px contre 8,64 px, soit 5,97×. À
        //     l'export les deux nombres sont multipliés par 3,56 et le RATIO est
        //     identique — l'invariance d'échelle était respectée, c'était
        //     l'amplitude qui était fausse. Un fondu-croisé entre deux images
        //     séparées de 9,6 largeurs de flou EST le régime de dédoublement.
        //
        // DEUX CORRECTIONS, les deux nécessaires.
        //
        // (1) MASQUE NORMALISÉ AU CADRE, comme en B3 : u = 1 est l'ellipse
        //     inscrite, le coin est à u = √2, pour TOUT format. Avec fin = 0,95 < 1
        //     le masque sature sur tout le pourtour, y compris au milieu des bords
        //     du petit côté. Statistiques rigoureusement indépendantes du rapport
        //     d'image — vérifiées identiques à 1,00 / 1,335 / 1,50 / 2,17 / 5,00 :
        //         m moyen 0,461 · tourbillon PLEIN 29,1 % · fondu-croisé 32,3 %
        //         · image intacte 38,5 %
        //     Le début à 0,70 (contre 0,52 en B3) garde la protection DOUBLE du
        //     centre : la zone intacte du tourbillon contient largement l'ellipse
        //     nette de B3.
        //
        // (2) ANGLE CALCULÉ, plus jamais posé en dur. `CIVortexDistortion` tourne
        //     le plus AU CENTRE et décroît vers `inputRadius` (profil documenté,
        //     l'inverse du tourbillon optique réel — d'où le masque qui ne garde
        //     que la couronne). Avec θ(r) = angle·(1 − r/R) et R = 0,75·grandCôté,
        //     le déplacement r·θ(r) est maximal en r = R/2 et y vaut
        //     angle·R/4 = angle·0,1875·grandCôté. On impose que ce maximum reste
        //     sous DEUX largeurs de flou B1 — la condition pour que B1 l'absorbe
        //     réellement — d'où angle = swirl·k·2·rayonFlouRelatif/0,1875.
        //     À k = 1, au viseur (grandCôté 900) : Helios 0,0939 rad, déplacement
        //     15,8 px contre 7,92 px de flou (ratio 2,00 au lieu de 9,57) ; Biotar
        //     0,0696 rad, 11,7 px contre 8,64 px ; Dream 0,0451 rad, 7,6 px contre
        //     17,3 px ; Takumar 0,0064 rad, 1,1 px. À l'export tout est multiplié
        //     par 3,56 et les ratios sont inchangés. Un tourbillon se lit au
        //     mouvement du fond, pas à l'amplitude de la rotation.
        // ─────────────────────────────────────────────────────────────────────
        //
        // (3) LA CONTRAINTE « DEUX LARGEURS DE FLOU » ÉTAIT TROP PRUDENTE, et
        //     elle rendait le tourbillon invisible — 15,8 px de déplacement au
        //     viseur pour l'Helios, dont c'est pourtant LA signature, celle qui
        //     lui vaut sa réputation et qui figure en toutes lettres sur sa
        //     fiche (« L'arrière-plan tournoie. Littéralement. »).
        //
        //     Elle visait à empêcher le dédoublement des contours. Or ce risque
        //     n'existe pas ici : la torsion s'applique à `flou`, la copie DÉJÀ
        //     défocalisée, et se remélange sur `flou` lui-même. Les deux côtés
        //     du fondu sont donc flous — un fondu entre deux images floues ne
        //     peut produire aucun contour net, quelle que soit l'amplitude. Le
        //     dédoublement d'origine venait d'un tout autre montage : le
        //     tourbillon était alors superposé à l'image NETTE.
        //
        //     Le déplacement maximal est donc porté à 5,5 % du grand côté, soit
        //     49,5 px au viseur et 176 px à l'export pour l'Helios. C'est un
        //     mouvement franc du fond, qui se lit immédiatement.
        let angleTourbillon = CGFloat(p.swirl) * k * (0.055 / 0.1875)

        if p.swirl > 0.02,
           let masqueTourbillon = masqueCadre(cadre: cadre, debut: 0.70, fin: 0.95) {
            let tordu = flou
                .clampedToExtent()
                .applyingFilter("CIVortexDistortion", parameters: [
                    "inputCenter": centre,
                    "inputRadius": Float(grandCote * 0.75),
                    "inputAngle": Float(angleTourbillon)
                ])
                .cropped(to: cadre)

            flou = tordu.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": flou,
                "inputMaskImage": masqueTourbillon
            ])
        }

        // ─────────────────────────────────────────────────────────────────────
        // B3. MASQUE DE DÉFOCALISATION — le centre du cadre reste net.
        //
        // HISTORIQUE, avec les nombres REFAITS. Deux ancrages successifs ont été
        // essayés, et les deux ont produit un masque qui ne SATURE jamais sur la
        // bande centrale du cadre. Or `CIBlendWithMask` est un FONDU LINÉAIRE
        // entre l'image nette et l'image floue, pas un flou à rayon variable : à
        // m = 0,39 il reste 61 % du détail net à TOUTES les fréquences. Un flou
        // dosé à 39 % ne se lit pas comme un flou, il se lit comme rien.
        //
        //   • Ancrage DIAGONALE (r0 = 0,26·diag, r1 = 0,46·diag). Sur le cadre
        //     réel du viseur, 674×900, il donnait m = 0,20 au bord vertical,
        //     m moyen = 0,238, et 44,3 % du cadre PARFAITEMENT net. Le commentaire
        //     précédent affirmait « masque ZÉRO sur toute la largeur » : c'est
        //     faux sur ce cadre — le zéro ne s'obtient qu'à partir d'un rapport
        //     d'image ≥ 1,643, qu'AUCUN preset AVFoundation ne produit.
        //   • Ancrage PETIT CÔTÉ (r0 = 0,34, r1 = 0,75). Indépendant du format,
        //     ce qui est le bon principe, mais r1 = 0,75·petitCôté est SUPÉRIEUR
        //     à 0,50·petitCôté, la distance du centre au bord du petit côté :
        //     aucun pixel de la bande centrale ne pouvait dépasser m = 0,390,
        //     dans aucun des trois cadres. m moyen = 0,341, et 2,4 % du cadre
        //     seulement au flou PLEIN — les quatre coins.
        //
        // LE CADRE RÉEL DU VISEUR, puisque les deux réglages précédents ont été
        // dimensionnés sur un cadre imaginaire : `ControleurCamera` pose
        // `session.sessionPreset = .photo`, donc un tampon 4:3 (4032×3024) que
        // `.oriented()` met en portrait 3024×4032, réduit par
        // min(1, 900/4032) = 0,2232 puis arrondi à des dimensions paires :
        // 674×900, rapport 1,335. Le 1206×2622 invoqué auparavant est l'ÉCRAN, et
        // `VueApercu.ajuster()` fait un aspect-fit : le 4:3 est letterboxé, jamais
        // recadré au format de l'écran. Aucun cadre de rapport 2,17 n'existe dans
        // cette app.
        //
        // RÉGLAGE ACTUEL — masque NORMALISÉ AU CADRE. Le rayon n'est plus une
        // longueur mais une fraction du DEMI-CÔTÉ correspondant : u = 1 est
        // l'ellipse inscrite, qui touche le milieu des quatre bords quel que soit
        // le format ; le coin est à u = √2 pour tout format. Les statistiques du
        // masque deviennent donc RIGOUREUSEMENT indépendantes du rapport d'image —
        // vérifié à 1,00 / 1,333 / 1,50 / 2,17 / 5,00, valeurs identiques au
        // millième :
        //     début 0,52 → fin 0,95   m moyen = 0,564
        //     aire au flou PLEIN 29,2 %   aire m ≥ 0,50 : 57,6 %   aire nette 21,3 %
        // Contre 2,4 % / 32,1 % / 27,3 % pour le réglage précédent. C'est le seul
        // changement qui fasse réellement exister le flou d'arrière-plan sur la
        // bande centrale, là où se trouve le fond derrière la tête du sujet.
        //
        // Dans le viseur 674×900, l'ellipse nette a pour demi-axes 175×234 px : un
        // visage centré y tient entièrement. Le flou est PLEIN au-delà de 320 px
        // sur l'horizontale (bord à 337) et de 427 px sur la verticale (bord à
        // 450), c'est-à-dire sur tout le pourtour du cadre.
        //
        // LIMITE ASSUMÉE : sans carte de profondeur, un sujet décentré verra une
        // partie de son corps floutée. La transition reste large pour que cette
        // erreur soit douce plutôt que franche. C'est le compromis explicite : un
        // flou légèrement faux est infiniment moins choquant qu'un anneau inventé
        // au bon endroit.
        // ─────────────────────────────────────────────────────────────────────
        var fond = teintee
        if let masqueFlou = masqueCadre(cadre: cadre, debut: 0.52, fin: 0.95) {
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
        // DEUX ÉCHELLES DE FLOU, et c'est la correction d'une panne mesurée. Un
        // flou gaussien unique de rayon 0,035·grandCôté (31,5 px au viseur)
        // DÉTRUIT le pic de la carte pour toute source PONCTUELLE : une tache
        // spéculaire de 5 px ne laisse qu'un pic de 0,013 à 0,107 selon la
        // convention de sigma, de 0,002 à 0,018 pour 2 px. Le « glow autour des
        // hautes lumières » n'existait donc que devant une zone brûlée LARGE
        // (≥ 80 px sur 900, soit ≥ 9 % du grand côté) — jamais autour d'un point
        // de lumière, qui est pourtant le cas décrit par la fiche de chaque verre.
        // Un second flou SERRÉ (0,006·grandCôté = 5,4 px au viseur) survit sur une
        // spéculaire : pic de 0,35 à 0,98 pour 5 px, de 0,07 à 0,46 pour 2 px. Les
        // deux sont réunis par `CIMaximumCompositing` — une union, donc bornée à 1
        // et conforme à R1, jamais une addition.
        //
        // FACTEUR D'ÉCRAN. Le coefficient 1,6 donnait 0,064 pour un `haze` de 0,04
        // (Helios, Trioplan), c'est-à-dire un delta MAXIMAL de 3,20 % sur un fond
        // à 0,50 et de 0,64 % sur une haute lumière à 0,90 : sous le seuil de
        // perception. Coefficient 3,0, plafond inchangé à 0,50 — le plafond ne
        // mord que sur le Dream Lens, l'ordre des neuf verres est donc préservé :
        //   helios 0,120 · trioplan 0,120 · biotar 0,240 · angénieux 0,300 ·
        //   noctilux 0,420 · takumar 0,480 · dream 0,500 (écrêté de 0,900)
        // Delta d'écran = facteur · carte · (1 − fond). Autour d'une spéculaire de
        // 5 px sur un fond à 0,50, Helios passe de 0,04-0,35 % à 2,1-5,9 %.
        //
        // DIVERGENCE CONNUE, à trancher dans Lens.swift et NON ici : `haze` vaut 0
        // chez le Summicron et le Noct-Nikkor, mais leur fiche affiche un trait
        // « Halo / glow » de 0,15 et de 0,55. Ce n'est donc pas « une absence de
        // voile revendiquée » comme l'affirmait ce commentaire — c'est le moteur
        // qui rend zéro là où la carte promet 0,55. Le classement des sept autres
        // diverge aussi du trait affiché (Trioplan : trait 0,45 pour haze 0,04 ;
        // Takumar : trait 0,35 pour haze 0,16).
        // ─────────────────────────────────────────────────────────────────────
        if p.haze > 0.01 {
            let hautesDouces = rampe(
                base.applyingFilter("CIColorControls", parameters: [
                    "inputBrightness": Float(-0.72),
                    "inputSaturation": Float(1),
                    "inputContrast": Float(1)
                ]),
                bas: 0, haut: 0.28)

            let voileLarge = hautesDouces
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    "inputRadius": Float(grandCote * 0.035)
                ])
                .cropped(to: cadre)

            let voileSerre = hautesDouces
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    "inputRadius": Float(grandCote * 0.006)
                ])
                .cropped(to: cadre)

            let voile = voileLarge.applyingFilter("CIMaximumCompositing", parameters: [
                "inputBackgroundImage": voileSerre
            ])

            fond = ecran(fond, avec: attenuer(voile,
                                              facteur: min(0.5, CGFloat(p.haze) * k * 3.0)))
        }

        // ─────────────────────────────────────────────────────────────────────
        // C. DISQUES DE BOKEH — conditionnels.
        // ─────────────────────────────────────────────────────────────────────
        var image = fond

        if disquesAutorises {
            let pointsDetectes = detecterPoints(base, cadre: cadre, grandCote: grandCote)
            // La porte mesure la couverture APRÈS dilatation : elle a donc besoin du
            // rayon du disque, qui est une propriété de l'objectif et de l'intensité.
            let porte = porteDeCouverture(pointsDetectes,
                                          rayonDisque: grandCote * rayonDisqueRelatif(p, k: k),
                                          cadre: cadre)

            if porte >= 0.02 {
                image = ecran(fond, avec: attenuer(
                    calqueOptique(base: base,
                                  points: pointsDetectes,
                                  lens: lens,
                                  k: k,
                                  cadre: cadre,
                                  grandCote: grandCote,
                                  refVignettage: refVignettage,
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
                "inputRadius": Float(refVignettage * 0.62),
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
            // 0,24 donne un voile dans [0,38 ; 0,62]. Écart-type du RÉSULTAT après
            // `CISoftLightBlendMode` (Monte-Carlo, 600 000 tirages) : 1,65 % sur un
            // fond à 0,20 · 1,83 % à 0,50 (4,7 niveaux sur 255) · 1,03 % à 0,80.
            // C'est l'ordre de grandeur d'un tirage argentique — une modulation de
            // quelques pour cent, pas un calque opaque. Le réglage précédent, 0,14,
            // donnait 0,96 / 1,07 / 0,60 % : lisible, mais tout juste au-dessus du
            // bruit de quantification une fois le fichier réduit à l'écran.
            let oscillation = CGFloat(p.grain) * k * 0.24
            // Un tiers par canal, puisque les trois sont sommés : c'est ce
            // facteur 3 qui manquait.
            let parCanal = oscillation / 3
            let socle = (1 - oscillation) / 2
            // ÉCHELLE DU GRAIN (R3), et c'est la seconde panne de cet étage.
            // `CIRandomGenerator` tire une valeur par pixel de la grille de
            // travail : la cellule de grain mesurait 1 px dans les TROIS cadres,
            // soit 0,1111 % du grand côté au viseur, 0,0833 % à l'aperçu et
            // 0,0312 % à l'export. Le grain de l'Angénieux était donc 3,56 fois
            // plus fin dans le fichier que dans le viseur où l'auteur le règle ;
            // pire, en ramenant l'export à la taille d'affichage le bruit blanc se
            // moyennait sur 3,56² = 12,7 px et son écart-type était divisé par
            // 3,56 : 1,07 % → 0,30 %, soit 0,77 niveau sur 255, sous le bruit de
            // quantification. « Du grain au viseur, aucun dans la photo ».
            //
            // Le bruit est donc tiré sur la grille fixe `coteGrain` puis agrandi
            // au cadre : la cellule vaut 1,000 px au viseur, 1,333 px à l'aperçu et
            // 3,556 px à l'export — 0,1111 % du grand côté dans les trois cas.
            // `samplingNearest()` avant l'agrandissement est obligatoire : une
            // interpolation bilinéaire corrélerait les voisins et diviserait
            // l'écart-type par ≈ 1,5 à l'export sans le toucher au viseur, ce qui
            // recréerait exactement l'écart qu'on vient de supprimer. Le plancher à
            // 1 est une nécessité physique — une cellule ne peut pas être plus
            // petite qu'un pixel — et ne mord que sur une source de moins de 900 px
            // importée dans le studio.
            let echelleGrain = max(1, grandCote / Self.coteGrain)
            let voileGrain = bruit
                .samplingNearest()
                .transformed(by: CGAffineTransform(scaleX: echelleGrain, y: echelleGrain))
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
    /// Le critère est ici COMPOSÉ de cinq termes, chacun ramené dans [0, 1] par
    /// une rampe et MULTIPLIÉS entre eux — multiplier ne peut que retirer des
    /// candidats, jamais en inventer, et l'alpha reste borné à 1 (R1). Ils mesurent
    /// cinq grandeurs indépendantes : la luminance (T1), l'entourage (T2), le
    /// contraste local multi-échelle (T3), l'ambiance de la scène (T4) et la
    /// COMPACITÉ (T5).
    ///
    /// La carte est calculée sur l'image NUE, avant toute teinte : « cette source
    /// est-elle isolée ? » est une propriété de la PHOTO, pas du verre choisi. La
    /// tentative précédente indexait le rayon d'entourage sur le rayon du disque
    /// à dessiner, ce qui est une inversion de causalité : le Summicron aurait
    /// détecté des points que le Dream Lens aurait rejetés.
    ///
    /// ÉCHELLE D'ANALYSE NORMALISÉE (§ `coteDetection`). L'analyse est menée sur une
    /// réduction du cadre à 900 px de grand côté, puis la carte obtenue est
    /// réagrandie au cadre de travail. Sans cela, T1 — un seuil de luminance
    /// ABSOLUE — mesurait la taille du tampon et non la scène : le fichier 3200 px
    /// détectait des sources trois fois plus petites que le viseur 900 px, d'où
    /// « des disques dans la photo, aucun au viseur ».
    ///
    /// Le réagrandissement de la carte grossit la graine d'un facteur
    /// `grandCote`/900 : 1,00 px au viseur, 1,33 px à l'aperçu, 3,56 px à l'export.
    /// Le rayon du disque étant lui aussi proportionnel au grand côté, le RAPPORT
    /// graine/rayon ne dépend pas du cadre : l'élargissement du disque vaut
    /// exactement +6,7 % dans les TROIS cadres (Helios à k = 0,75 — viseur 7,46 →
    /// 7,96 px, aperçu 9,95 → 10,62 px, export 26,53 → 28,31 px). R3 est donc
    /// préservée, et c'est à comparer à des disques présents ou absents selon le
    /// cadre, ce qui était l'état d'avant.
    ///
    /// L'analyse coûte aussi 45 fois moins cher à l'export : les deux morphologies
    /// et la gaussienne s'exécutent sur 674×900 = 606 600 px avec des rayons de
    /// 8,10 et 45,0 px, au lieu de 2400×3200 = 7 680 000 px avec des rayons de 28,8
    /// et 160 px.
    private static func detecterPoints(_ base: CIImage,
                                       cadre: CGRect,
                                       grandCote: CGFloat) -> CIImage {

        let facteur = min(1, Self.coteDetection / grandCote)

        // Cadre déjà au plus égal à la grille de référence (viseur, ou petite image
        // importée) : réduire puis réagrandir n'ajouterait que du flou.
        guard facteur < 0.999 else {
            return carteDePoints(base, cadre: cadre, grandCote: grandCote)
        }

        // R2 : filtre à support spatial, donc clamp avant et recadrage après. Le
        // support de Lanczos vaut 3/facteur px source ; sans le clamp, le pourtour
        // de la carte serait assombri par le « noir transparent » de l'extérieur,
        // ce qui est exactement le piège que R2 décrit pour l'érosion.
        let cadreAnalyse = CGRect(x: cadre.origin.x * facteur,
                                  y: cadre.origin.y * facteur,
                                  width: cadre.width * facteur,
                                  height: cadre.height * facteur)
        let reduite = base
            .clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [
                "inputScale": Float(facteur),
                "inputAspectRatio": Float(1)
            ])
            .cropped(to: cadreAnalyse)

        // Réagrandissement en BILINÉAIRE (transformation affine simple) et non en
        // Lanczos : à l'agrandissement, les lobes négatifs de Lanczos produiraient
        // un dépassement sous zéro et au-dessus de un autour de chaque point, que
        // `CIMultiplyCompositing` propagerait dans la graine. Une interpolation
        // bilinéaire d'un agrandissement ne peut pas dépasser les bornes de ses
        // voisins, donc la carte reste dans [0, 1] comme le veut R1.
        // Le clamp avant l'agrandissement n'est pas cosmétique : l'arrondi de
        // `cadreAnalyse` peut laisser l'étendue réagrandie un pixel en deçà de
        // `cadre`, et `CIAreaAverage` de `porteDeCouverture` moyennerait alors du
        // noir transparent sur ce liseré.
        return carteDePoints(reduite,
                             cadre: cadreAnalyse,
                             grandCote: grandCote * facteur)
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / facteur, y: 1 / facteur))
            .cropped(to: cadre)
    }

    /// Le critère proprement dit, à l'échelle où on le lui donne. Toujours appelé
    /// via `detecterPoints`, qui garantit que `grandCote` vaut au plus
    /// `coteDetection` — c'est cette garantie qui rend les cinq seuils absolus
    /// ci-dessous comparables d'un cadre à l'autre.
    private static func carteDePoints(_ base: CIImage,
                                      cadre: CGRect,
                                      grandCote: CGFloat) -> CIImage {

        // Saturation nulle : un rouge saturé ne doit pas compter comme une haute
        // lumière au seul motif que son canal rouge est écrêté.
        let luminance = base.applyingFilter("CIColorControls", parameters: [
            "inputSaturation": Float(0),
            "inputBrightness": Float(0),
            "inputContrast": Float(1)
        ])

        // Rayon d'analyse, relatif au cadre (R3). Depuis la normalisation de
        // l'échelle d'analyse, `grandCote` vaut ici 900 dans les TROIS cadres —
        // viseur, aperçu et export — donc le rayon vaut 8,10 px partout, et non
        // plus 8,10 / 10,8 / 28,8 px selon le tampon. Le plancher à 3 px ne mord
        // qu'en dessous de 333 px de grand côté, cas d'une petite image importée.
        let rayonAnalyse = max(3, grandCote * 0.009)

        // ─────────────────────────────────────────────────────────────────────
        // MORPHOLOGIE MULTI-ÉCHELLE, et c'est la correction d'une panne totale.
        //
        // Le code n'analysait qu'à UNE échelle, rayonAnalyse = 8,10 px. T2 (rampe
        // décroissante sur l'érosion à 8,10 px) et T3 (chapeau à 8,10 px) formaient
        // alors un filtre passe-bande de TAILLE beaucoup plus étroit que ce que le
        // commentaire supposait : pour être détectée, une source devait voir sa
        // luminance s'effondrer en MOINS de 8,10 px. Or c'est exactement ce qu'une
        // vraie source lumineuse ne fait pas — elle a un halo. Dès que le cœur
        // écrêté dépasse rayonAnalyse, l'ouverture CONSERVE la source (chapeau ≡ 0)
        // ET l'érosion vaut 1 en son centre : T2 = T3 = 0, produit exactement nul.
        //
        // Balayage mesuré (cœur R écrêté + halo gaussien σ, fond nocturne 0,05,
        // cadre 674×900), MAX du produit des quatre termes de l'ancien critère :
        //     R = 1 px : σ=1 → 1,000 · σ=4 → 1,000 · σ=8 → 0,017 · σ=16 → 0,000
        //     R = 3 px : σ=4 → 0,989 · σ=8 → 0,000
        //     R = 5 px : σ=4 → 0,176 · σ=8 → 0,000
        //     R = 8 px : σ=1 → 0,539 · σ=2 → 0,000
        //     R = 10 px et au-delà : 0,000 pour TOUT σ
        // Sur une RUE DE NUIT complète : lampadaire proche (cœur 10 px, σ=25) →
        // T1 = 1,000 mais érosion = 1,000 donc T2 = 0 et chapeau = 0,000 donc
        // T3 = 0, produit 0,00000 ; lampadaire lointain (cœur 3 px, σ=5) → produit
        // 0,00000. Seules passaient les ampoules de guirlande (cœur 2 px, σ=3).
        // L'étage C ne s'allumait JAMAIS sur un vrai lampadaire — c'est-à-dire sur
        // la seule scène qui justifie son existence.
        //
        // Corrigé par l'opérateur canonique « source claire de taille QUELCONQUE
        // sur fond sombre » : le chapeau haut-de-forme est pris à TROIS échelles,
        // 1×, 3× et 6× rayonAnalyse (8,10 / 24,3 / 48,6 px), et on garde le
        // MAXIMUM. Un chapeau reste ≡ 0 le long d'un demi-plan à toutes les
        // échelles, donc le verrou contre les bords francs est intact ; mais un
        // cœur large ou un halo étendu, invisible à 8,10 px, apparaît à 48,6 px.
        // Le même balayage donne maintenant 1,000 pour le lampadaire proche comme
        // pour le lointain comme pour la guirlande.
        //
        // COÛT — c'est ce qui impose la PYRAMIDE. Une morphologie par disque de
        // 48,6 px sur 606 600 px serait ~7 400 taps par pixel, hors budget d'une
        // trame de viseur. Un disque de rayon r sur une image réduite d'un facteur
        // f est l'équivalent d'un disque de rayon f·r sur l'image pleine, pour f²
        // fois moins de pixels ET le même nombre de taps. Les trois étages réunis
        // coûtent donc 1 + 1/9 + 1/36 = 1,14 fois l'étage unique d'avant. Ce qui se
        // perd à la réduction est la résolution du VOISINAGE, qui est précisément
        // ce que ces deux grandes échelles mesurent.
        let etage1 = etageMorphologique(luminance, rayon: rayonAnalyse, facteur: 1, cadre: cadre)
        let etage3 = etageMorphologique(luminance, rayon: rayonAnalyse, facteur: 3, cadre: cadre)
        let etage6 = etageMorphologique(luminance, rayon: rayonAnalyse, facteur: 6, cadre: cadre)

        // L'érosion RETENUE est celle de la plus grande échelle : « il y a du sombre
        // à moins de 48,6 px », et non plus « à moins de 8,10 px ».
        let erosion = etage6.erosion

        // Chapeau haut-de-forme blanc : luminance − ouverture, réuni par
        // `CIMaximumCompositing` (union bornée à 1, jamais une addition — R1).
        // L'ouverture reste ≤ luminance à chaque échelle, donc chaque différence
        // est une soustraction exacte (R4). Le réagrandissement bilinéaire des deux
        // grandes échelles ne peut pas dépasser les bornes de ses voisins ; là où il
        // rendrait malgré tout l'ouverture supérieure à la luminance — un trait
        // SOMBRE et fin — la valeur absolue de la différence devient positive, mais
        // T1 rejette ce pixel puisque sa luminance est basse.
        let chapeau = luminance
            .applyingFilter("CIDifferenceBlendMode", parameters: [
                "inputBackgroundImage": etage1.ouverture
            ])
            .applyingFilter("CIMaximumCompositing", parameters: [
                "inputBackgroundImage": luminance.applyingFilter("CIDifferenceBlendMode", parameters: [
                    "inputBackgroundImage": etage3.ouverture
                ])
            ])
            .applyingFilter("CIMaximumCompositing", parameters: [
                "inputBackgroundImage": luminance.applyingFilter("CIDifferenceBlendMode", parameters: [
                    "inputBackgroundImage": etage6.ouverture
                ])
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
        //
        // DEUX changements, tous deux mesurés. L'érosion est prise à 48,6 px et non
        // plus à 8,10 px : le seuil analytique de l'ancienne version était
        // σ_max = (rayonAnalyse − R)/1,264, soit 6,41 px de halo pour un point et
        // 4,83 px pour un cœur de 2 px — au-delà, T2 = 0 exactement. Un lampadaire
        // proche (cœur 10 px, σ=25) donnait une érosion de 1,000, donc T2 = 0. À
        // 48,6 px la même source donne 0,304, donc T2 = 1,000.
        // Et la rampe est relâchée de (0,45 → 0,12) à (0,80 → 0,35) : à grande
        // échelle il n'est plus nécessaire que le voisinage soit NOIR, il suffit
        // qu'il soit plus sombre que la source. Repères sRGB mesurés : sable au
        // soleil 0,75 → T2 = 0,111 ; ciel bleu 0,63 → 0,378 ; mur d'intérieur 0,45
        // → 0,778 ; rue de nuit 0,05 → 1,000.
        let t2 = rampe(erosion, bas: 0.80, haut: 0.35)

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
        // pouvait le croire), T2 parce que l'érosion trouve les cheveux sombres
        // tout à côté, T3 à pleine amplitude. La graine contient alors un liseré de
        // points TOUT LE LONG du contour du sujet, que C3 dilate et que C4 creuse
        // en anneaux : les liserés de la capture incriminée. Le garde-fou de
        // couverture ne rattrape rien, ces lamelles pesant moins de 0,35 % du cadre.
        //
        // CE N'EST PAS T4 QUI FERME CE TROU, contrairement à ce qu'affirmait ce
        // commentaire. Il prétendait que la moyenne locale vaut ≈ 0,6 entre les
        // mèches. Mesurée sur la scène décrite — cheveux à 0,10, lamelles de ciel
        // de 3 px à 0,99 tous les 14 px, cadre 674×900 — elle vaut 0,291, que le
        // flou soit pris à σ = rayon (45 px) ou à σ = rayon/3 (15 px). L'ancien T4
        // laissait donc passer 0,460 d'amplitude, avec T1 = T2 = T3 = 1,000. C'est
        // très exactement le liseré reproché à la capture de plage. Le trou est
        // fermé par T5, ci-dessous, qui mesure la bonne grandeur : l'ALLONGEMENT.
        let t3 = rampe(chapeau, bas: 0.20, haut: 0.50)

        // T4 — VOISINAGE SOMBRE À GRANDE ÉCHELLE. C'est la traduction littérale du
        // principe physique : une bulle n'existe que là où tout le pourtour est
        // sombre. L'érosion de T2 est ponctuelle et se laisse abuser par un creux
        // local ; la moyenne à grande échelle, elle, décrit la SCÈNE.
        //
        // DEUX FAUTES CORRIGÉES ICI, toutes deux mesurées.
        //
        // (1) LA MOYENNE ÉTAIT PRISE SUR LA LUMINANCE NUE, donc une source
        //     relevait elle-même sa propre ambiance : plus elle était brillante et
        //     large, plus elle abaissait son propre T4. Mesuré sur la rue de nuit,
        //     lampadaire proche : ambiance 0,358 et T4 = 0,222 — un plafond de 22 %
        //     d'amplitude imposé au voisinage de la source la plus brillante du
        //     cadre, uniquement parce qu'elle brille. L'ambiance est désormais
        //     calculée sur l'ÉROSION à 48,6 px, qui a déjà retiré la source : le
        //     même lampadaire donne 0,06 et T4 = 1,000.
        //
        // (2) LA RAMPE (0,42 → 0,14) ÉTEIGNAIT TOUT INTÉRIEUR. Elle exigeait une
        //     ambiance sous 0,42 sRGB, c'est-à-dire plus sombre qu'un mur peint, un
        //     plafond blanc ou une pièce éclairée. Mesuré sur la scène de la
        //     capture — couloir, murs 0,45, plafond 0,62, spot au plafond (cœur
        //     5 px, σ=12), fenêtre 0,96, cadre 674×900 — l'étage C rendait un MAX
        //     de 0,00000 et une couverture de 0,0000 % : rigoureusement vide, le
        //     spot étant rejeté DEUX fois, par T2 et par T4.
        //     La rampe est déplacée à (0,62 → 0,20). Valeurs mesurées avec
        //     l'ambiance corrigée : rue de nuit 0,06 → T4 = 1,000 ; pièce du soir
        //     0,30 → 0,770 ; couloir clair 0,61 → 0,024 ; ciel de plage 0,63 →
        //     0,000 ; écume 0,75 → 0,000 ; mer au soleil 0,58 → 0,100.
        //
        // LIMITE ASSUMÉE ET CHIFFRÉE : sur le produit complet, un spot dans une
        // pièce du soir passe à 0,773 (il était à 0,000), mais un spot dans un
        // couloir aux murs et plafond CLAIRS reste à 0,005. C'est délibéré et non
        // une négligence : l'ambiance d'un tel couloir (0,61) est celle d'une mer
        // ensoleillée (0,58), et aucune mesure de voisinage ne peut les séparer.
        // Entre « pas de disques dans un couloir clair » et « des anneaux fantômes
        // sur la mer », R5 tranche : on garde le premier.
        //
        // PRIX PAYÉ, mesuré et jugé acceptable : une mer scintillante au soleil
        // passe de 0,0000 % de couverture de graine à 0,0299 %, avec un produit
        // MAXIMAL de 0,034. Screené, cela vaut 0,034·(1 − 0,58) = 1,4 % de delta sur
        // l'eau — sous le seuil de perception, et treize fois moins que le 0,460
        // d'amplitude que l'ancien détecteur posait sur les lamelles de cheveux.
        let ambiance = erosion
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                "inputRadius": Float(max(8, grandCote * 0.05))
            ])
            .cropped(to: cadre)
        let t4 = rampe(ambiance, bas: 0.62, haut: 0.20)

        // T5 — COMPACITÉ. Le critère qui manquait, et le seul qui ferme réellement
        // l'angle mort de T3 décrit plus haut : une lamelle de ciel entre deux
        // mèches est une structure ALLONGÉE, un disque de bokeh est COMPACT. Ni la
        // luminance, ni l'entourage, ni l'ambiance ne distinguent les deux — seule
        // la forme le fait.
        //
        // L'ouverture par un SEGMENT horizontal supprime toute structure plus
        // étroite que le segment dans la direction horizontale, et la laisse
        // intacte si elle est plus large ; idem verticalement. On prend le MINIMUM
        // des deux (`CIMinimumCompositing` : une intersection, bornée, jamais une
        // addition — R1), puis la différence avec la luminance. Cette différence
        // est grande sur une structure fine dans AU MOINS une direction, et nulle
        // sur une tache compacte ou sur une grande plage claire. Les deux
        // ouvertures sont ≤ luminance, donc la différence est encore une
        // soustraction exacte (R4).
        //
        // Longueur du segment : 0,6·rayonAnalyse arrondi au nombre IMPAIR
        // supérieur, comme l'exige `CIMorphologyRectangle*`, soit 5 px sur la
        // grille d'analyse normalisée à 900 px. Elle sépare mesurément :
        //   lamelle de ciel de 3 px entre des cheveux à 0,10 → différence 0,89 →
        //   T5 = 0,000 ; même lamelle au bord du ciel ouvert → 0,36 → 0,000 ;
        //   ampoule de guirlande (cœur 2 px, σ=3) → 0,00 → 1,000 ; lampadaire →
        //   1,000 ; grande plage claire → 1,000 (rejetée ailleurs, par T2 et T3).
        // Sur la scène de plage complète, la couverture de la graine tombe de
        // 1,0276 % à 0,0393 % — vingt-six fois moins de faux positifs le long du
        // contour du sujet.
        //
        // LIMITE ASSUMÉE : le segment étant axial, une lamelle DIAGONALE plus large
        // que 5 px sur la grille d'analyse survit. `CIMorphologyRectangle*` ne sait
        // pas faire d'élément structurant oblique ; l'alternative — quatre
        // ouvertures de plus — ne tient pas dans le budget d'une trame de viseur.
        let coteSegment = max(3, Int((rayonAnalyse * 0.6).rounded(.up)) | 1)
        let compacite = ouvertureRectangle(luminance, largeur: coteSegment, hauteur: 1, cadre: cadre)
            .applyingFilter("CIMinimumCompositing", parameters: [
                "inputBackgroundImage": ouvertureRectangle(luminance,
                                                           largeur: 1,
                                                           hauteur: coteSegment,
                                                           cadre: cadre)
            ])
        let allongement = luminance.applyingFilter("CIDifferenceBlendMode", parameters: [
            "inputBackgroundImage": compacite
        ])
        let t5 = rampe(allongement, bas: 0.35, haut: 0.10)

        return t1
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": t2])
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": t3])
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": t4])
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": t5])
    }

    /// Érosion et ouverture morphologiques à l'échelle `facteur`, calculées sur une
    /// image réduite d'autant puis réagrandies au cadre.
    ///
    /// Un disque de rayon `rayon` sur une image réduite d'un facteur f est
    /// l'équivalent d'un disque de rayon f·`rayon` sur l'image pleine, pour f² fois
    /// moins de pixels ET le même nombre de taps par pixel : c'est ce qui rend
    /// l'analyse à 24,3 et 48,6 px abordable dans une trame de viseur.
    ///
    /// La réduction est une transformation AFFINE (bilinéaire) et non un Lanczos :
    /// les lobes négatifs de Lanczos feraient dépasser l'ouverture au-dessus de la
    /// luminance le long des bords clairs, donc un faux chapeau — précisément le
    /// générateur de liserés que R4 interdit. Une bilinéaire ne peut pas dépasser
    /// les bornes de ses voisins.
    ///
    /// Réduire puis réagrandir d'un même facteur autour de l'origine est une
    /// composition de mises à l'échelle : la position est restituée exactement,
    /// aucune translation n'est nécessaire, quel que soit `cadre.origin`.
    private static func etageMorphologique(_ luminance: CIImage,
                                           rayon: CGFloat,
                                           facteur: CGFloat,
                                           cadre: CGRect) -> (erosion: CIImage, ouverture: CIImage) {

        let r = Float(max(1, rayon))

        // R2 : clamp avant, recadrage après, à CHAQUE étage — sans le clamp,
        // l'érosion verrait une bordure de noir transparent tout autour du cadre et
        // toute la périphérie passerait le test d'entourage.
        func erodeEtOuvre(_ image: CIImage, dans zone: CGRect) -> (erosion: CIImage, ouverture: CIImage) {
            let ero = image
                .clampedToExtent()
                .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": r])
                .cropped(to: zone)
            let ouv = ero
                .clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": r])
                .cropped(to: zone)
            return (ero, ouv)
        }

        guard facteur > 1.001 else {
            let (ero, ouv) = erodeEtOuvre(luminance, dans: cadre)
            return (ero, ouv)
        }

        let reduite = luminance
            .cropped(to: cadre)
            .transformed(by: CGAffineTransform(scaleX: 1 / facteur, y: 1 / facteur))
        let cadreReduit = reduite.extent

        // Cadre devenu trop petit pour que la morphologie ait un sens : on retombe
        // sur l'échelle unité plutôt que de rendre une image dégénérée (R5).
        guard cadreReduit.width >= 4 * CGFloat(r), cadreReduit.height >= 4 * CGFloat(r) else {
            let (ero, ouv) = erodeEtOuvre(luminance, dans: cadre)
            return (ero, ouv)
        }

        let (ero, ouv) = erodeEtOuvre(reduite, dans: cadreReduit)
        let agrandissement = CGAffineTransform(scaleX: facteur, y: facteur)
        return (ero.clampedToExtent().transformed(by: agrandissement).cropped(to: cadre),
                ouv.clampedToExtent().transformed(by: agrandissement).cropped(to: cadre))
    }

    /// Ouverture morphologique par un élément structurant RECTANGULAIRE, clampée
    /// puis recadrée (R2). `largeur` et `hauteur` doivent être impairs, ce que
    /// `CIMorphologyRectangle*` exige.
    private static func ouvertureRectangle(_ image: CIImage,
                                           largeur: Int,
                                           hauteur: Int,
                                           cadre: CGRect) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIMorphologyRectangleMinimum", parameters: [
                "inputWidth": Float(largeur),
                "inputHeight": Float(hauteur)
            ])
            .clampedToExtent()
            .applyingFilter("CIMorphologyRectangleMaximum", parameters: [
                "inputWidth": Float(largeur),
                "inputHeight": Float(hauteur)
            ])
            .cropped(to: cadre)
    }

    /// Garde-fou de COUVERTURE : la porte qui rend l'étage C auto-régulé.
    ///
    /// Renvoie 1 tant que les disques réellement dessinés couvrent au plus 20 % du
    /// cadre, 0 au-delà de 45 %, avec une rampe continue entre les deux — pas de
    /// basculement visible en bougeant le curseur.
    ///
    /// C'EST UN GARDE-FOU, PAS LE MÉCANISME PRINCIPAL. Une porte qui mesure une
    /// SURFACE ne mesure ni un NOMBRE ni une ISOLATION : la cause des « anneaux
    /// fantômes flottant sur la mer » est traitée en amont par T2, T4 et T5, pas
    /// ici. La porte ne rattrape que le cas résiduel « le calque mange l'image ».
    ///
    /// CE QUE MESURAIT LA VERSION PRÉCÉDENTE, ET POURQUOI C'ÉTAIT FAUX. Elle
    /// moyennait la GRAINE — les points détectés — alors que ce qui est screené sur
    /// l'image est cette graine DILATÉE de `rayonDisque`. Pour des points de 2 px de
    /// rayon sur un cadre de 900 px de grand côté, à k = 1, le facteur d'expansion
    /// d'aire ((rp + rD)/rp)² vaut :
    ///   Summicron rD = 3,89 px → ×8,7    Noct-Nikkor 4,86 → ×11,8
    ///   Helios     8,91 → ×29,8          Biotar      9,72 → ×34,3
    ///   Takumar   10,04 → ×36,3          Angénieux  11,34 → ×44,5
    ///   Noctilux  14,26 → ×66,1          Trioplan   15,39 → ×75,6
    ///   Dream     19,44 → ×114,9
    /// Les seuils 0,25 % / 1,2 % étaient donc calibrés sur une grandeur une à deux
    /// décades trop petite : à la limite « porte grande ouverte », les disques
    /// couvraient déjà 2,2 % du cadre pour le Summicron et 28,7 % pour le Dream ; au
    /// seuil de fermeture, 10,4 % et 100 %. Et le garde-fou ne dépendait PAS de
    /// `size` alors que le facteur d'expansion, lui, varie d'un rapport 13 entre le
    /// Summicron et le Dream : la même scène passait la porte avec un objectif et
    /// saturait le cadre avec un autre.
    ///
    /// PANNE SYMÉTRIQUE, aussi grave : mesurer une surface de GRAINE, c'est punir le
    /// NOMBRE de points — donc éteindre l'étage C précisément sur la scène la plus
    /// riche en vraies sources ponctuelles. Mesuré, guirlande de N ampoules de 2 px
    /// sur un cadre 674×900 : N = 100 → porte 0,747 ; N = 200 → 0,360 ; N = 400 →
    /// 0,000, ÉTEINT. Une guirlande, un sapin, une ville de nuit sont l'argument de
    /// vente de cet étage.
    ///
    /// La porte mesure donc maintenant la couverture APRÈS dilatation, ce qui est
    /// exactement la grandeur visuelle, et rend le seuil intrinsèquement dépendant
    /// de l'objectif sans avoir à le paramétrer.
    ///
    /// `CIAreaAverage` moyenne la dilatation GRISE, donc la couverture est pondérée
    /// par l'amplitude de chaque détection : un faux positif à 0,03 ne pèse que 3 %
    /// de sa surface. C'est le comportement voulu — la porte mesure ce qui va être
    /// PEINT, pas ce qui a été candidat. Mesuré avec le détecteur corrigé, cadre
    /// 674×900, k = 1, couverture puis porte :
    ///   rue de nuit    graine 0,259 % → 1,29 % (Helios) → 1 · 4,02 % (Dream) → 1
    ///   pièce du soir  graine 0,340 % → 1,33 %          → 1 · 2,90 %         → 1
    ///   plage          graine 0,039 % → 0,27 %          → 1 · 0,62 %         → 1
    ///   mer au soleil  graine 0,030 % → 0,64 %          → 1 · 1,68 %         → 1
    ///   guirlande 100  graine 0,492 % → 6,50 %          → 1 · 22,45 %        → 0,902
    ///
    /// Le comportement en NOMBRE, qui était la panne symétrique, guirlande de N
    /// ampoules de 2 px (couverture après dilatation, puis porte) :
    ///     N     Summicron        Helios          Noctilux        Dream
    ///     100   2,12 %  1,000    6,50 %  1,000   13,85 % 1,000   22,45 % 0,902
    ///     200   4,12 %  1,000   12,20 %  1,000   24,42 % 0,823   37,21 % 0,312
    ///     400   8,21 %  1,000   23,88 %  0,845   45,03 % 0,000   63,89 % 0,000
    ///     800  15,97 %  1,000   42,40 %  0,104   70,21 % 0,000   86,77 % 0,000
    ///    1600  28,83 %  0,647   64,77 %  0,000   89,07 % 0,000   97,36 % 0,000
    /// L'extinction ne survient plus au bout de ≈ 350 ampoules pour TOUS les verres,
    /// mais quand les disques de CE verre-là recouvrent réellement la moitié du
    /// cadre : 1 600 ampoules au Summicron, 400 au Dream Lens.
    private static func porteDeCouverture(_ points: CIImage,
                                          rayonDisque: CGFloat,
                                          cadre: CGRect) -> CGFloat {

        // Sonde mesurée sur un cadre réduit d'un facteur 4 : la couverture est une
        // statistique globale, sa résolution spatiale n'a aucune importance, et la
        // dilatation y coûte 16 fois moins cher.
        let reduction: CGFloat = 4

        // PRÉ-DILATATION de 2 px AVANT la réduction. Sans elle, le
        // sous-échantillonnage bilinéaire ne lit qu'un pixel sur quatre et peut
        // perdre entièrement une ampoule de 2 px : la couverture serait
        // sous-estimée, la porte resterait ouverte, et c'est le mauvais sens de
        // panne. Elle surestime légèrement la couverture, ce qui est le sens
        // acceptable au titre de R5.
        let sonde = points
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [
                "inputRadius": Float(reduction / 2)
            ])
            .cropped(to: cadre)
            .transformed(by: CGAffineTransform(scaleX: 1 / reduction, y: 1 / reduction))

        let cadreSonde = sonde.extent
        guard cadreSonde.width >= 1, cadreSonde.height >= 1 else { return 0 }

        let etalee = sonde
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [
                "inputRadius": Float(max(1, rayonDisque / reduction))
            ])
            .cropped(to: cadreSonde)

        let moyenne = etalee.applyingFilter("CIAreaAverage", parameters: [
            "inputExtent": CIVector(x: cadreSonde.origin.x,
                                    y: cadreSonde.origin.y,
                                    z: cadreSonde.width,
                                    w: cadreSonde.height)
        ])

        // Le gain 2 APRÈS la moyenne : la couverture utile va maintenant jusqu'à
        // 45 %, et non plus jusqu'à 1,2 %. Le gain 32 d'avant saturait dès 3,1 %,
        // ce qui rendrait la nouvelle rampe illisible. Avec 2, la résolution vaut
        // 0,196 % de couverture et la saturation intervient à 50 %, au-delà du
        // seuil de fermeture.
        let amplifie = attenuer(moyenne, facteur: 2)

        // Buffer initialisé à 255 et non à 0 : si le rendu GPU échoue en silence,
        // la couverture lue vaut 0,500 — au-dessus du seuil de fermeture, qui est
        // 0,45 — et l'étage C est désactivé. C'est le SENS DE LA PANNE imposé par
        // R5 : le mode de défaillance acceptable est « pas de disques », jamais
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

        let couverture = CGFloat(pixel[0]) / 255 / 2
        return min(max((0.45 - couverture) / (0.45 - 0.20), 0), 1)
    }

    // MARK: - Étage C : le calque des disques

    /// Rayon du cercle de confusion, en fraction du grand côté.
    ///
    /// Relatif, bornes relatives (R3) : l'aperçu 1200 px et l'export 3200 px restent
    /// la MÊME image à l'échelle près, même quand la borne mord.
    ///
    /// Isolé dans sa propre fonction parce que DEUX étages en dépendent désormais :
    /// le calque, qui dessine les disques, et le garde-fou de couverture, qui mesure
    /// la surface qu'ils occuperont. Les recopier serait s'exposer à ce qu'ils
    /// divergent — c'est-à-dire à mesurer autre chose que ce qu'on dessine, ce qui
    /// était exactement la panne du garde-fou.
    ///
    /// Valeurs à k = 1, en px sur un grand côté de 900 : Summicron 3,89 ·
    /// Noct-Nikkor 4,86 · Helios 8,91 · Biotar 9,72 · Takumar 10,04 · Angénieux
    /// 11,34 · Noctilux 14,26 · Trioplan 15,39 · Dream 19,44.
    private static func rayonDisqueRelatif(_ p: BokehParams, k: CGFloat) -> CGFloat {
        min(max(0.018 * CGFloat(p.size) * (0.35 + 0.65 * k), 0.0035), 0.055)
    }

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
                                      refVignettage: CGFloat,
                                      centre: CIVector) -> CIImage {

        let p = lens.bokeh

        let rayonDisque = grandCote * rayonDisqueRelatif(p, k: k)
        // Largeur de la transition du bord : `soft` va de 0,10 (bord franc du
        // Summicron) à 0,72 (halo évanescent du Dream Lens).
        //
        // PLANCHER RELATIF, et non plus `max(1, …)` en pixels absolus : ce plancher
        // d'un pixel MORDAIT réellement, sur les deux verres les plus nets, et
        // faisait diverger le viseur de l'export en violation de R3. Largeur brute
        // à k = 1, en px, pour 900 / 1200 / 3200 : Summicron 0,65 / 0,86 / 2,29 —
        // écrêtée à 1 dans les deux premiers cadres ; Noct-Nikkor 0,75 / 1,00 /
        // 2,68 — écrêtée au viseur. Le rapport largeurBord/rayonDisque, qui est LA
        // grandeur qui décide de l'aspect du bord, valait donc 0,257 au viseur
        // contre 0,166 à l'export pour le Summicron (×1,55) et 0,206 contre 0,155
        // pour le Noct-Nikkor (×1,33). Avec un plancher à 0,0006·grandCôté — 0,54 px
        // à 900, 1,92 px à 3200 — plus aucun des neuf verres n'est écrêté à k = 1,
        // et quand le plancher mord à basse intensité il mord à l'identique dans
        // les trois cadres.
        let largeurBord = max(grandCote * 0.0006,
                              rayonDisque * (0.10 + 0.55 * CGFloat(p.soft)))

        // C2. GRAINE : l'image nue, masquée par les points détectés, relevée puis
        // teintée de la couleur de bokeh de l'objectif. La teinte est appliquée
        // ICI, à la graine des disques, et non à une carte de luminance :
        // c'est la couleur des BULLES du catalogue, pas la dérive du verre (qui
        // relève de l'étage A).
        //
        // ORDRE DES DEUX OPÉRATIONS, et c'était une panne complète. Le code posait
        // un seul gain 1,6·mix(1, teinte, 0,55) PUIS écrêtait. Ce gain vaut au
        // MINIMUM, sur les trois canaux et pour les neuf verres :
        //   Takumar 1,141 · Angénieux 1,176 · Noctilux 1,279 · Helios 1,310 ·
        //   Trioplan 1,383 · Biotar 1,479 · Dream 1,490 · Summicron 1,521 ·
        //   Noct-Nikkor 1,576
        // La luminance maximale qui SURVIVE à l'écrêtage vaut donc 1/gain_min, soit
        // au mieux 0,876 (Takumar) et au pire 0,635 (Noct-Nikkor) — toutes
        // STRICTEMENT inférieures au seuil BAS de T1, qui est 0,88. Autrement dit :
        // tout pixel que la détection accepte est écrêté à 1,0 sur R, V ET B. Les
        // neuf palettes du catalogue sortaient des disques BLANC PUR, rigoureusement
        // identiques. Vérifié : une source à 0,88 comme une source à 1,00 donnent
        // (1,000 · 1,000 · 1,000) pour les neuf objectifs. La teinte ne subsistait
        // que là où `points` < 1 — c'est-à-dire sur les seules détections
        // marginales, donc sur les faux positifs, et nulle part ailleurs.
        //
        // Corrigé en séparant les deux rôles : un RELÈVEMENT neutre 1,6 suivi de
        // l'écrêtage, puis la TEINTE en gains tous ≤ 1, qui ne peut plus être
        // écrasée par un plafond qu'elle ne touche pas. Sortie d'un disque saturé
        // à k = 1, teinte à dose 0,55 : Helios (0,931 · 0,978 · 0,819), Takumar
        // (1,000 · 0,899 · 0,713), Noct-Nikkor (0,985 · 0,985 · 1,000), Noctilux
        // (1,000 · 0,933 · 0,799). Les neuf verres sont enfin distincts.
        let teinte = CouleurHex.composantes(lens.palette.first ?? lens.accent)
        let dose = 0.55 * k
        let releve = base
            .applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": points])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.6, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.6, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

        let graine = releve.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: melange(1, teinte.0, dose), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: melange(1, teinte.1, dose), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: melange(1, teinte.2, dose), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
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
                "inputRadius": Float(refVignettage * 0.62),
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

    /// Masque NORMALISÉ AU CADRE : noir et transparent au centre, blanc et opaque
    /// au-delà, avec des rayons exprimés en fraction du DEMI-CÔTÉ correspondant.
    ///
    /// `debut` et `fin` sont sans dimension. u = 1 est l'ELLIPSE INSCRITE, qui
    /// touche le milieu des quatre bords ; le coin est à u = √2. Ces deux repères
    /// ne dépendent d'AUCUN format, donc les statistiques du masque (aire saturée,
    /// aire nette, moyenne) sont rigoureusement identiques pour un carré, un 4:3,
    /// un 3:2, un 2,17 ou un panoramique 5:1 — ce que ni l'ancrage sur la
    /// diagonale ni l'ancrage sur le petit côté ne savaient faire. C'est la forme
    /// forte de R3 appliquée à la géométrie, et non plus seulement aux longueurs.
    ///
    /// La rampe est portée simultanément par la LUMINANCE et par l'ALPHA parce que
    /// la documentation de `CIBlendWithMask` est ambiguë selon les versions sur le
    /// canal réellement utilisé. En faisant coïncider les deux, le masque est
    /// correct quelle que soit la convention — voie conservatrice assumée.
    ///
    /// Le gradient est produit sur une grille de rayon `unite` puis étiré au cadre
    /// par une transformation ANISOTROPE. Passer par une grille de 512 plutôt que
    /// d'écrire directement des rayons de l'ordre de 0,5 évite de demander à un
    /// générateur procédural de rendre une rampe entière à l'intérieur d'un pixel.
    private static func masqueCadre(cadre: CGRect, debut: CGFloat, fin: CGFloat) -> CIImage? {
        let unite: CGFloat = 512
        guard cadre.width > 0, cadre.height > 0,
              let filtre = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": Float(debut * unite),
                "inputRadius1": Float(max(fin, debut + 0.002) * unite),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
              ]), let sortie = filtre.outputImage else {
            // R5 : pas de masque → l'appelant renonce à l'étape plutôt que de
            // l'appliquer sans confinement.
            return nil
        }

        // Étirement puis recentrage : un point à la distance u·unite de l'origine
        // atterrit sur l'ellipse de demi-axes u·largeur/2 et u·hauteur/2.
        let etirement = CGAffineTransform(scaleX: cadre.width / (2 * unite),
                                          y: cadre.height / (2 * unite))
            .concatenating(CGAffineTransform(translationX: cadre.midX, y: cadre.midY))

        // `CIRadialGradient` produit une image d'étendue INFINIE : le recadrage
        // n'est pas cosmétique, il est obligatoire.
        return sortie.transformed(by: etirement).cropped(to: cadre)
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
