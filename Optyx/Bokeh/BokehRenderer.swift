import Foundation
import Metal
import MetalKit
import simd

// MARK: - Bloc d'uniformes partagé avec le shader

/// Miroir Swift EXACT de `struct BokehUniforms` du fichier `.metal`. L'ordre des
/// champs est le contrat : Metal ne vérifie rien, il relit les octets tels quels.
/// Une permutation ne provoque aucune erreur de compilation — elle donne une scène
/// noire ou des disques aberrants, c'est-à-dire le pire mode de panne possible.
///
/// Les deux matrices sont EN TÊTE : `float4x4` s'aligne sur 16 octets des deux
/// côtés, alors qu'un scalaire placé avant introduirait un remplissage que le
/// compilateur MSL et le compilateur Swift ne calculent pas forcément pareil.
///
/// Contrairement à three.js, qui injecte `modelViewMatrix` et `projectionMatrix`
/// gratuitement dans tout `ShaderMaterial`, Metal n'injecte rien : ces deux
/// matrices doivent être construites côté Swift (voir `matricePerspective`, dont
/// la plage de profondeur est [0, 1] et non [-1, 1]).
///
/// Elles restent SÉPARÉES, et non pré-multipliées en une seule « mvp » : le vertex
/// shader a besoin de `mv.z` seul pour l'atténuation de taille en perspective
/// (`120 / -mv.z`). Une matrice combinée rendrait cette profondeur inaccessible et
/// aplatirait les trois couches à la même taille de sprite — le relief disparaîtrait.
struct BokehUniforms {
    var modelView: simd_float4x4 = matrix_identity_float4x4
    var projection: simd_float4x4 = matrix_identity_float4x4

    /// Secondes écoulées. Toujours replié par `wrapTau()` côté shader avant tout
    /// appel trigonométrique, et replié modulo `BokehRenderer.periodeHorloge` côté
    /// CPU pour que le `Float` conserve sa résolution sur une session longue.
    var time: Float = 0
    var size: Float = 0
    var pixelRatio: Float = 2
    var swirl: Float = 0
    var rise: Float = 0
    var pan: Float = 0
    var twinkle: Float = 0
    var opacity: Float = 0
    var ring: Float = 0
    var rim: Float = 0
    var soft: Float = 0.5
    var fringe: Float = 0
    var cat: Float = 0
    var spike: Float = 0

    /// Remplissage explicite. 2 × 64 octets de matrices + 14 × 4 octets de scalaires
    /// = 184, que l'alignement 16 porte à un `stride` de 192 des deux côtés. Sans ces
    /// deux mots, `MemoryLayout.size` (184) et `.stride` (192) diffèrent : transmettre
    /// 192 octets lirait 8 octets au-delà de la valeur, et n'en transmettre que 184
    /// laisserait Metal considérer le tampon plus court que la structure MSL. Les
    /// figer ici supprime le choix.
    var remplissage0: Float = 0
    var remplissage1: Float = 0
}

// MARK: - Générateur déterministe

/// Générateur congruentiel de Lehmer (MINSTD, multiplicateur 16807), copié du site.
///
/// C'est une propriété produit et non un détail d'implémentation : la disposition
/// des disques doit être identique à chaque lancement ET identique au site. Un
/// `SystemRandomNumberGenerator` donnerait une belle scène, mais une scène qui
/// change à chaque ouverture — l'utilisateur ne retrouverait jamais « sa » vue.
///
/// La graine est un `Int` 64 bits, jamais un `Int32` : `16807 × seed` culmine vers
/// 2^46. En JavaScript le calcul se fait en `double` (mantisse 53 bits) et reste
/// exact ; en `Int32` il déborderait et la suite divergerait silencieusement de
/// celle du site.
private struct Minstd {
    private var graine: Int

    init(_ graine: Int) { self.graine = graine }

    mutating func suivant() -> Double {
        graine = (graine &* 16807) % 2147483647
        return Double(graine - 1) / 2147483646.0
    }
}

// MARK: - Description d'une couche

