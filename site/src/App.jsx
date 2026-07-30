import { lenses } from './lenses.js'
import Scene from './Scene.jsx'

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

export default function App() {
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
          9 verres mythiques simulés en temps réel dans votre iPhone,
          en photo comme en vidéo. Le sujet reste net grâce au LiDAR,
          l'arrière-plan prend le caractère du verre.
        </p>
        <nav className="chips" aria-label="Les 9 objectifs">
          {lenses.map((lens) => (
            <a key={lens.id} className="chip" href={`#${lens.id}`}>
              {lens.name}
            </a>
          ))}
        </nav>
      </header>

      <main className="cards">
        {lenses.map((lens, i) => (
          <LensCard key={lens.id} lens={lens} index={i} />
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
