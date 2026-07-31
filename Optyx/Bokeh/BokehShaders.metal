#include <metal_stdlib>
using namespace metal;

// Portage LITTÉRAL du shader de points du site (site/src/Hero3D.jsx).
//
// Le site ne « simule » pas un objectif sur une image : il DESSINE des disques
// de bokeh. C'est pour cela qu'il est beau et que l'ancienne app ne l'était
// pas — appliquer un flou physiquement correct à une photo d'intérieur ne
// montre rien, alors qu'ici la signature de l'objectif EST l'image.
// Conséquence : toute « amélioration » physique de ces formules est une
// régression produit. Les constantes (0.18, 0.10, 4.0, 0.12, 4.5, 7.31,
// 120.0, 0.32, 0.64, 0.66, 0.94, 1.02, 0.90, 18.0) sont des choix esthétiques
// validés par l'auteur : aucune n'est à réajuster.
//
// PÉRIMÈTRE : ces fonctions servent aux scènes animées du CATALOGUE, et à
// elles seules. Le studio part d'une photo, que ce shader ne sait pas prendre
// en entrée : il la traite en Core Image (MoteurOptique). Ce
// qui fait converger les deux rendus n'est donc pas le code mais les
// paramètres — les mêmes valeurs de BokehParams pilotent ici bokehProfile()
// (soft, ring, rim, fringe, spike) et là-bas les filtres correspondants. Toute
// retouche esthétique faite ici sans son pendant côté studio rouvre l'écart
// que l'auteur nomme « ce n'est pas comme le site ».

constant float TAU = 6.2831853f;

// Index de buffers. Vertex et fragment sont deux espaces de noms DISTINCTS :
// le même bloc d'uniformes doit être attaché des deux côtés
// (setVertexBytes ET setFragmentBytes), à des index DIFFÉRENTS. N'en oublier
// qu'un donne des uniformes à zéro d'un seul côté — sprites invisibles, ou
// disques uniformément noirs, sans la moindre erreur au runtime.
//
// Les attributs de particule occupent TROIS tampons séparés et non un seul
// tableau entrelacé : le CPU réécrit les couleurs en place à chaque trame
// (fondu vers la palette de l'objectif) alors que positions et phases sont
// figées à la construction. Entrelacer forcerait à réécrire 28 octets par
// particule pour n'en changer que 12, et surtout à toucher des octets que le
// GPU lit au même instant.
//
// Ces index sont le CONTRAT avec encoderCouches() du renderer. Un décalage ne
// produit aucune erreur de compilation : le shader lirait ses uniformes dans
// le tampon de couleurs et parcourrait les positions avec le mauvais pas.
constant int kBufPositions  = 0;   // vertex   : packed_float3 par particule
constant int kBufCouleurs   = 1;   // vertex   : packed_float3 par particule
constant int kBufPhases     = 2;   // vertex   : float par particule
constant int kBufUniformesV = 3;   // vertex   : BokehUniforms
constant int kBufUniformesF = 0;   // fragment : le MÊME BokehUniforms

// ---------------------------------------------------------------------------
// Uniformes
// ---------------------------------------------------------------------------

// ORDRE DES CHAMPS : strictement identique à la struct Swift du renderer.
// Un décalage d'un seul champ ne produit ni erreur de compilation ni message
// au runtime : juste une image absurde (des disques figés, ou rien du tout),
// impossible à diagnostiquer à l'œil. Ne jamais insérer, retirer ni permuter
// un champ ici sans faire exactement la même chose côté Swift.
//
// Disposition mémoire : les DEUX matrices en tête (2 × 64 = 128 octets, et
// float4x4 s'aligne sur 16 des deux côtés), puis 14 float = 56 octets, puis
// deux mots de remplissage EXPLICITES qui portent le total de 184 à 192 — la
// valeur que l'alignement 16 donne de toute façon au stride. Sans eux,
// MemoryLayout.size (184) et .stride (192) diffèrent côté Swift et il faut
// choisir lequel transmettre ; les figer supprime le choix. Placer un scalaire
// AVANT les matrices introduirait un bourrage que les compilateurs MSL et
// Swift ne sont pas tenus de calculer pareil.
// Côté Swift, toujours transmettre MemoryLayout<BokehUniforms>.stride.
//
// Contrairement à three.js, qui injecte modelViewMatrix et projectionMatrix
// gratuitement dans tout ShaderMaterial, Metal n'injecte AUCUNE matrice :
// les deux sont construites côté Swift. Elles restent SÉPARÉES et non
// pré-multipliées en une « mvp » : l'atténuation de taille en perspective
// (120 / −z_vue) a besoin de la profondeur en espace vue, qu'une matrice
// combinée rendrait inaccessible — les trois couches sortiraient à la même
// taille de sprite et le relief disparaîtrait.
// La projection doit être en profondeur [0,1] — convention Metal — et non
// [-1,1] comme en OpenGL : une matrice de style GL placerait la moitié de la
// scène derrière le plan proche et la ferait clipper silencieusement.
struct BokehUniforms {
    float4x4 modelView;
    float4x4 projection;