/// Un plan de profondeur. Le relief ne vient pas d'un test de profondeur (il n'y en
/// a aucun, cf. le mélange additif) mais du DÉCALAGE entre les trois couches : la
/// proche est peu nombreuse, grosse et rapide, la lointaine dense, fine et lente.
private struct ReglageCouche {
    let nombre: Int
    let proche: Float
    let lointain: Float
    /// Multiplicateur appliqué côté CPU sur `size` — ce n'est pas un uniforme du site.
    let taille: Float
    /// Multiplicateur appliqué côté CPU sur `swirl` et `rise`.
    let vitesse: Float
}

// MARK: - État GPU d'une couche

/// Les tampons d'une couche, alloués UNE SEULE FOIS. Positions et phases ne changent
/// jamais ; seules les couleurs sont réécrites à chaque trame, en place.
///
/// C'est une classe et non une structure pour que `for couche in couches` livre une
/// référence : muter `couche.uniformes` dans la boucle de dessin ne recopie alors
/// pas 192 octets par couche et par trame, et surtout n'oblige pas à réécrire
/// l'élément dans le tableau.
private final class CoucheGPU {
    let nombre: Int
    let facteurTaille: Float
    let facteurVitesse: Float

    let positions: MTLBuffer
    let phases: MTLBuffer
    let couleurs: MTLBuffer

    /// Vue typée sur `couleurs.contents()`, mémorisée à la construction : la relier
    /// à chaque trame ne coûterait rien, mais l'exigence « aucune allocation dans
    /// draw(in:) » se tient plus facilement quand rien n'est recalculé du tout.
    let ecritureCouleurs: UnsafeMutablePointer<Float>

    /// Couleur visée par particule, en LINÉAIRE. Recalculée au seul changement
    /// d'objectif ; la trame se contente d'interpoler vers elle.
    var cibles: [SIMD3<Float>]

    var uniformes = BokehUniforms()

    init?(device: MTLDevice, reglage: ReglageCouche, graine: Int) {
        nombre = reglage.nombre
        facteurTaille = reglage.taille
        facteurVitesse = reglage.vitesse

        var positionsCPU = [Float](repeating: 0, count: reglage.nombre * 3)
        var phasesCPU = [Float](repeating: 0, count: reglage.nombre)

        // QUATRE tirages par particule, DANS CET ORDRE. Toute permutation — même
        // équivalente statistiquement — produit une autre scène que celle du site.
        var alea = Minstd(graine)
        for i in 0..<reglage.nombre {
            // La racine carrée redresse la densité : sans elle, le tirage uniforme
            // du rayon entasse les particules au centre du disque.
            let rayon = Float(0.5 + alea.suivant().squareRoot() * 4.2)
            let angle = Float(alea.suivant() * Double.pi * 2)
            // Ellipse très large (1.25 / 0.55) : le cadre du héros l'est aussi, et
            // une répartition circulaire laisserait le haut et le bas vides.
            positionsCPU[i * 3] = cos(angle) * rayon * 1.25
            positionsCPU[i * 3 + 1] = sin(angle) * rayon * 0.55
            positionsCPU[i * 3 + 2] = -(reglage.proche
                + Float(alea.suivant()) * (reglage.lointain - reglage.proche))
            phasesCPU[i] = Float(alea.suivant())
        }

        // 3 × 4 octets par position : c'est exactement le pas d'un `packed_float3`
        // MSL. Un `float3` non empaqueté ferait 16 octets et le shader lirait une
        // particule sur quatre, en désordre.
        let octetsPositions = positionsCPU.count * MemoryLayout<Float>.stride
        let octetsPhases = phasesCPU.count * MemoryLayout<Float>.stride
        let octetsCouleurs = reglage.nombre * 3 * MemoryLayout<Float>.stride

        guard let tamponPositions = device.makeBuffer(bytes: positionsCPU,
                                                      length: octetsPositions,
                                                      options: .storageModeShared),
              let tamponPhases = device.makeBuffer(bytes: phasesCPU,
                                                   length: octetsPhases,
                                                   options: .storageModeShared),
              let tamponCouleurs = device.makeBuffer(length: octetsCouleurs,
                                                     options: .storageModeShared)
        else { return nil }

        // Noir au départ, comme le `Float32Array` neuf du site : la scène s'allume
        // en fondu au premier affichage au lieu d'apparaître d'un bloc. Le contenu
        // d'un `MTLBuffer` neuf n'est pas garanti nul, d'où l'effacement explicite.
        let ecriture = tamponCouleurs.contents().assumingMemoryBound(to: Float.self)
        for i in 0..<(reglage.nombre * 3) { ecriture[i] = 0 }

        positions = tamponPositions
        phases = tamponPhases
        couleurs = tamponCouleurs
        ecritureCouleurs = ecriture
        cibles = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: reglage.nombre)
    }
}

