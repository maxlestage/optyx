// Héros React Three Fiber : un vrai bokeh d'objectif, rendu par shader.
//
// Chaque particule n'est pas un rond flou mais un disque de bokeh avec
// ses traits optiques : liseré plus lumineux au bord (aberration
// sphérique), frange chromatique, et surtout ŒIL DE CHAT — le disque
// rogné en amande vers les coins du cadre, exactement ce que produit
// une optique très ouverte, et ce qui donne naissance au tourbillon.
//
// Le mouvement vit aussi dans le shader : rotation DIFFÉRENTIELLE (les
// bords tournent plus vite que le centre, comme un vrai swirl), montée
// des bulles par particule, travelling ciné. Trois couches de
// profondeur donnent le relief, et tout se fond en douceur d'un
// objectif à l'autre.
import { Component, useMemo, useRef } from 'react'
import { Canvas, useFrame } from '@react-three/fiber'
import * as THREE from 'three'

const VERTEX = /* glsl */ `
  attribute vec3 aColor;
  attribute float aPhase;

  uniform float uTime;
  uniform float uSize;
  uniform float uPixelRatio;
  uniform float uSwirl;
  uniform float uRise;
  uniform float uPan;
  uniform float uTwinkle;

  varying vec3 vColor;
  varying vec2 vNdc;
  varying float vFade;

  const float TAU = 6.2831853;

  // Réduction d'argument maison : sur GPU, sin() et cos() perdent toute
  // précision — voire renvoient n'importe quoi — passé quelques
  // milliers de radians. Or l'angle de rotation croît avec le temps :
  // sans ce repli dans [0, 2π), l'animation se fige ou s'efface après
  // quelques minutes d'affichage.
  float wrap(float x) {
    return fract(x / TAU) * TAU;
  }

  void main() {
    vColor = aColor;
    vec3 pos = position;

    // Rotation différentielle : l'amplitude croît avec le rayon — le
    // champ s'enroule au lieu de tourner en bloc.
    float radius = length(pos.xy);
    float angle = wrap(uSwirl * uTime * (0.18 + 0.10 * radius));
    float c = cos(angle);
    float s = sin(angle);
    pos.xy = vec2(pos.x * c - pos.y * s, pos.x * s + pos.y * c);

    // Bulles : chaque particule monte à son propre rythme et reboucle.
    // Réservé aux profils qui montent — ailleurs, ce décalage ne ferait
    // que déséquilibrer la répartition d'origine.
    pos.y += (mod(uTime * uRise + aPhase * 4.0, 4.0) - 2.0) * step(0.001, uRise);

    // Travelling latéral (rendu ciné).
    pos.x += sin(wrap(uTime * 0.12 + aPhase * 2.0)) * uPan;

    vec4 mv = modelViewMatrix * vec4(pos, 1.0);
    vec4 proj = projectionMatrix * mv;

    // Position à l'écran (-1…1) : sert à l'œil de chat, qui dépend de
    // la distance au centre du cadre.
    vNdc = proj.xy / proj.w;

    // Scintillement : les points fins vibrent, les grosses orbes non.
    vFade = 1.0 - uTwinkle * (0.5 + 0.5 * sin(wrap(uTime * 4.5 + aPhase * TAU)));

    // Taille : variée par particule, atténuée par la distance.
    float variety = 0.65 + 0.7 * fract(aPhase * 7.31);
    gl_PointSize = uSize * uPixelRatio * variety * (120.0 / max(0.001, -mv.z));
    gl_Position = proj;
  }
`

