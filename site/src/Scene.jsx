// Scènes bokeh en pur CSS/SVG — même esthétique que les visuels App
// Store, sans aucune image à charger.

/** Générateur pseudo-aléatoire déterministe : mêmes scènes à chaque rendu. */
function rng(seed) {
  let s = seed
  return () => {
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  }
}

function Dots({ seed, count, palette, blur = 10, min = 12, max = 34 }) {
  const rand = rng(seed)
  const dots = Array.from({ length: count }, (_, i) => ({
    left: rand() * 100,
    top: rand() * 100,
    size: min + rand() * (max - min),
    color: palette[i % palette.length],
    opacity: 0.45 + rand() * 0.5,
  }))
  return dots.map((d, i) => (
    <span
      key={i}
      className="dot"
      style={{
        left: `${d.left}%`,
        top: `${d.top}%`,
        width: `${d.size}%`,
        color: d.color,
        opacity: d.opacity,
        filter: `blur(${blur}px)`,
      }}
    />
  ))
}

function Arcs({ seed, count, palette, thick = 3 }) {
  const rand = rng(seed)
  return Array.from({ length: count }, (_, i) => {
    const radius = 18 + rand() * 38
    const start = rand() * 360
    const sweep = 30 + rand() * 60
    return (
      <span
        key={i}
        className="arc"
        style={{
          width: `${radius * 2}%`,
          height: `${radius * 2}%`,
          borderWidth: `${thick}px`,
          borderTopColor: palette[i % palette.length],
          opacity: 0.35 + rand() * 0.45,
          transform: `translate(-50%, -50%) rotate(${start}deg)`,
          '--sweep': `${sweep}deg`,
        }}
      />
    )
  })
}

function Rings({ seed, count, color }) {
  const rand = rng(seed)
  return Array.from({ length: count }, (_, i) => {
    const size = 8 + rand() * 22
    return (
      <span
        key={i}
        className="ring"
        style={{
          left: `${rand() * 92}%`,
          top: `${rand() * 88}%`,
          width: `${size}%`,
          borderColor: color,
          opacity: 0.35 + rand() * 0.55,
        }}
      />
    )
  })
}

const SCENES = {
  swirl: (
    <div className="scene" style={{ background: 'radial-gradient(80% 80% at 50% 45%, #232d14 0%, #10140a 60%, #060704 100%)' }}>
      <Dots seed={11} count={5} palette={['#d7f0a4', '#f0e0a0']} blur={8} min={10} max={22} />
      <Arcs seed={12} count={14} palette={['#cfe89a', '#f0d494', '#a8c877']} />
    </div>
  ),
  'swirl-soft': (
    <div className="scene" style={{ background: 'radial-gradient(80% 80% at 50% 45%, #1c241e 0%, #0e120f 60%, #050605 100%)' }}>
      <Dots seed={21} count={4} palette={['#d4e8d8', '#e8e4cc']} blur={10} min={10} max={20} />
      <Arcs seed={22} count={10} palette={['#c2d8c8', '#e0dcc4']} thick={2} />
    </div>
  ),
  bubbles: (
    <div className="scene" style={{ background: 'radial-gradient(85% 85% at 50% 42%, #241708 0%, #120b04 60%, #070402 100%)' }}>
      <Dots seed={31} count={3} palette={['#f0c070']} blur={16} min={16} max={30} />
      <Rings seed={32} count={12} color="#f4e2b8" />
    </div>
  ),
  crisp: (
    <div className="scene" style={{ background: 'linear-gradient(165deg, #26241f 0%, #131210 55%, #080807 100%)' }}>
      <Dots seed={41} count={16} palette={['#f0ede4', '#ffe0aa', '#c2d4ec']} blur={1} min={3} max={8} />
    </div>
  ),
  night: (
    <div className="scene" style={{ background: 'radial-gradient(85% 85% at 50% 40%, #111527 0%, #090a14 60%, #030304 100%)' }}>
      <Dots seed={51} count={7} palette={['#ffdc96', '#ffc06e', '#b4c8ff']} blur={4} min={5} max={11} />
      <Dots seed={52} count={7} palette={['#ffe4b0']} blur={22} min={14} max={30} />
      <div className="vignette" />
    </div>
  ),
  dream: (
    <div className="scene" style={{ background: 'radial-gradient(95% 85% at 50% 42%, #3c3432 0%, #201a19 60%, #0d0b0a 100%)' }}>
      <Dots seed={61} count={9} palette={['#ffeed6', '#ffd8e4', '#dee4ff']} blur={26} min={20} max={44} />
      <div className="haze" />
    </div>
  ),
  gold: (
    <div className="scene" style={{ background: 'linear-gradient(160deg, #3e2708 0%, #261605 55%, #100902 100%)' }}>
      <Dots seed={71} count={9} palette={['#ffcb6e', '#ffab46', '#ffe4a0']} blur={14} min={10} max={26} />
      <span className="sun" />
    </div>
  ),
  stars: (
    <div className="scene" style={{ background: 'radial-gradient(90% 90% at 50% 38%, #0e1220 0%, #07080f 60%, #020203 100%)' }}>
      <Dots seed={81} count={22} palette={['#f4f4fa', '#ffe4aa', '#aec6ff']} blur={0.5} min={1.5} max={4} />
    </div>
  ),
  cine: (
    <div className="scene" style={{ background: 'linear-gradient(165deg, #2e2216 0%, #1c1c18 45%, #0e1412 100%)' }}>
      <Dots seed={91} count={7} palette={['#ffbe78', '#78bebe', '#ffe0b4']} blur={14} min={12} max={28} />
      <span className="bar top" />
      <span className="bar bottom" />
      <span className="grain" />
    </div>
  ),
}

export default function Scene({ kind }) {
  return SCENES[kind] ?? SCENES.crisp
}