// MARK: - Renderer

/// Pilote les scènes de bokeh du CATALOGUE : trois couches de points, un pipeline,
/// un profil de disque.
///
/// Ce qu'il ne fait pas, et qu'il ne faut pas lui prêter : le rendu du studio. Ce
/// renderer DESSINE un champ de particules synthétiques sur du noir, il ne prend
/// aucune image en entrée et n'a aucun moyen d'en transformer une. Le studio, lui,
/// part d'une photo : il passe par Core Image (`MoteurStudio`, dans StudioView.swift).
/// Il y a donc bel et bien DEUX rendus, et prétendre le contraire en commentaire
/// n'en ferait pas un seul.
///
/// Ce qui est réellement partagé — et c'est le seul partage qui réponde au reproche
/// ayant coulé la version précédente (« ça ne se voit pas, ce n'est pas comme le
/// site ») — ce sont les quatorze valeurs de `BokehParams` et les traits qu'elles
/// pilotent : bord adouci par `soft`, centre creusé par `ring`, liseré par `rim`,
/// frange par `fringe`, aigrettes par `spike`, taille modulée par le même facteur
/// (0,35 + 0,65·k). Une divergence entre ce que la fiche montre et ce que la photo
/// reçoit se corrige donc dans `BokehParams` ou dans l'un des deux rendus — jamais
/// en ajoutant un troisième chemin.
final class BokehRenderer: NSObject, MTKViewDelegate {

    // MARK: Constantes de scène

    /// Les trois plans du site, valeurs inchangées. 192 particules au total : c'est
    /// peu, et c'est suffisant parce que chaque disque porte toute la signature.
    private static let reglages: [ReglageCouche] = [
        ReglageCouche(nombre: 24, proche: 1.4, lointain: 2.8, taille: 1.5, vitesse: 1.15),
        ReglageCouche(nombre: 58, proche: 2.8, lointain: 4.8, taille: 0.95, vitesse: 0.85),
        ReglageCouche(nombre: 110, proche: 4.8, lointain: 7.5, taille: 0.55, vitesse: 0.6),
    ]

    /// Repli de l'horloge. Un `Float` a 24 bits de mantisse : à 4096 s le pas est de
    /// 5·10⁻⁴ s, soit 2·10⁻³ rad sur l'angle le plus rapide (4,5 rad/s) — invisible.
    /// Sans repli, une session laissée ouverte une nuit atteindrait des valeurs où le
    /// scintillement se quantifierait en stroboscope. Le repli provoque un saut de
    /// phase toutes les 68 minutes ; c'est le compromis retenu, et il est bien moins
    /// coûteux que la dégradation continue qu'il remplace.
    static let periodeHorloge: Double = 4096

    // MARK: Objets Metal

    let device: MTLDevice
    private let fileDeCommandes: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var couches: [CoucheGPU] = []

    // MARK: État d'animation

    /// Objectif affiché. Le changement ne remplace RIEN brutalement : seules les
    /// couleurs cibles sont recalculées, et la trame suivante commence à converger
    /// vers elles. C'est ce fondu qui donne l'impression que la scène « vit », et
    /// c'est exactement le soin que le site apporte.
    var lens: Lens {
        didSet {
            guard lens.id != oldValue.id else { return }
            majCiblesCouleurs()
        }
    }