const FRAGMENT = /* glsl */ `
  precision highp float;

  uniform float uOpacity;
  uniform float uRing;    // 0 = disque plein, 1 = bulle de savon
  uniform float uRim;     // liseré lumineux du bord
  uniform float uSoft;    // douceur du bord
  uniform float uFringe;  // frange chromatique
  uniform float uCat;     // œil de chat vers les coins
  uniform float uSpike;   // aigrettes d'étoile

  varying vec3 vColor;
  varying vec2 vNdc;
  varying float vFade;

  // Profil d'un disque de bokeh, évalué à une échelle donnée (c'est en
  // faisant varier cette échelle par canal qu'on obtient la frange).
  float bokeh(vec2 p, float scale, float ring, float soft) {
    float r = length(p) * scale;
    if (r > 1.0) return 0.0;
    float body = 1.0 - smoothstep(1.0 - soft, 1.0, r);
    float hollow = smoothstep(0.32, 0.64, r);
    return mix(body, body * hollow, ring);
  }

  void main() {
    vec2 p = gl_PointCoord * 2.0 - 1.0;
    float r = length(p);
    if (r > 1.0) discard;

    // ŒIL DE CHAT : le disque est rogné par un second cercle décalé
    // vers le centre du cadre — plus la particule est excentrée, plus
    // elle prend la forme d'une amande. Signature des optiques rapides.
    // Le décalage est BORNÉ : au-delà du cadre, vNdc dépasse 1 et
    // rognerait les disques jusqu'à les effacer.
    vec2 off = vNdc;
    float lo = length(off);
    off = lo > 1.0 ? off / lo : off;
    float cut = length(p - off * uCat);
    float cat = 1.0 - smoothstep(0.90, 1.02, cut);

    float ir = bokeh(p, 1.0 - uFringe, uRing, uSoft);
    float ig = bokeh(p, 1.0, uRing, uSoft);
    float ib = bokeh(p, 1.0 + uFringe, uRing, uSoft);

    // Liseré : l'aberration sphérique concentre la lumière sur le bord.
    float rim = uRim * smoothstep(0.66, 0.94, r) * (1.0 - smoothstep(0.94, 1.0, r));

    // Aigrettes de diffraction (étoiles).
    float spikes = 0.0;
    if (uSpike > 0.001) {
      float sx = max(0.0, 1.0 - abs(p.x) * 18.0);
      float sy = max(0.0, 1.0 - abs(p.y) * 18.0);
      spikes = uSpike * (sx + sy) * (1.0 - r);
    }

    vec3 col = vColor * vec3(ir, ig, ib) + vColor * (rim + spikes);
    col *= cat * uOpacity * vFade;
    gl_FragColor = vec4(col, 1.0);
  }
`

// Trois plans de profondeur : le premier gros et lent, le dernier fin
// et lointain — c'est ce décalage qui donne le relief.
const LAYERS = [
  { count: 24, near: 1.4, far: 2.8, size: 1.5, speed: 1.15 },
  { count: 58, near: 2.8, far: 4.8, size: 0.95, speed: 0.85 },
  { count: 110, near: 4.8, far: 7.5, size: 0.55, speed: 0.6 },
]

function makeGeometryData(layer, seedStart) {
  let seed = seedStart
  const rand = () => {
    seed = (seed * 16807) % 2147483647
    return (seed - 1) / 2147483646
  }
  const { count, near, far } = layer
  const positions = new Float32Array(count * 3)
  const phases = new Float32Array(count)
  for (let i = 0; i < count; i++) {
    // Racine carrée : répartition uniforme sur le disque, pas d'amas
    // au centre.
    const radius = 0.5 + Math.sqrt(rand()) * 4.2
    const angle = rand() * Math.PI * 2
    // Ellipse large : le cadre du héros l'est aussi — un disque rond
    // laisserait le haut et le bas vides, et déborderait sur les côtés.
    positions[i * 3] = Math.cos(angle) * radius * 1.25
    positions[i * 3 + 1] = Math.sin(angle) * radius * 0.55
    positions[i * 3 + 2] = -(near + rand() * (far - near))
    phases[i] = rand()
  }
  return { positions, phases }
}

const lerp = (a, b, t) => a + (b - a) * t