    float time;        // s, croît sans borne — TOUJOURS replié par wrapTau()
    float size;        // [0.046, 1.80]  échelle des sprites
    float pixelRatio;  // [1, 3]  point_size est en pixels PHYSIQUES
    float swirl;       // [0, 1.15]
    float rise;        // [0, 0.391] — < 0.001 désactive tout le terme
    float pan;         // [0, 0.55]
    float twinkle;     // [0, 0.45]
    float opacity;     // [0.08, 0.52] — plafond anti-saturation, ne pas monter
    float ring;        // {0, 1}  0 = disque plein, 1 = bulle de savon
    float rim;         // [0, 0.80]
    float soft;        // [0.10, 0.72]
    float fringe;      // [0, 0.075]
    float cat;         // [0, 0.62]
    float spike;       // [0, 0.55] — <= 0.001 court-circuite le calcul

    // Jamais lus par le shader : ils n'existent que pour que la taille écrite
    // ici soit exactement le stride que Swift transmet. Ne pas les recycler en
    // paramètres sans les ajouter au miroir Swift dans le même mouvement.
    float remplissage0;
    float remplissage1;
};

// ---------------------------------------------------------------------------
// Sommet
// ---------------------------------------------------------------------------

struct BokehVertexOut {
    float4 position  [[position]];

    // IMPÉRATIF. Metal n'a AUCUNE taille de point par défaut (pas
    // d'équivalent de glPointSize) : si la fonction vertex d'un pipeline
    // dessinant .point n'écrit pas point_size, la taille est INDÉFINIE — en
    // pratique 1 pixel, ou rien du tout. Le shader compile sans un seul
    // avertissement : c'est un écran noir parfaitement silencieux. Écrire
    // point_size sur TOUS les chemins de sortie, sans exception.
    float  pointSize [[point_size]];

    float3 color     [[user(vcolor)]];
    float2 ndc       [[user(vndc)]];
    float  fade      [[user(vfade)]];
};

// Structure d'entrée du fragment DISTINCTE de la sortie du vertex :
// [[point_size]] n'est pas un attribut d'entrée fragment valide, et réutiliser
// la même struct refuserait de compiler. Les [[user(...)]] apparient par NOM,
// jamais par ordre de déclaration.
struct BokehFragmentIn {
    float4 position [[position]];
    float3 color    [[user(vcolor)]];
    float2 ndc      [[user(vndc)]];
    float  fade     [[user(vfade)]];
};

// ---------------------------------------------------------------------------
// Fonctions partagées
// ---------------------------------------------------------------------------

// Réduction d'argument — correctif d'un BUG RÉEL constaté sur le site : après
// quelques minutes d'affichage, la scène se figeait ou virait au noir.
//
// Les trois angles du shader sont proportionnels au temps écoulé et croissent
// donc sans borne. Or sin/cos GPU ne sont pas les fonctions libm : leur
// réduction d'argument interne est à précision limitée. Passé quelques
// milliers de radians l'angle se quantifie (le scintillement devient un
// stroboscope), puis devient constant — scène figée ; certains pilotes
// renvoient carrément NaN, qui se propage dans fade puis dans la couleur —
// écran noir. Replier dans [0, 2π) AVANT l'appel trigonométrique borne la
// précision de l'angle pour toujours.
//
// En Metal c'est encore plus nécessaire qu'en WebGL : le fast-math est actif
// par défaut, sin() se résout en fast::sin() dont la réduction d'argument est
// plus agressive encore. Corollaire : ne jamais typer le temps ni les angles
// en half — un half sature à 65504 et perd toute résolution fractionnaire dès
// quelques centaines.
static inline float wrapTau(float x) {
    return fract(x / TAU) * TAU;
}