    /// Curseur d'intensité, dans [0, 1] (le `k` du site). Module les DÉFAUTS de
    /// l'objectif ; `ring` et `soft` lui échappent volontairement, ce sont des traits
    /// structurels — une bulle de savon reste une bulle de savon à faible intensité.
    var intensite: Float = 1

    /// Horloge accumulée en `Double` : accumuler en `Float` perdrait des trames
    /// entières une fois passé quelques milliers de secondes (1/60 s devient
    /// inférieur à l'ULP).
    private var temps: Double = 0

    /// Palette courante déjà convertie en linéaire, pour ne pas relire des chaînes
    /// hexadécimales 192 fois par changement d'objectif.
    private var paletteLineaire: [SIMD3<Float>] = []
    private var duoLineaire: [SIMD3<Float>] = []

    // MARK: Construction

    /// Échoue — sans jamais lever — si le GPU, la bibliothèque de shaders ou le
    /// pipeline manquent. L'appelant affiche alors le dégradé statique du thème :
    /// une scène absente est un défaut d'agrément, un plantage au lancement est un
    /// défaut fatal, et rien ici ne justifie le second.
    init?(device: MTLDevice, lens: Lens = Lens.catalog[0]) {
        // Tout ce qui peut échouer est tenté AVANT d'écrire la moindre propriété :
        // l'ordre garde l'initialiseur lisible et sans état partiel.
        guard let file = device.makeCommandQueue(),
              let bibliotheque = device.makeDefaultLibrary(),
              let fonctionSommet = bibliotheque.makeFunction(name: "bokehVertex"),
              let fonctionFragment = bibliotheque.makeFunction(name: "bokehFragment")
        else { return nil }

        let descripteur = MTLRenderPipelineDescriptor()
        descripteur.label = "Bokeh"
        descripteur.vertexFunction = fonctionSommet
        descripteur.fragmentFunction = fonctionFragment
        descripteur.rasterSampleCount = 1

        // Format NON-sRGB, délibérément. three.js convertit les hex de palette en
        // linéaire mais un `ShaderMaterial` custom n'encode rien en sortie : le
        // canvas affiche ces valeurs linéaires comme si elles étaient de l'sRGB. Le
        // site est donc plus dense et plus saturé que ses hex ne le laissent croire,
        // et c'est CE rendu-là qui a été validé. Avec `.bgra8Unorm_srgb`, le matériel
        // ré-encoderait à l'écriture et l'image sortirait délavée.
        descripteur.colorAttachments[0].pixelFormat = .bgra8Unorm
        descripteur.colorAttachments[0].isBlendingEnabled = true

        // RVB : addition pure. Le shader a déjà appliqué `opacity`, l'œil de chat et
        // le scintillement, donc la source part telle quelle. `.one` plutôt que
        // `.sourceAlpha` rend le résultat INDÉPENDANT de l'alpha écrit.
        descripteur.colorAttachments[0].rgbBlendOperation = .add
        descripteur.colorAttachments[0].sourceRGBBlendFactor = .one
        descripteur.colorAttachments[0].destinationRGBBlendFactor = .one

        // ALPHA : la destination reste STRICTEMENT intacte. C'est la porte par
        // laquelle l'ancienne app s'était noircie deux fois : additionner N
        // contributions portant chacune alpha = 1 donne alpha = N, et la composition
        // suivante réinterprète le tout comme du prémultiplié. Ici la cible est
        // effacée à alpha = 1 et y reste, quel que soit le nombre de disques
        // superposés. On supprime le mécanisme de la panne au lieu de le désamorcer.
        descripteur.colorAttachments[0].alphaBlendOperation = .add
        descripteur.colorAttachments[0].sourceAlphaBlendFactor = .zero
        descripteur.colorAttachments[0].destinationAlphaBlendFactor = .one

        guard let etat = try? device.makeRenderPipelineState(descriptor: descripteur) else {
            return nil
        }

        var construites: [CoucheGPU] = []
        construites.reserveCapacity(BokehRenderer.reglages.count)
        for (index, reglage) in BokehRenderer.reglages.enumerated() {
            // Graines 1000, 1977, 2954 : celles du site. Les changer changerait la
            // disposition des disques, donc la scène que l'auteur a validée.
            guard let couche = CoucheGPU(device: device,
                                         reglage: reglage,
                                         graine: 1000 + index * 977)
            else { return nil }
            construites.append(couche)
        }

        self.device = device
        self.fileDeCommandes = file
        self.pipeline = etat
        self.couches = construites
        self.lens = lens
        super.init()

        majCiblesCouleurs()
    }

