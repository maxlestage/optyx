// Héros React Three Fiber : un champ de bokeh 3D dont le caractère
// change avec l'objectif sélectionné — tourbillon, bulles, halo, or…
// L'intensité (0–100 %) est le geste emblématique de l'app.
import { useMemo, useRef } from 'react'
import { Canvas, useFrame } from '@react-three/fiber'
import * as THREE from 'three'

const COUNT = 340

/** Texture disque doux ou anneau (bulle de savon), générée en canvas. */
function makeSprite(ring) {
  const size = 128
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = size
  const ctx = canvas.getContext('2d')
  const c = size / 2
  if (ring) {
    const grad = ctx.createRadialGradient(c, c, c * 0.55, c, c, c * 0.95)
    grad.addColorStop(0, 'rgba(255,255,255,0)')
    grad.addColorStop(0.55, 'rgba(255,255,255,0.95)')
    grad.addColorStop(1, 'rgba(255,255,255,0)')
    ctx.fillStyle = grad
    ctx.fillRect(0, 0, size, size)
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

/** Positions et phases aléatoires mais stables d'un rendu à l'autre. */
function makeField() {
  let seed = 42
  const rand = () => {
    seed = (seed * 16807) % 2147483647
    return (seed - 1) / 2147483646
  }
  const positions = new Float32Array(COUNT * 3)
  const phases = new Float32Array(COUNT)
  for (let i = 0; i < COUNT; i++) {
    const radius = 1.2 + rand() * 5.4
    const angle = rand() * Math.PI * 2
    positions[i * 3] = Math.cos(angle) * radius
    positions[i * 3 + 1] = Math.sin(angle) * radius * 0.72
    positions[i * 3 + 2] = -1.5 - rand() * 5
    phases[i] = rand() * Math.PI * 2
  }
  return { positions, phases }
}

function Bokeh({ config, k }) {
  const group = useRef()
  const discs = useRef()
  const { positions, phases } = useMemo(makeField, [])
  const discTexture = useMemo(() => makeSprite(false), [])
  const ringTexture = useMemo(() => makeSprite(true), [])

  const colors = useMemo(() => {
    const array = new Float32Array(COUNT * 3)
    const color = new THREE.Color()
    for (let i = 0; i < COUNT; i++) {
      color.set(config.palette[i % config.palette.length])
      array[i * 3] = color.r
      array[i * 3 + 1] = color.g
      array[i * 3 + 2] = color.b
    }
    return array
  }, [config])

  useFrame(({ clock }) => {
    const t = clock.elapsedTime
    // Tourbillon : le champ entier pivote, vitesse au caractère du verre.
    if (group.current) {
      group.current.rotation.z = t * 0.12 * config.swirl * k
    }
    // Respiration du halo : taille et présence pulsent doucement.
    if (discs.current) {
      const breathe = 1 + Math.sin(t * 0.8) * 0.12 * config.glow
      discs.current.material.size =
        (0.28 + config.size * 0.9 * k) * breathe
      discs.current.material.opacity =
        0.25 + (0.5 + 0.35 * Math.sin(t * 0.6)) * config.glow * k * 0.6
    }
  })

  return (
    <group ref={group}>
      <points ref={discs}>
        <bufferGeometry>
          <bufferAttribute attach="attributes-position" args={[positions, 3]} />
          <bufferAttribute attach="attributes-color" args={[colors, 3]} />
        </bufferGeometry>
        <pointsMaterial
          map={config.ring ? ringTexture : discTexture}
          vertexColors
          transparent
          depthWrite={false}
          blending={THREE.AdditiveBlending}
          sizeAttenuation
        />
      </points>
    </group>
  )
}

/// Sans WebGL (vieux navigateur, webview bridée), l'échec du Canvas ne
/// doit pas emporter tout le site : repli sur le fond statique.
import { Component } from 'react'
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
  return (
    <div className="hero3d" style={{ '--haze': lens.three.haze * k }}>
      <CanvasBoundary>
        <Canvas
          dpr={[1, 2]}
          camera={{ position: [0, 0, 6], fov: 50 }}
          gl={{ antialias: false, alpha: true, powerPreference: 'low-power' }}
        >
          <Bokeh config={lens.three} k={k} />
        </Canvas>
      </CanvasBoundary>
      <div className="hero3d-haze" />
      <div className="hero3d-vignette" />
    </div>
  )
}