// MSL n'a pas mod(). fmod() est celui du C — troncature vers zéro — là où
// GLSL prend le plancher ; les deux diffèrent pour tout x négatif. Les
// arguments actuels sont tous positifs, donc fmod donnerait par chance le bon
// résultat : c'est exactement le genre d'équivalence fortuite qui casse le
// jour où l'on ajoute un décalage négatif. On fige la sémantique GLSL.
static inline float glslMod(float x, float y) {
    return x - y * floor(x / y);
}

// LE CŒUR DU PRODUIT : le profil d'un disque de bokeh. La même fonction, bit
// pour bit, sert au catalogue et au studio — c'est la réponse à « ce n'est pas
// comme le site ».
//
// body   : disque plein dont le bord est adouci sur la largeur `soft`.
//          soft → 0.10 donne le bord dur du Summicron, 0.72 le halo
//          évanescent du Dream Lens.
// hollow : rampe croissante qui VIDE le centre. ring = 1 → bulle de savon
//          (Trioplan), ring = 0 → disque plein.
// scale  : n'existe que pour la frange chromatique — trois évaluations à
//          trois échelles donnent trois disques concentriques (§ fragment).
//
// Le test r > 1 est redondant avec le smoothstep, qui sature déjà au-delà.
// On le garde pour la fidélité et parce qu'il protège le cas soft = 0, où
// smoothstep(1,1,r) devient une marche exacte : défini, mais fragile.
static inline float bokehProfile(float2 p, float scale, float ring, float soft) {
    float r = length(p) * scale;
    if (r > 1.0f) { return 0.0f; }
    float body   = 1.0f - smoothstep(1.0f - soft, 1.0f, r);
    float hollow = smoothstep(0.32f, 0.64f, r);
    return mix(body, body * hollow, ring);
}

// ---------------------------------------------------------------------------
// Vertex
// ---------------------------------------------------------------------------