    // MARK: Préparation de la vue

    /// Aligne la `MTKView` sur ce que le pipeline attend. Les valeurs par défaut de
    /// `MTKView` coïncident déjà pour la plupart, mais les poser explicitement évite
    /// qu'un réglage d'apparence ajouté plus tard (multi-échantillonnage, tampon de
    /// profondeur) fasse diverger la vue du pipeline — divergence qui se manifeste
    /// par une exception à la création de l'encodeur, pas par un avertissement.
    func preparer(_ vue: MTKView) {
        vue.device = device
        vue.delegate = self
        vue.colorPixelFormat = .bgra8Unorm
        // Aucune profondeur : le site dessine avec `depthWrite: false` et sans test.
        // L'addition étant commutative, l'ordre des couches est de toute façon
        // indifférent — trier ou tester coûterait sans rien changer à l'image.
        vue.depthStencilPixelFormat = .invalid
        vue.sampleCount = 1
        // Effacement à alpha = 1 : c'est le pendant obligatoire du découplage alpha
        // du mélange. Un fond à alpha = 0 ressortirait à l'export comme une image
        // transparente que le compositeur assombrirait.
        vue.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        vue.isOpaque = true
        vue.framebufferOnly = true
        vue.preferredFramesPerSecond = 60
        vue.enableSetNeedsDisplay = false
        vue.isPaused = false
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Rien à réallouer : ni les tampons ni le pipeline ne dépendent de la taille.
        // Le rapport d'aspect est relu à chaque trame, ce qui est plus robuste que de
        // le mémoriser ici (cette méthode n'est pas appelée au tout premier affichage
        // sur toutes les versions d'iOS).
    }

    func draw(in view: MTKView) {
        let taille = view.drawableSize
        guard taille.width > 0, taille.height > 0 else { return }

        // Le temps avance par TRAME, pas par lecture d'horloge murale. Un
        // `CACurrentMediaTime()` brut donnerait un `Float` énorme (temps depuis le
        // démarrage de l'appareil, parfois des semaines) dont la mantisse ne
        // laisserait plus rien aux fractions de seconde : l'animation avancerait par
        // à-coups. Ici la valeur part de zéro et reste bornée.
        let cadence = view.preferredFramesPerSecond > 0
            ? Double(view.preferredFramesPerSecond) : 60
        let delta = 1 / cadence
        temps += delta
        if temps >= BokehRenderer.periodeHorloge { temps -= BokehRenderer.periodeHorloge }

        // Fondu du site : `min(1, delta × 3.2)`, soit ~5 % par trame à 60 Hz et ~8 %
        // à 40 Hz. Le taux est exprimé PAR SECONDE et non par trame, sinon la vitesse
        // du morphing dépendrait de la cadence d'affichage de l'appareil.
        let fondu = Float(min(1, delta * 3.2))

        // `point_size` s'exprime en pixels PHYSIQUES : sans ce facteur, les sprites
        // seraient deux à trois fois trop petits sur un écran Retina. Borné à [1, 3]
        // parce que la taille de point maximale d'un GPU Apple est 511 px et qu'un
        // facteur libre finirait par la heurter — l'écrêtage y serait immédiatement
        // visible, les gros disques cessant de grandir pendant que les petits
        // continuent.
        let largeurPoints = view.bounds.width
        let ratio: Float = largeurPoints > 0
            ? Float(min(3, max(1, taille.width / largeurPoints)))
            : 2

        majCouches(temps: Float(temps),
                   aspect: Float(taille.width / taille.height),
                   pixelRatio: ratio,
                   fondu: fondu)

        guard let descripteur = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let tampon = fileDeCommandes.makeCommandBuffer(),
              let encodeur = tampon.makeRenderCommandEncoder(descriptor: descripteur)
        else { return }

        encodeur.label = "Bokeh catalogue"
        encoderCouches(encodeur)
        encodeur.endEncoding()
        tampon.present(drawable)
        tampon.commit()
    }

