// Catalogue des 9 objectifs — miroir de Optyx/Models/LensProfile.swift.
// `scene` pilote le visuel CSS de la carte ; `accent` teinte la carte.

export const lenses = [
  {
    id: 'helios-44-2',
    name: 'Helios 44-2',
    focal: '58 mm f/2',
    origin: 'URSS · monture M42',
    era: '1958 – années 1990',
    story:
      "Copie soviétique du Zeiss Biotar, produit à des millions d'exemplaires. Son bokeh tourbillonnant culte transforme les arrière-plans en spirale autour du sujet. Très abordable, c'est la porte d'entrée du monde vintage.",
    scene: 'swirl',
    accent: '#b8d977',
    traits: [
      ['Tourbillon', 1.0],
      ['Vignettage', 0.45],
      ['Aberration chromatique', 0.35],
    ],
  },
  {
    id: 'zeiss-biotar',
    name: 'Zeiss Biotar',
    focal: '58 mm f/2',
    origin: 'Allemagne · M42 / Exakta',
    era: '1936 – 1960',
    story:
      "L'original allemand dont l'Helios est la copie. Même tourbillon, mais avec un rendu un peu plus doux et raffiné. Plus rare et nettement plus cher que son clone soviétique.",
    scene: 'swirl-soft',
    accent: '#a8c4b8',
    traits: [
      ['Tourbillon', 0.85],
      ['Halo / glow', 0.35],
      ['Douceur des bords', 0.25],
    ],
  },
  {
    id: 'trioplan',
    name: 'Meyer-Optik Görlitz Trioplan',
    focal: '100 mm f/2.8',
    origin: 'Allemagne (RDA) · M42 / Exakta',
    era: '1916 – 1970',
    story:
      "Un triplet optique tout simple dont l'aberration sphérique non corrigée produit le fameux bokeh « bulles de savon » : chaque point lumineux hors mise au point devient un anneau brillant.",
    scene: 'bubbles',
    accent: '#e8c98a',
    traits: [
      ['Bulles de savon', 1.0],
      ['Aberration chromatique', 0.45],
      ['Halo / glow', 0.45],
    ],
  },
  {
    id: 'summicron-50',
    name: 'Leica Summicron',
    focal: '50 mm f/2',
    origin: 'Allemagne · monture M / LTM',
    era: '1953 – aujourd’hui',
    story:
      "Le classique du reportage : micro-contraste superbe, rendu précis mais jamais clinique. Un « défaut » discret : un léger vignettage et une signature douce à pleine ouverture.",
    scene: 'crisp',
    accent: '#e8e4dc',
    traits: [
      ['Micro-contraste', 0.7],
      ['Saturation', 0.6],
      ['Vignettage', 0.2],
    ],
  },
  {
    id: 'noctilux',
    name: 'Leica Noctilux',
    focal: '50 mm f/1',
    origin: 'Allemagne · monture M',
    era: '1976 – 2008',
    story:
      "Le roi de la nuit chez Leica. À f/1, l'image baigne dans un glow onirique, le vignettage est massif et la zone de netteté se réduit à un fil. Un rendu immédiatement reconnaissable.",
    scene: 'night',
    accent: '#ffd894',
    traits: [
      ['Halo / glow', 0.95],
      ['Vignettage', 0.65],
      ['Douceur des bords', 0.45],
    ],
  },
  {
    id: 'canon-dream',
    name: 'Canon « Dream Lens »',
    focal: '50 mm f/0.95',
    origin: 'Japon · monture Canon 7',
    era: '1961 – 1970',
    story:
      "Quasi mythique, très peu produit. À f/0.95, le monde devient un rêve : halos généreux, contraste évanescent, netteté fragile. C'est précisément ce voile onirique qui fait sa légende.",
    scene: 'dream',
    accent: '#f2ddd2',
    traits: [
      ['Halo / glow', 1.0],
      ['Douceur des bords', 0.8],
      ['Aberration chromatique', 0.5],
    ],
  },
  {
    id: 'super-takumar',
    name: 'Pentax Super Takumar',
    focal: '50 mm f/1.4',
    origin: 'Japon · monture M42',
    era: '1964 – 1975',
    story:
      "Son verre au thorium, légèrement radioactif, jaunit avec les décennies et donne aux images une chaleur dorée inimitable. Construction magnifique, mise au point soyeuse.",
    scene: 'gold',
    accent: '#ffc55e',
    traits: [
      ['Dérive chaude', 1.0],
      ['Halo / glow', 0.35],
      ['Vignettage', 0.3],
    ],
  },
  {
    id: 'noct-nikkor',
    name: 'Noct-Nikkor',
    focal: '58 mm f/1.2',
    origin: 'Japon · monture F',
    era: '1977 – 1997',
    story:
      "Conçu pour photographier la nuit : sa lentille asphérique polie à la main dompte le coma des points lumineux. Contraste élevé pour son époque, léger halo à pleine ouverture.",
    scene: 'stars',
    accent: '#aec6ff',
    traits: [
      ['Micro-contraste', 0.85],
      ['Halo / glow', 0.55],
      ['Grain', 0.3],
    ],
  },
  {
    id: 'angenieux',
    name: 'Angénieux Cinéma',
    focal: 'zoom 25–250 mm',
    origin: 'France · montures ciné',
    era: '1956 – aujourd’hui',
    story:
      "Les zooms de cinéma légendaires de Pierre Angénieux, utilisés d'Hollywood à la Nouvelle Vague. Rendu ciné par excellence : contraste doux, couleurs chaudes, grain présent.",
    scene: 'cine',
    accent: '#f0a868',
    traits: [
      ['Grain', 0.6],
      ['Virage ciné', 0.85],
      ['Dérive chaude', 0.4],
    ],
  },
]