// Un sommet = une particule. Les attributs sont lus par pointeur `device` +
// [[vertex_id]] plutôt que par [[stage_in]] : pas de MTLVertexDescriptor à
// tenir synchronisé, donc pas d'incohérence de format silencieuse.
//
// packed_float3 et non float3 : dans un tampon device, float3 est aligné sur
// 16 octets et en occupe donc 16. Les tampons du renderer sont tassés à 3
// Float (12 octets) par particule ; typer float3 ici ferait lire une particule
// sur quatre, à des positions aberrantes, et déborderait la longueur du tampon
// avant la fin du draw. Côté Swift il faut symétriquement trois Float séparés
// par vecteur, jamais un SIMD3<Float> (16 octets).
vertex BokehVertexOut bokehVertex(
    uint                       vid       [[vertex_id]],
    // Position monde, générée une fois par le MINSTD 16807.
    const device packed_float3 *positions [[buffer(kBufPositions)]],
    // Couleur courante, réécrite en place par le CPU à chaque trame (fondu
    // vers la palette de l'objectif) : c'est pour elle que les trois tampons
    // restent séparés.
    const device packed_float3 *couleurs  [[buffer(kBufCouleurs)]],
    // Graine par particule ∈ [0,1), fixe.
    const device float         *phases    [[buffer(kBufPhases)]],
    constant BokehUniforms&     u         [[buffer(kBufUniformesV)]])
{
    BokehVertexOut out;

    out.color    = float3(couleurs[vid]);
    float3 pos   = float3(positions[vid]);
    float  phase = phases[vid];

    // Rotation DIFFÉRENTIELLE : la vitesse angulaire croît avec le rayon
    // (0.18 + 0.10·r). C'est ce gradient, et non la rotation elle-même, qui
    // fait la différence entre « le champ tourne en bloc » (inintéressant) et
    // « le champ s'enroule » — le swirl de l'Helios.
    // radius est mesuré sur la position INITIALE : l'angle est donc une
    // fonction pure de (pos, time), sans intégration ni état. Ce shader est
    // stateless, condition pour que le studio soit reproductible.
    float radius = length(pos.xy);
    float angle  = wrapTau(u.swirl * u.time * (0.18f + 0.10f * radius));
    float c = cos(angle);
    float s = sin(angle);
    pos.xy = float2(pos.x * c - pos.y * s, pos.x * s + pos.y * c);

    // Montée des bulles : dent de scie de période 4 en y, déphasée par
    // particule pour qu'elles ne montent pas en rang.
    // Le step() annule TOUT le terme quand rise vaut 0 : sans lui,
    // glslMod(phase·4, 4) − 2 injecterait un décalage vertical statique dans
    // [-2, 2] qui détruirait la répartition elliptique soignée du générateur.
    pos.y += (glslMod(u.time * u.rise + phase * 4.0f, 4.0f) - 2.0f)
           * step(0.001f, u.rise);

    // Travelling latéral lent, déphasé par particule (rendu ciné Angénieux).
    pos.x += sin(wrapTau(u.time * 0.12f + phase * 2.0f)) * u.pan;

    // Deux étapes et non une matrice combinée : mv.z est la profondeur en
    // espace vue, dont l'atténuation de taille a besoin plus bas.
    float4 mv   = u.modelView * float4(pos, 1.0f);
    float4 proj = u.projection * mv;

    // Position du CENTRE du sprite dans le cadre : sert exclusivement à
    // orienter l'œil de chat. Le sprite n'ayant qu'un sommet, cette varying
    // est constante sur toute sa surface — l'interpolation est un
    // non-événement.
    // Cette division-ci reste sur proj.w, et non sur −mv.z : la division
    // homogène est la DÉFINITION du passage clip → NDC, valable pour toute
    // matrice de projection. C'est l'atténuation de taille, plus bas, qui
    // devait cesser de s'appuyer sur w.
    // Le max() sur w n'a aucun effet dans la scène (w ≈ 7…15) mais évite
    // qu'une particule passée derrière la caméra produise un inf, puis
    // off/lo = inf/inf = NaN dans le fragment : dans une cible additive, un
    // NaN contamine tout ce qui sera dessiné ensuite.
    float w = max(proj.w, 1e-4f);
    out.ndc = proj.xy / w;

    // Scintillement ∈ [1 − twinkle, 1], jamais négatif. Réservé aux optiques
    // piquées : ce sont les points fins qui vibrent, pas les grosses orbes.
    out.fade = 1.0f - u.twinkle
             * (0.5f + 0.5f * sin(wrapTau(u.time * 4.5f + phase * TAU)));

    // variety ∈ [0.65, 1.35]. Le facteur 7.31 décorrèle la taille de la phase
    // temporelle : sans lui, les grosses particules seraient exactement
    // celles qui montent en tête, et l'œil verrait la corrélation.
    float variety = 0.65f + 0.7f * fract(phase * 7.31f);

    // Atténuation perspective manuelle du site : 120 / (−z_vue). La grandeur
    // est lue sur mv.z, DIRECTEMENT. Passer par proj.w donnerait aujourd'hui
    // le même nombre — la dernière ligne de la projection vaut (0, 0, −1, 0) —
    // mais ce serait une coïncidence de la matrice courante, pas une identité :
    // toute retouche de matricePerspective (profondeur inversée, projection
    // hors-écran du studio) changerait silencieusement la taille des sprites,
    // et le studio cesserait de ressembler au catalogue. Le max() protège la
    // division pour une particule exactement au plan caméra.
    float px = u.size * u.pixelRatio * variety * (120.0f / max(0.001f, -mv.z));

    // 511 px est la taille de point maximale de toutes les familles de GPU
    // Apple ; au-delà le comportement est indéfini et le point peut
    // disparaître. Dans le catalogue le maximum réel est de ~118 px à 3×,
    // donc ce clamp est un garde-fou — mais il deviendrait un écrêtage
    // VISIBLE (grosses bulles bloquées, petites non : rupture d'échelle
    // immédiatement perceptible) si le studio dérivait pixelRatio de la
    // largeur absolue d'une photo. Ne pas le faire.
    out.pointSize = clamp(px, 1.0f, 511.0f);
    out.position  = proj;
    return out;
}

// ---------------------------------------------------------------------------
// Fragment
// ---------------------------------------------------------------------------