    // Pas de rendu hors-écran ici. Il en existait un — `rendreScene(dans:…)`, qui
    // dessinait le champ de particules dans une texture — et il n'a JAMAIS eu
    // d'appelant : le studio part d'une photo et passe par Core Image. Le garder
    // revenait à faire tenir la promesse « un seul shader » par du code mort, ce qui
    // est pire que de ne pas la tenir : la relecture croit le contrat honoré et cesse
    // de vérifier que les deux rendus concordent. S'il faut un jour composer ces
    // disques SUR une photo, ce sera en `CIMaximumCompositing` ou `CIScreenBlendMode`
    // et jamais en alpha normal — la cible sort à alpha 1, et la traiter comme du
    // prémultiplié est exactement ce qui avait noirci deux fois l'ancienne app.

    // MARK: Encodage

    private func encoderCouches(_ encodeur: MTLRenderCommandEncoder) {
        encodeur.setRenderPipelineState(pipeline)
        for couche in couches {
            encodeur.setVertexBuffer(couche.positions, offset: 0, index: 0)
            encodeur.setVertexBuffer(couche.couleurs, offset: 0, index: 1)
            encodeur.setVertexBuffer(couche.phases, offset: 0, index: 2)

            // Les index de tampon des étages sommet et fragment sont DEUX espaces de
            // noms distincts : le même bloc doit être attaché des deux côtés, à des
            // index différents. En oublier un ne produit aucune erreur — juste des
            // uniformes à zéro d'un seul côté, donc des sprites invisibles ou des
            // disques uniformément noirs.
            let longueur = MemoryLayout<BokehUniforms>.stride
            encodeur.setVertexBytes(&couche.uniformes, length: longueur, index: 3)
            encodeur.setFragmentBytes(&couche.uniformes, length: longueur, index: 0)

            encodeur.drawPrimitives(type: .point,
                                    vertexStart: 0,
                                    vertexCount: couche.nombre)
        }
    }

    // MARK: Mise à jour des uniformes

