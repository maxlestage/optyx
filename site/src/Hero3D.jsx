// Héros React Three Fiber : chaque objectif a SA scène — sprites,
// mouvement, couches et ambiance propres — pilotée par `lens.three` :
//   sprite  : 'disc' | 'ring' | 'cross'   (bokeh, bulle, étoile à branches)
//   swirl   : vitesse de spirale          (Helios, Biotar)
//   rise    : les particules flottent     (Trioplan)
//   twinkle : scintillement rapide        (Noct-Nikkor, Summicron)
//   pan     : travelling latéral ciné     (Angénieux)
//   breathe : halo qui respire            (Noctilux, Dream Lens)
//   sun     : disque solaire doré         (Takumar)
//   duo     : second nuage à contre-teinte (orange/teal Angénieux)
// L'intensité k (0–1) module tout, comme dans l'app.
import { Component, useMemo, useRef } from 'react'
import { Canvas, useFrame } from '@react-three/fiber'
import * as THREE from 'three'

function makeSprite(kind) {
  const size = 128
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = size
  const ctx = canvas.getContext('2d')
  const c = size / 2
  if (kind === 'ring') {
    const grad = ctx.createRadialGradient(c, c, c * 0.55, c, c, c * 0.95)
    grad.addColorStop(0, 'rgba(255,255,255,0)')
    grad.addColorStop(0.55, 'rgba(255,255,255,0.95)')
    grad.addColorStop(1, 'rgba(255,255,255,0)')
    ctx.fillStyle = grad
    ctx.fillRect(0, 0, size, size)
  } else if (kind === 'cross') {
    // Étoile à quatre branches : le coma dompté du Noct-Nikkor.
    const grad = ctx.createRadialGradient(c, c, 0, c, c, c * 0.3)
    grad.addColorStop(0, 'rgba(255,255,255,1)')
    grad.addColorStop(1, 'rgba(255,255,255,0)')
    ctx.fillStyle = grad
    ctx.fillRect(0, 0, size, size)
    ctx.strokeStyle = 'rgba(255,255,255,0.85)'
    ctx.lineWidth = 3
    ctx.beginPath()
    ctx.moveTo(c, 6)
    ctx.lineTo(c, size - 6)
    ctx.moveTo(6, c)
    ctx.lineTo(size - 6, c)
    ctx.stroke()
  } else {
    const grad = ctx.createRadialGradient(c, c, 0, c, c, c)
    grad.addColorStop(0, 'rgba(255,255,255,1)')
    grad.addColorStop(0.5, 'rgba(255,255,255,0.55)')
    grad.addColorStop(1, 'rgba(255,255,255,0)')
    ctx.fillStyle = grad
    ctx.fillRect(0, 0, size, size)
  }
  const texture = new THREE.CanvasTexture(canvas)
  texture.needsUpdate = true
  return texture
}

function makeField(seedStart, count, spreadY = 0.72) {
  let seed = seedStart
  const rand = () => {
    seed = (seed * 16807) % 2147483647
    return (seed - 1) / 2147483646
  }
  const positions = new Float32Array(count * 3)
  for (let i = 0; i < count; i++) {
    const radius = 1.1 + rand() * 5.6
    const angle = rand() * Math.PI * 2
    positions[i * 3] = Math.cos(angle) * radius
    positions[i * 3 + 1] = Math.sin(angle) * radius * spreadY
    positions[i * 3 + 2] = -1.5 - rand() * 5
  }
  return positions
}

function colorsFor(palette, count) {
  const array = new Float32Array(count * 3)
  const color = new THREE.Color()
  for (let i = 0; i < count; i++) {
    color.set(palette[i % palette.length])
    array[i * 3] = color.r
    array[i * 3 + 1] = color.g
    array[i * 3 + 2] = color.b
  }
  return array
}

function Cloud({ config, k, layer }) {
  const points = useRef()
  const count = layer === 0 ? 220 : 140
  const positions = useMemo(
    () => makeField(layer === 0 ? 42 : 1337, count),
    [layer, count],
  )
  const palette =
    layer === 1 && config.duo ? config.duo : config.palette
  const colors = useMemo(() => colorsFor(palette, count), [palette, count])
  const texture = useMemo(() => makeSprite(config.sprite), [config.sprite])

  useFrame(({ clock }) => {
    const t = clock.elapsedTime
    const p = points.current
    if (!p) return
    const phase = layer * Math.PI * 0.7

    // Spirale : chaque couche tourne à sa vitesse — le fond se creuse.
    p.rotation.z =
      t * (0.1 + layer * 0.06) * (config.swirl ?? 0) * k

    // Bulles qui flottent : montée lente en boucle.
    if (config.rise) {
      p.position.y = (((t * 0.25 * k + layer * 1.7) % 3.4) + 3.4) % 3.4 - 1.7
    }

    // Travelling ciné : balayage latéral très lent.
    if (config.pan) {
      p.position.x = Math.sin(t * 0.1 + phase) * 0.9 * k
    }

    const material = p.material
    // Base : présence du bokeh selon l'intensité.
    let opacity = 0.3 + 0.5 * k
    // Respiration du halo (Noctilux, Dream Lens).
    if (config.breathe) {
      opacity *= 0.75 + 0.25 * Math.sin(t * 0.7 + phase)
    }
    // Scintillement rapide (Noct-Nikkor, Summicron).
    if (config.twinkle) {
      opacity *= 0.62 + 0.38 * Math.sin(t * 5.2 + phase * 3)
    }
    material.opacity = opacity
    material.size =
      (0.24 + (config.size ?? 0.5) * 0.95 * k) *
      (config.breathe ? 1 + 0.12 * Math.sin(t * 0.8 + phase) : 1)
  })

  return (
    <points ref={points}>
      <bufferGeometry>
        <bufferAttribute attach="attributes-position" args={[positions, 3]} />
        <bufferAttribute attach="attributes-color" args={[colors, 3]} />
      </bufferGeometry>
      <pointsMaterial
        map={texture}
        vertexColors
        transparent
        depthWrite={false}
        blending={THREE.AdditiveBlending}
        sizeAttenuation
      />
    </points>
  )
}

/** Disque solaire doré du Takumar, qui palpite doucement. */
function Sun({ k }) {
  const mesh = useRef()
  const texture = useMemo(() => makeSprite('disc'), [])
  useFrame(({ clock }) => {
    const t = clock.elapsedTime
    if (mesh.current) {
      const scale = (2.6 + Math.sin(t * 0.5) * 0.25) * (0.4 + 0.6 * k)
      mesh.current.scale.setScalar(scale)
      mesh.current.material.opacity = 0.5 * k
    }
  })
  return (
    <sprite ref={mesh} position={[1.9, 1.1, -3]}>
      <spriteMaterial
        map={texture}
        color="#ffce7a"
        transparent
        depthWrite={false}
        blending={THREE.AdditiveBlending}
      />
    </sprite>
  )
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
          <Cloud config={config} k={k} layer={0} />
          <Cloud config={config} k={k} layer={1} />
          {config.sun ? <Sun k={k} /> : null}
        </Canvas>
      </CanvasBoundary>
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