fragment float4 bokehFragment(
    BokehFragmentIn          in         [[stage_in]],
    // Remplace gl_PointCoord : origine en HAUT À GAUCHE du sprite, ∈ [0,1],
    // exactement la même convention qu'en GL ES.
    float2                   pointCoord [[point_coord]],
    constant BokehUniforms&  u          [[buffer(kBufUniformesF)]])
{
    float2 p = pointCoord * 2.0f - 1.0f;
    float  r = length(p);

    // Hors du disque inscrit. discard_fragment() ne rend pas la main,
    // contrairement au discard de GLSL : le flot continue et la fonction doit
    // malgré tout renvoyer une valeur — d'où le return explicite, qui n'est
    // pas une redondance.
    // L'alpha reste à 1 même ici : la cible est effacée à alpha 1 et doit le
    // rester quoi qu'il arrive.
    if (r > 1.0f) {
        discard_fragment();
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    // ŒIL DE CHAT : le disque est rogné par un SECOND cercle décalé dans la
    // direction de ndc. Plus la particule est excentrée, plus le rognage
    // mord et plus le disque devient une amande — signature des optiques très
    // ouvertes, et origine du tourbillon visuel.
    //
    // Le bornage est le correctif d'un BUG RÉEL : ndc n'est pas contraint à
    // [-1,1], et les particules débordent volontairement du cadre, donc
    // |ndc| ≫ 1 est courant. Sans bornage, off·cat s'éloigne arbitrairement,
    // cut dépasse 1.02 sur tout le sprite et cat tombe à 0 : le disque
    // DISPARAÎT entièrement. On voyait les bulles s'effacer en périphérie au
    // lieu de s'y étirer. Normaliser conserve la direction et plafonne la
    // norme à 1 : le rognage sature au lieu de tuer.
    //
    // Note d'axes, à ne surtout pas « corriger » : point_coord a son y vers le
    // BAS, ndc son y vers le HAUT. Le site mélange ces deux conventions
    // opposées, Metal a exactement la même paire, donc la traduction
    // littérale reproduit le rendu du site. Si un jour le studio différait du
    // catalogue en haut/bas, c'est ici qu'il faudrait chercher (projection
    // hors-écran à y inversé), pas dans une inversion ajoutée à la va-vite.
    float2 off = in.ndc;
    float  lo  = length(off);
    off = (lo > 1.0f) ? (off / lo) : off;
    float cut = length(p - off * u.cat);
    float cat = 1.0f - smoothstep(0.90f, 1.02f, cut);

    // Frange chromatique : le MÊME profil, trois échelles. scale < 1 agrandit
    // le disque (r = |p|·scale), donc le rouge déborde et le bleu rentre :
    // liseré magenta à l'extérieur, cyan à l'intérieur. L'ordre physique
    // dépendrait du signe de l'aberration longitudinale — ne pas le
    // « corriger », c'est ce rendu-là qui est validé. fringe ≤ 0.075 : c'est
    // subtil, et c'est voulu.
    float ir = bokehProfile(p, 1.0f - u.fringe, u.ring, u.soft);
    float ig = bokehProfile(p, 1.0f,            u.ring, u.soft);
    float ib = bokehProfile(p, 1.0f + u.fringe, u.ring, u.soft);

    // Liseré : l'aberration sphérique non corrigée concentre la lumière sur le
    // bord du disque. Cloche asymétrique culminant à r = 0.94, éteinte à
    // r = 1. Poussée à 0.80 sur le Trioplan, où l'anneau EST la bulle de savon.
    float rim = u.rim * smoothstep(0.66f, 0.94f, r)
              * (1.0f - smoothstep(0.94f, 1.0f, r));

    // Aigrettes de diffraction. SOMME et non produit des deux bandes : un
    // produit ne laisserait que leur intersection, c'est-à-dire un simple
    // point central au lieu d'une croix.
    // Le branchement est parfaitement cohérent — tous les fragments d'un draw
    // partagent la même valeur d'uniforme — donc aucune divergence à craindre.
    float spikes = 0.0f;
    if (u.spike > 0.001f) {
        float sx = max(0.0f, 1.0f - abs(p.x) * 18.0f);
        float sy = max(0.0f, 1.0f - abs(p.y) * 18.0f);
        spikes = u.spike * (sx + sy) * (1.0f - r);
    }

    // Liseré et aigrettes sont TEINTÉS par la couleur de la particule : du
    // blanc pur ferait basculer la scène en points lumineux génériques et lui
    // ferait perdre l'identité de l'objectif.
    float3 col = in.color * float3(ir, ig, ib) + in.color * (rim + spikes);
    col *= cat * u.opacity * in.fade;

    // ALPHA CONSTANT À 1, JAMAIS ACCUMULÉ. C'est ici que l'ancienne app s'est
    // noircie deux fois : additionner N contributions portant chacune alpha 1
    // donne alpha = N, et la composition suivante interprète le résultat comme
    // prémultiplié. La parade est structurelle et se joue à deux endroits :
    // ce 1.0 constant, et côté pipeline sourceAlphaBlendFactor = .zero /
    // destinationAlphaBlendFactor = .one, qui laisse l'alpha de la cible
    // strictement intact.
    return float4(col, 1.0f);
}
