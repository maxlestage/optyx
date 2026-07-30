import { useState } from 'react'
import { lenses } from './lenses.js'
import Scene from './Scene.jsx'
import Hero3D from './Hero3D.jsx'

function TraitBar({ label, value }) {
  return (
    <div className="trait">
      <span className="trait-label">{label}</span>
      <span className="trait-track">
        <span className="trait-fill" style={{ width: `${value * 100}%` }} />
      </span>
    </div>
  )
}

function LensCard({ lens, index }) {
  return (
    <article className="card" id={lens.id} style={{ '--accent': lens.accent }}>
      <div className="card-scene">
        <Scene kind={lens.scene} />
        <span className="card-index">{String(index + 1).padStart(2, '0')}</span>
        <div className="card-title">
          <h3>{lens.name}</h3>
          <p>{lens.focal}</p>
        </div>
      </div>
      <div className="card-body">
        <p className="card-signature">{lens.signature}</p>
        <p className="card-meta">
          <span>{lens.origin}</span>
          <span>{lens.era}</span>
        </p>
        <p className="card-story">{lens.story}</p>
        <div className="card-traits">
          {lens.traits.map(([label, value]) => (
            <TraitBar key={label} label={label} value={value} />
          ))}
        </div>
      </div>
    </article>
  )
}

/// Lien profond : ?lens=trioplan ouvre le terrain de jeu sur cet objectif.
function initialLens() {
  const wanted = new URLSearchParams(window.location.search).get('lens')
  const index = lenses.findIndex((lens) => lens.id === wanted)
  return index >= 0 ? index : 0
}

export default function App() {
  const [selected, setSelected] = useState(initialLens)
  const [intensity, setIntensity] = useState(100)
  const lens = lenses[selected]
  const k = intensity / 100

  return (
    <>
      <header className="hero">
        <p className="brand">Optyx</p>
        <h1>
          Les objectifs <span className="accent">légendaires.</span>
          <br />
          Dans votre poche.
        </h1>
        <p className="tagline">
          9 verres mythiques simulés en temps réel dans votre iPhone, en photo
          comme en vidéo. Essayez leur caractère ici même :
        </p>
      </header>

      <section className="playground" style={{ '--accent': lens.accent }}>
        <Hero3D lens={lens} k={k} />
        <div className="playground-caption">
          <h2>{lens.name}</h2>
          <p>{lens.signature}</p>
        </div>
        <nav className="chips" aria-label="Choisir un objectif">
          {lenses.map((entry, i) => (
            <button
              key={entry.id}
              className={`chip${i === selected ? ' on' : ''}`}
              onClick={() => setSelected(i)}
            >
              {entry.name}
            </button>
          ))}
        </nav>
        <label className="intensity">
          <input
            type="range"
            min="0"
            max="100"
            value={intensity}
            onChange={(event) => setIntensity(Number(event.target.value))}
            aria-label="Intensité de la simulation"
          />
          <span>{intensity} %</span>
        </label>
      </section>

      <main className="cards">
        {lenses.map((entry, i) => (
          <LensCard key={entry.id} lens={entry} index={i} />
        ))}
      </main>

      <section className="outro">
        <h2>
          Sans compte. Sans pub. <span className="accent">Sans collecte.</span>
        </h2>
        <p>
          Intensité réglable de 0 à 100 %, mode Profondeur (LiDAR), ProRAW,
          CinemaScope 2.39:1, et un Studio pour appliquer les objectifs à vos
          photos existantes.
        </p>
        <p className="cta">Bientôt sur l'App Store.</p>
      </section>

      <footer className="footer">
        <p>© 2026 Optyx — Objectifs vintage simulés.</p>
      </footer>
    </>
  )
}