function Layer({ config, k, index }) {
  const layer = LAYERS[index]
  const geometry = useRef()
  const material = useRef()
  const { positions, phases } = useMemo(
    () => makeGeometryData(layer, 1000 + index * 977),
    [layer, index],
  )

  // Couleurs courantes (fondues vers la palette de l'objectif choisi).
  const colors = useMemo(
    () => new Float32Array(layer.count * 3),
    [layer.count],
  )
  const target = useMemo(() => new THREE.Color(), [])

  const uniforms = useMemo(
    () => ({
      uTime: { value: 0 },
      uSize: { value: 0 },
      uPixelRatio: { value: Math.min(2, window.devicePixelRatio || 1) },
      uSwirl: { value: 0 },
      uRise: { value: 0 },
      uPan: { value: 0 },
      uTwinkle: { value: 0 },
      uOpacity: { value: 0 },
      uRing: { value: 0 },
      uRim: { value: 0 },
      uSoft: { value: 0.5 },
      uFringe: { value: 0 },
      uCat: { value: 0 },
      uSpike: { value: 0 },
    }),
    [],
  )

  useFrame(({ clock }, delta) => {
    const t = clock.elapsedTime
    const u = uniforms
    u.uTime.value = t

    // Fondu doux vers les valeurs de l'objectif courant : changer de
    // puce fait MORPHER la scène au lieu de la remplacer.
    const ease = Math.min(1, delta * 3.2)
    const palette = index === 1 && config.duo ? config.duo : config.palette

    u.uSize.value = lerp(
      u.uSize.value,
      (config.size ?? 0.5) * (0.35 + 0.65 * k) * layer.size,
      ease,
    )
    u.uSwirl.value = lerp(u.uSwirl.value, (config.swirl ?? 0) * k * layer.speed, ease)
    u.uRise.value = lerp(u.uRise.value, (config.rise ?? 0) * k * layer.speed, ease)
    u.uPan.value = lerp(u.uPan.value, (config.pan ?? 0) * k, ease)
    u.uTwinkle.value = lerp(u.uTwinkle.value, (config.twinkle ?? 0) * k, ease)
    u.uRing.value = lerp(u.uRing.value, config.ring ?? 0, ease)
    u.uRim.value = lerp(u.uRim.value, (config.rim ?? 0.25) * k, ease)
    u.uSoft.value = lerp(u.uSoft.value, config.soft ?? 0.35, ease)
    u.uFringe.value = lerp(u.uFringe.value, (config.fringe ?? 0.04) * k, ease)
    u.uCat.value = lerp(u.uCat.value, (config.cat ?? 0.35) * k, ease)
    u.uSpike.value = lerp(u.uSpike.value, (config.spike ?? 0) * k, ease)

    // Respiration du halo : présence qui enfle et retombe.
    const breathe = config.breathe
      ? 0.8 + 0.2 * Math.sin(t * 0.7 + index * 1.1)
      : 1
    // Volontairement en deçà de 1 : en fusion additive, des disques qui
    // se recouvrent saturent vite en blanc — c'est cette réserve qui
    // garde la couleur du bokeh.
    u.uOpacity.value = lerp(u.uOpacity.value, (0.1 + 0.42 * k) * breathe, ease)

    // Fondu des couleurs particule par particule.
    const attribute = geometry.current?.getAttribute('aColor')
    if (attribute) {
      const array = attribute.array
      for (let i = 0; i < layer.count; i++) {
        target.set(palette[i % palette.length])
        const o = i * 3
        array[o] = lerp(array[o], target.r, ease)
        array[o + 1] = lerp(array[o + 1], target.g, ease)
        array[o + 2] = lerp(array[o + 2], target.b, ease)
      }
      attribute.needsUpdate = true
    }
  })

  return (
    <points>
      <bufferGeometry ref={geometry}>
        <bufferAttribute attach="attributes-position" args={[positions, 3]} />
        <bufferAttribute attach="attributes-aColor" args={[colors, 3]} />
        <bufferAttribute attach="attributes-aPhase" args={[phases, 1]} />
      </bufferGeometry>
      <shaderMaterial
        ref={material}
        uniforms={uniforms}
        vertexShader={VERTEX}
        fragmentShader={FRAGMENT}
        transparent
        depthWrite={false}
        blending={THREE.AdditiveBlending}
      />
    </points>
  )
}

/** Dérive lente de la caméra : la scène respire, jamais figée. */
function Drift() {
  useFrame(({ clock, camera }) => {
    const t = clock.elapsedTime
    camera.position.x = Math.sin(t * 0.13) * 0.35
    camera.position.y = Math.cos(t * 0.09) * 0.22
    camera.lookAt(0, 0, -3)
  })
  return null
}

class CanvasBoundary extends Component {
  state = { failed: false }
  static getDerivedStateFromError() {
    return { failed: true }
  }
  render() {
    return this.state.failed ? null : this.props.children
  }
}

export default function Hero3D({ lens, k }) {
  const config = lens.three
  return (
    <div className="hero3d" style={{ '--haze': (config.haze ?? 0) * k }}>
      <CanvasBoundary>
        <Canvas
          dpr={[1, 2]}
          camera={{ position: [0, 0, 6], fov: 50 }}
          gl={{ antialias: false, alpha: true, powerPreference: 'low-power' }}
        >
          <Drift />
          {LAYERS.map((_, index) => (
            <Layer key={index} config={config} k={k} index={index} />
          ))}
        </Canvas>
      </CanvasBoundary>
      {config.sun ? <span className="hero3d-sun" /> : null}
      <div className="hero3d-haze" />
      <div className="hero3d-vignette" />
      {config.bars ? (
        <>
          <span className="hero3d-bar top" />
          <span className="hero3d-bar bottom" />
        </>
      ) : null}
      {config.grain ? <span className="hero3d-grain" /> : null}
    </div>
  )
}