    /// Recalcule les uniformes des trois couches. `fondu` est la fraction du chemin
    /// parcourue vers les valeurs cibles à cette trame ; il reste un paramètre plutôt
    /// qu'une constante parce qu'il est dérivé de la CADENCE réelle et non du nombre
    /// de trames — passer 1 poserait les cibles d'un coup, ce qu'aucun appelant ne
    /// demande aujourd'hui.
    private func majCouches(temps tempsScene: Float,
                            aspect: Float,
                            pixelRatio: Float,
                            fondu: Float) {
        let k = min(max(intensite, 0), 1)
        let p = lens.bokeh

        // Dérive lente de la caméra : une scène rigoureusement immobile paraît morte
        // même quand les particules bougent, parce que la parallaxe est ce qui donne
        // le volume. Valeurs du site.
        let oeil = SIMD3<Float>(sin(tempsScene * 0.13) * 0.35,
                                cos(tempsScene * 0.09) * 0.22,
                                6)
        let vue = BokehRenderer.matriceRegard(oeil: oeil,
                                              cible: SIMD3<Float>(0, 0, -3),
                                              haut: SIMD3<Float>(0, 1, 0))
        // La matrice modèle est l'identité : la profondeur est déjà portée par les
        // positions. Introduire une transformation par couche déplacerait les plans
        // les uns par rapport aux autres et casserait la répartition d'origine.
        let projection = BokehRenderer.matricePerspective(
            fovY: 50 * Float.pi / 180, aspect: aspect, proche: 0.1, lointain: 2000)

        for (index, couche) in couches.enumerated() {
            var u = couche.uniformes
            u.modelView = vue
            u.projection = projection
            u.time = tempsScene
            u.pixelRatio = pixelRatio

            u.size = BokehRenderer.vers(u.size,
                                        p.size * (0.35 + 0.65 * k) * couche.facteurTaille,
                                        fondu)
            u.swirl = BokehRenderer.vers(u.swirl, p.swirl * k * couche.facteurVitesse, fondu)
            u.rise = BokehRenderer.vers(u.rise, p.rise * k * couche.facteurVitesse, fondu)
            u.pan = BokehRenderer.vers(u.pan, p.pan * k, fondu)
            u.twinkle = BokehRenderer.vers(u.twinkle, p.twinkle * k, fondu)
            // `ring` et `soft` ignorent `k` : voir `intensite`.
            u.ring = BokehRenderer.vers(u.ring, p.ring, fondu)
            u.soft = BokehRenderer.vers(u.soft, p.soft, fondu)
            u.rim = BokehRenderer.vers(u.rim, p.rim * k, fondu)
            u.fringe = BokehRenderer.vers(u.fringe, p.fringe * k, fondu)
            u.cat = BokehRenderer.vers(u.cat, p.cat * k, fondu)
            u.spike = BokehRenderer.vers(u.spike, p.spike * k, fondu)

            // Respiration du halo, déphasée par couche : une présence qui enfle et
            // retombe, réservée aux optiques à glow (Biotar, Noctilux, Dream Lens).
            let respiration = lens.breathe
                ? 0.8 + 0.2 * sin(tempsScene * 0.7 + Float(index) * 1.1)
                : 1
            // Plafond à 0,52 par construction (0.1 + 0.42). Volontairement en deçà
            // de 1 : en fusion additive, des disques qui se recouvrent saturent vite
            // en blanc, et c'est cette réserve qui garde la COULEUR du bokeh. Monter
            // cette valeur donne une bouillie lumineuse, pas une scène plus lumineuse.
            let cible = (0.1 + 0.42 * k) * respiration * p.opacity
            u.opacity = BokehRenderer.vers(u.opacity, cible, fondu)

            couche.uniformes = u
            majCouleurs(couche, fondu: fondu)
        }
    }

    /// Fondu des couleurs, particule par particule, directement dans le tampon
    /// partagé. 192 × 3 flottants au total : 2,3 Ko réécrits par trame, négligeable.
    ///
    /// Le GPU peut relire ce tampon pendant l'écriture (pas de triple tamponnage) :
    /// au pire une particule affiche pendant une trame une couleur intermédiaire
    /// entre deux pas d'un fondu de 5 % — soit un écart bien inférieur au bruit de
    /// quantification 8 bits. Le triple tamponnage coûterait trois allocations et une
    /// sémaphore pour corriger quelque chose d'invisible.
    private func majCouleurs(_ couche: CoucheGPU, fondu: Float) {
        let ecriture = couche.ecritureCouleurs
        for i in 0..<couche.nombre {
            let cible = couche.cibles[i]
            let o = i * 3
            ecriture[o] += (cible.x - ecriture[o]) * fondu
            ecriture[o + 1] += (cible.y - ecriture[o + 1]) * fondu
            ecriture[o + 2] += (cible.z - ecriture[o + 2]) * fondu
        }
    }

    /// Recalcule la couleur visée de chaque particule. Appelé au seul changement
    /// d'objectif — jamais dans la boucle de dessin, où l'analyse de chaînes
    /// hexadécimales allouerait.
    private func majCiblesCouleurs() {
        paletteLineaire = lens.palette.map(BokehRenderer.couleurLineaire)
        duoLineaire = lens.duo.map(BokehRenderer.couleurLineaire)

        for (index, couche) in couches.enumerated() {
            // La couche du milieu bascule sur `duo` quand l'objectif en déclare une.
            // Seul l'Angénieux le fait (ambre devant, cyan au milieu) : c'est ce
            // contraste chaud/froid entre deux plans qui fait le rendu ciné, et il
            // disparaîtrait si toutes les couches partageaient la même palette.
            let source = (index == 1 && !duoLineaire.isEmpty) ? duoLineaire : paletteLineaire
            guard !source.isEmpty else { continue }
            for i in 0..<couche.nombre {
                couche.cibles[i] = source[i % source.count]
            }
        }
    }

    // MARK: Utilitaires

    private static func vers(_ courant: Float, _ cible: Float, _ fondu: Float) -> Float {
        courant + (cible - courant) * fondu
    }

    /// Hex du catalogue → composantes LINÉAIRES.
    ///
    /// La conversion est celle de three.js (`SRGBToLinear`), et elle est délibérément
    /// suivie d'une écriture dans une cible non-sRGB : le site affiche des valeurs
    /// linéaires comme si elles étaient de l'sRGB, ce qui l'assombrit et le sature —
    /// et c'est ce rendu-là qui plaît. Corriger la chaîne colorimétrique donnerait
    /// des pastels délavés, exactement l'écart que l'auteur nomme « pas comme le site ».
    ///
    /// L'analyse hexadécimale est refaite ici plutôt que d'emprunter `Color(hex:)` du
    /// thème : celui-ci produit une `Color` SwiftUI, dont on ne peut pas ressortir les
    /// composantes de façon fiable, et surtout une `Color` a déjà subi la gestion de
    /// couleur du système — c'est-à-dire précisément ce qu'on veut éviter.
    private static func couleurLineaire(_ hex: String) -> SIMD3<Float> {
        var texte = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if texte.count == 3 {
            texte = texte.map { "\($0)\($0)" }.joined()
        }
        guard texte.count == 6, let valeur = UInt32(texte, radix: 16) else {
            // Gris moyen plutôt qu'un noir invisible : une couleur fausse se voit et
            // se corrige, une particule éteinte passe pour un bug de rendu.
            return SIMD3<Float>(repeating: 0.25)
        }
        return SIMD3<Float>(
            versLineaire(Float((valeur >> 16) & 0xFF) / 255),
            versLineaire(Float((valeur >> 8) & 0xFF) / 255),
            versLineaire(Float(valeur & 0xFF) / 255))
    }

    private static func versLineaire(_ c: Float) -> Float {
        if c < 0.04045 { return c * 0.0773993808 }
        return Float(pow(Double(c) * 0.9478672986 + 0.0521327014, 2.4))
    }

    /// Matrice de vue, écrite à la main : GLKit est obsolète et son `GLKMatrix4`
    /// suppose les conventions OpenGL, qui ne sont pas celles de Metal.
    private static func matriceRegard(oeil: SIMD3<Float>,
                                      cible: SIMD3<Float>,
                                      haut: SIMD3<Float>) -> simd_float4x4 {
        let avant = simd_normalize(cible - oeil)
        let droite = simd_normalize(simd_cross(avant, haut))
        let vertical = simd_cross(droite, avant)
        // Colonnes, pas lignes : simd est en colonne-majeure, comme MSL. L'axe avant
        // est nié parce que la caméra regarde vers les z négatifs.
        return simd_float4x4(columns: (
            SIMD4<Float>(droite.x, vertical.x, -avant.x, 0),
            SIMD4<Float>(droite.y, vertical.y, -avant.y, 0),
            SIMD4<Float>(droite.z, vertical.z, -avant.z, 0),
            SIMD4<Float>(-simd_dot(droite, oeil),
                         -simd_dot(vertical, oeil),
                         simd_dot(avant, oeil),
                         1)))
    }

    /// Projection perspective en profondeur [0, 1] — la convention Metal.
    ///
    /// La variante OpenGL (profondeur [-1, 1]) compile et tourne sans le moindre
    /// message, mais place la moitié de la scène derrière le plan proche de Metal :
    /// le découpage supprime alors une partie des particules. Ici la profondeur n'est
    /// ni testée ni écrite, mais le découpage, lui, s'applique toujours.
    private static func matricePerspective(fovY: Float,
                                           aspect: Float,
                                           proche: Float,
                                           lointain: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = aspect > 0 ? y / aspect : y
        let z = lointain / (proche - lointain)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * proche, 0)))
    }
}
