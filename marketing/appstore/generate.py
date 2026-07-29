#!/usr/bin/env python3
"""Génère les visuels App Store d'Optyx (1320x2868, iPhone 6,9 pouces)."""
import math
import os

OUT = os.path.dirname(os.path.abspath(__file__))

CSS = """
@font-face {
  font-family: 'Inter';
  src: url('fonts/InterVariable.ttf') format('truetype-variations');
  font-weight: 100 900;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: 1320px; height: 2868px; overflow: hidden; }
body {
  font-family: 'Inter', sans-serif;
  background: radial-gradient(120% 60% at 50% -10%, #1c1917 0%, #0a0a0a 55%, #000 100%);
  color: #fff;
  position: relative;
}
.accent { color: #ff9f0a; }
.headline {
  position: absolute; top: 150px; left: 90px; right: 90px;
  font-size: 118px; font-weight: 800; letter-spacing: -3px;
  text-align: center; line-height: 1.06;
}
.sub {
  position: absolute; top: 470px; left: 140px; right: 140px;
  font-size: 52px; font-weight: 500; color: #b8b2aa;
  text-align: center; line-height: 1.35; letter-spacing: -0.5px;
}
.brand {
  position: absolute; top: 70px; left: 0; right: 0;
  text-align: center; font-size: 40px; font-weight: 700;
  letter-spacing: 14px; color: #ff9f0a; text-transform: uppercase;
}
/* ---- iPhone ---- */
.phone {
  position: absolute; left: 50%; transform: translateX(-50%);
  top: 700px; width: 1010px; height: 2260px;
  border-radius: 155px; background: #000;
  border: 5px solid #3a3a3c;
  box-shadow: 0 0 0 14px #1a1a1c, 0 60px 160px rgba(0,0,0,.85),
              0 0 220px rgba(255,159,10,.10);
  overflow: hidden;
}
.island {
  position: absolute; top: 32px; left: 50%; transform: translateX(-50%);
  width: 260px; height: 74px; border-radius: 40px; background: #000;
  z-index: 40; border: 1px solid #111;
}
.scene { position: absolute; inset: 0; overflow: hidden; }
/* ---- UI de l'app ---- */
.chipbar {
  position: absolute; left: 0; right: 0; bottom: 470px;
  display: flex; justify-content: center; gap: 26px; align-items: center;
  z-index: 30;
}
.chip {
  background: rgba(28,28,30,.82); border-radius: 44px;
  padding: 26px 42px; text-align: center; backdrop-filter: blur(8px);
  color: #ddd; flex-shrink: 0;
}
.chip .n { font-size: 37px; font-weight: 700; }
.chip .f { font-size: 30px; font-weight: 500; opacity: .75; margin-top: 4px; }
.chip.on { background: #ff9f0a; color: #1a1000; }
.slider {
  position: absolute; left: 120px; right: 240px; bottom: 380px; height: 14px;
  border-radius: 7px; background: linear-gradient(90deg,#ff9f0a 82%, #3a3a3c 82%);
  z-index: 30;
}
.slider::after {
  content: ''; position: absolute; right: 14%; top: 50%;
  transform: translate(50%,-50%); width: 74px; height: 46px;
  border-radius: 26px; background: #fff;
}
.pct {
  position: absolute; right: 90px; bottom: 350px; font-size: 44px;
  font-weight: 700; color: #fff; z-index: 30;
}
.modes {
  position: absolute; left: 0; right: 0; bottom: 270px; text-align: center;
  font-size: 42px; font-weight: 700; z-index: 30;
}
.modes .off { color: #999; font-weight: 500; margin-left: 40px; }
.shutter {
  position: absolute; left: 50%; bottom: 60px; transform: translateX(-50%);
  width: 165px; height: 165px; border-radius: 50%;
  border: 9px solid #fff; z-index: 30;
}
.shutter::after {
  content: ''; position: absolute; inset: 12px; border-radius: 50%; background: #fff;
}
.topchips {
  position: absolute; top: 130px; left: 0; right: 0; display: flex;
  justify-content: center; gap: 24px; z-index: 30;
}
.tchip {
  background: rgba(28,28,30,.8); color: #eee; border-radius: 40px;
  padding: 20px 38px; font-size: 34px; font-weight: 700;
}
.tchip.on { background: #ff9f0a; color: #1a1000; }
/* ---- éléments de scène ---- */
.dot { position: absolute; border-radius: 50%; }
.arc { position: absolute; border-radius: 999px; }
.ring { position: absolute; border-radius: 50%; background: transparent; }
.vig {
  position: absolute; inset: -8%; z-index: 20;
  background: radial-gradient(75% 62% at 50% 46%, transparent 55%, rgba(0,0,0,.55) 100%);
}
.footer {
  position: absolute; bottom: 90px; left: 0; right: 0; text-align: center;
  font-size: 38px; font-weight: 600; color: #6e6862; letter-spacing: 2px;
  z-index: 50;
}
"""

def phone(scene_html, chips, ui=True, top="Profondeur", video=False):
    c = ""
    for name, focal, on in chips:
        c += f'<div class="chip{" on" if on else ""}"><div class="n">{name}</div><div class="f">{focal}</div></div>'
    ui_html = ""
    if ui:
        ui_html = f"""
        <div class="topchips"><div class="tchip">AE/AF</div><div class="tchip on">&#9679;&nbsp;{top}</div><div class="tchip">RAW</div></div>
        <div class="chipbar">{c}</div>
        <div class="slider"></div><div class="pct">100&nbsp;%</div>
        <div class="modes">{'<span class="off">Photo</span><span class="accent" style="margin-left:40px">Vidéo</span>' if video else '<span class="accent">Photo</span><span class="off">Vidéo</span>'}</div>
        <div class="shutter"></div>"""
    return f"""<div class="phone"><div class="island"></div>
      <div class="scene">{scene_html}<div class="vig"></div></div>{ui_html}</div>"""

def dots(seed_pts, palette, blur=22, z=1, hard=False):
    html = ""
    stop = "62%" if hard else "72%"
    inner = "58%" if hard else "0%"
    for i, (x, y, s, ci, o) in enumerate(seed_pts):
        ccol = palette[ci % len(palette)]
        html += (f'<div class="dot" style="left:{x}px;top:{y}px;width:{s}px;height:{s}px;'
                 f'background:radial-gradient(circle at 38% 35%, {ccol} {inner}, {ccol} {inner}, transparent {stop});'
                 f'opacity:{o};filter:blur({blur}px);z-index:{z};"></div>')
    return html

def swirl_arcs(cx, cy, radii, palette, thick=26, blur=14):
    """Arcs tangents : traînées du bokeh tourbillonnant."""
    html = ""
    for i, (r, a0, span, ci, o) in enumerate(radii):
        length = 2 * math.pi * r * span / 360
        a = math.radians(a0)
        x = cx + r * math.cos(a)
        y = cy + r * math.sin(a)
        rot = a0 + 90
        col = palette[ci % len(palette)]
        html += (f'<div class="arc" style="left:{x - length/2:.0f}px;top:{y - thick/2:.0f}px;'
                 f'width:{length:.0f}px;height:{thick}px;'
                 f'background:linear-gradient(90deg, transparent, {col} 30%, {col} 70%, transparent);'
                 f'transform:rotate({rot:.0f}deg);opacity:{o};filter:blur({blur}px);"></div>')
    return html

def rings(pts, color="rgba(255,240,214,", w=7, blur=3):
    html = ""
    for x, y, s, o in pts:
        html += (f'<div class="ring" style="left:{x}px;top:{y}px;width:{s}px;height:{s}px;'
                 f'border:{w}px solid {color}{o});box-shadow:0 0 {s//5}px {color}{o*0.55:.2f}), '
                 f'inset 0 0 {s//4}px {color}{o*0.3:.2f});filter:blur({blur}px);"></div>')
    return html

def page(name, headline, sub, body, headline_size=118, sub_top=470):
    html = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>{CSS}</style></head>
<body><div class="brand">Optyx</div>
<div class="headline" style="font-size:{headline_size}px">{headline}</div>
<div class="sub" style="top:{sub_top}px">{sub}</div>
{body}</body></html>"""
    with open(os.path.join(OUT, name), "w") as f:
        f.write(html)

# ---------------------------------------------------------------- écran 1 : héros
PAL_WARM = ["rgba(255,190,105,.95)", "rgba(255,150,70,.9)", "rgba(255,220,170,.95)",
            "rgba(180,120,255,.55)", "rgba(120,180,255,.5)"]
pts = [(120,300,260,0,.8),(700,180,320,1,.7),(420,520,180,2,.9),(60,900,300,1,.55),
       (760,760,240,2,.75),(280,1100,340,0,.6),(650,1250,200,3,.6),(150,1500,260,2,.7),
       (720,1560,300,4,.5),(430,1750,220,0,.75),(90,120,180,2,.85),(870,420,190,0,.7),
       (500,950,150,1,.9),(840,1080,170,2,.6),(300,80,150,4,.5)]
scene = f'<div style="position:absolute;inset:0;background:radial-gradient(90% 70% at 55% 35%, #2a1f14 0%, #120d08 60%, #060404 100%);"></div>' + dots(pts, PAL_WARM, blur=26)
body = phone(scene, [("Noctilux","50 mm f/1",False),("Helios 44-2","58 mm f/2",True),("Trioplan","100 mm f/2.8",False)])
page("01-hero.html",
     'Les objectifs<br><span class="accent">légendaires.</span><br>Dans votre poche.',
     "9 verres mythiques simulés en temps réel, en photo comme en vidéo.",
     body, headline_size=104, sub_top=540)

# ---------------------------------------------------------------- écran 2 : Helios
PAL_HELIOS = ["rgba(210,255,160,.9)", "rgba(255,230,150,.9)", "rgba(160,220,120,.8)",
              "rgba(255,190,110,.85)"]
cx, cy = 500, 900
arcs = []
for i in range(38):
    r = 260 + (i * 43) % 620
    a0 = (i * 47.3) % 360
    span = 16 + (i * 7) % 26
    arcs.append((r, a0, span, i, .32 + (i % 5) * .11))
scene = ('<div style="position:absolute;inset:0;background:radial-gradient(80% 65% at 50% 42%, #1c2410 0%, #0e1207 55%, #050603 100%);"></div>'
         + dots([(cx-140,cy-190,300,1,.95),(cx-30,cy-60,200,0,.95),(cx-230,cy+10,170,3,.9)], PAL_HELIOS, blur=16)
         + swirl_arcs(cx, cy, arcs, PAL_HELIOS))
body = phone(scene, [("Neutre","—",False),("Helios 44-2","58 mm f/2",True),("Zeiss Biotar","58 mm f/2",False)])
page("02-helios.html",
     'Le tourbillon<br>du <span class="accent">Helios 44-2.</span>',
     "L'arrière-plan se met à tournoyer autour de votre sujet, comme sur le culte 58 mm soviétique de 1958.",
     body)

# ---------------------------------------------------------------- écran 3 : Trioplan
ring_pts = [(120,260,190,.85),(420,150,150,.7),(660,300,230,.9),(240,560,130,.75),
            (560,640,180,.8),(90,840,220,.65),(720,900,150,.85),(360,1000,250,.7),
            (170,1300,160,.8),(600,1260,200,.75),(430,1550,140,.85),(740,1560,180,.6),
            (60,1660,150,.7),(300,1780,190,.65),(820,1200,120,.8),(850,600,130,.7)]
scene = ('<div style="position:absolute;inset:0;background:radial-gradient(85% 70% at 50% 40%, #201409 0%, #100a05 55%, #060302 100%);"></div>'
         + dots([(320,700,260,0,.5),(600,420,200,2,.45)], PAL_WARM, blur=30)
         + rings(ring_pts))
body = phone(scene, [("Zeiss Biotar","58 mm f/2",False),("Trioplan","100 mm f/2.8",True),("Summicron","50 mm f/2",False)])
page("03-trioplan.html",
     'Des bulles de savon<br>signées <span class="accent">Trioplan.</span>',
     "Chaque point lumineux devient un anneau brillant — l'aberration la plus recherchée du triplet Meyer-Optik de 1916.",
     body)

# ---------------------------------------------------------------- écran 4 : Dream Lens
PAL_DREAM = ["rgba(255,238,210,1)", "rgba(255,215,230,.9)", "rgba(225,230,255,.85)",
             "rgba(255,250,235,1)"]
pts = [(200,300,420,0,.8),(560,180,520,3,.75),(80,760,480,1,.65),(600,700,560,0,.75),
       (320,1150,600,2,.6),(620,1350,460,3,.7),(120,1500,420,0,.65),(400,500,300,3,.9),
       (700,1050,340,1,.6),(250,1700,380,2,.6)]
scene = ('<div style="position:absolute;inset:0;background:radial-gradient(95% 75% at 50% 40%, #3a3230 0%, #1e1817 55%, #0c0a09 100%);"></div>'
         + dots(pts, PAL_DREAM, blur=44)
         + '<div style="position:absolute;inset:0;background:radial-gradient(65% 50% at 50% 36%, rgba(255,242,225,.30) 0%, transparent 72%);"></div>')
body = phone(scene, [("Noctilux","50 mm f/1",False),("Canon « Dream Lens »","50 mm f/0.95",True),("Super Takumar","50 mm f/1.4",False)])
page("04-dreamlens.html",
     'Le rêve<br>à <span class="accent">f/0.95.</span>',
     "Halos généreux, netteté fragile, voile onirique : la légende du Canon Dream Lens, produit à quelques milliers d'exemplaires.",
     body)

# ---------------------------------------------------------------- écran 5 : Takumar
PAL_GOLD = ["rgba(255,200,90,.95)", "rgba(255,170,60,.9)", "rgba(255,225,150,.95)",
            "rgba(230,140,50,.85)"]
pts = [(600,220,380,0,.8),(150,400,260,2,.7),(400,700,200,1,.85),(700,850,300,2,.6),
       (100,1000,340,0,.6),(500,1200,260,3,.7),(250,1500,300,1,.6),(680,1500,220,0,.7),
       (350,150,180,3,.75),(800,500,200,1,.65),(60,1700,240,2,.6)]
scene = ('<div style="position:absolute;inset:0;background:linear-gradient(160deg, #3a2408 0%, #241505 45%, #0e0802 100%);"></div>'
         + dots(pts, PAL_GOLD, blur=30)
         + '<div style="position:absolute;left:560px;top:120px;width:520px;height:520px;border-radius:50%;background:radial-gradient(circle, rgba(255,215,130,.55) 0%, rgba(255,180,80,.25) 45%, transparent 70%);filter:blur(10px);"></div>')
body = phone(scene, [("Dream Lens","50 mm f/0.95",False),("Super Takumar","50 mm f/1.4",True),("Noct-Nikkor","58 mm f/1.2",False)])
page("05-takumar.html",
     "L'or du <span class=\"accent\">thorium.</span>",
     "Le verre légèrement radioactif du Super Takumar jaunit avec les décennies — Optyx recrée sa dorure inimitable.",
     body, sub_top=330)

# ---------------------------------------------------------------- écran 6 : Profondeur
cx, cy = 500, 760
arcs = []
for i in range(30):
    r = 330 + (i * 57) % 560
    a0 = (i * 53.7) % 360
    span = 14 + (i * 5) % 22
    arcs.append((r, a0, span, i, .3 + (i % 4) * .12))
silhouette = """
<svg viewBox="0 0 200 260" style="position:absolute;left:50%;bottom:290px;transform:translateX(-50%);width:640px;z-index:15;filter:drop-shadow(0 0 60px rgba(0,0,0,.9));">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#2b2320"/><stop offset="1" stop-color="#0d0a09"/>
  </linearGradient></defs>
  <circle cx="100" cy="74" r="46" fill="url(#g)"/>
  <path d="M100 118 C 52 118 26 156 20 260 L 180 260 C 174 156 148 118 100 118 Z" fill="url(#g)"/>
</svg>"""
scene = ('<div style="position:absolute;inset:0;background:radial-gradient(85% 70% at 50% 38%, #17202b 0%, #0b1015 55%, #040507 100%);"></div>'
         + dots([(150,260,240,4,.6),(700,200,280,3,.55),(260,640,200,4,.5),(680,760,240,3,.5),(420,420,180,4,.6)], PAL_WARM, blur=24)
         + swirl_arcs(cx, cy, arcs, ["rgba(150,200,255,.7)", "rgba(255,210,140,.7)", "rgba(190,170,255,.6)"])
         + silhouette)
body = phone(scene, [("Summicron","50 mm f/2",False),("Noctilux","50 mm f/1",True),("Dream Lens","50 mm f/0.95",False)])
page("06-profondeur.html",
     'Votre sujet reste <span class="accent">net.</span>',
     "Grâce au LiDAR, les effets sculptent l'arrière-plan selon la vraie distance — le visage, lui, ne bouge pas.",
     body, sub_top=330)

print("6 pages générées dans", OUT)


# ---------------------------------------------------------------- écran 7 : Biotar
PAL_BIOTAR = ["rgba(200,225,190,.85)", "rgba(235,235,220,.85)", "rgba(170,200,230,.7)",
              "rgba(230,210,170,.8)"]
cx, cy = 500, 880
arcs = []
for i in range(30):
    r = 300 + (i * 51) % 560
    a0 = (i * 61.7) % 360
    span = 12 + (i * 5) % 18
    arcs.append((r, a0, span, i, .26 + (i % 4) * .10))
scene = ('<div style="position:absolute;inset:0;background:radial-gradient(80% 65% at 50% 42%, #1a2018 0%, #0e120d 55%, #050604 100%);"></div>'
         + dots([(cx-120,cy-170,260,1,.9),(cx-10,cy-40,170,0,.9)], PAL_BIOTAR, blur=16)
         + swirl_arcs(cx, cy, arcs, PAL_BIOTAR, thick=22, blur=16))
body = phone(scene, [("Helios 44-2","58 mm f/2",False),("Zeiss Biotar","58 mm f/2",True),("Trioplan","100 mm f/2.8",False)])
page("07-biotar.html",
     'Le tourbillon <span class="accent">originel.</span>',
     "Zeiss Biotar, 1936 : la spirale dont l\'Helios est la copie — plus douce, plus raffinée, plus rare.",
     body, sub_top=330)

# ---------------------------------------------------------------- écran 8 : Summicron
PAL_LEICA = ["rgba(240,238,232,.95)", "rgba(255,225,170,.9)", "rgba(190,215,240,.85)",
             "rgba(255,180,120,.85)"]
pts = [(150,260,90,0,.9),(420,180,70,1,.85),(680,320,110,2,.8),(260,560,60,3,.9),
       (560,620,95,0,.85),(120,860,80,1,.8),(720,880,70,2,.85),(380,1050,100,0,.9),
       (200,1300,75,3,.8),(620,1260,85,1,.85),(460,1520,65,0,.9),(770,1520,90,2,.7),
       (90,1650,70,1,.8),(330,1760,80,0,.85)]
scene = ('<div style="position:absolute;inset:0;background:linear-gradient(170deg,#23211e 0%, #131210 55%, #070706 100%);"></div>'
         + dots(pts, PAL_LEICA, blur=2, hard=True))
body = phone(scene, [("Trioplan","100 mm f/2.8",False),("Summicron","50 mm f/2",True),("Noctilux","50 mm f/1",False)])
page("08-summicron.html",
     'La précision <span class="accent">Leica.</span>',
     "Summicron 50 mm : micro-contraste superbe, rendu précis, jamais clinique. Le classique du reportage.",
     body, sub_top=330)

# ---------------------------------------------------------------- écran 9 : Noctilux
PAL_NOCT = ["rgba(255,220,150,1)", "rgba(255,190,110,.95)", "rgba(180,200,255,.8)",
            "rgba(255,240,200,1)"]
pts = [(180,300,180,0,.95),(600,220,240,3,.9),(320,620,150,1,.9),(700,700,190,0,.85),
       (110,950,220,3,.8),(500,1100,170,1,.9),(260,1420,200,0,.8),(660,1400,150,2,.7),
       (420,1700,180,3,.8),(90,1650,140,2,.6)]
halos = ""
for x, y, s, ci, o in pts:
    halos += (f'<div class="dot" style="left:{x-s}px;top:{y-s}px;width:{s*3}px;height:{s*3}px;'
              f'background:radial-gradient(circle, rgba(255,230,180,{o*0.35:.2f}) 0%, transparent 65%);'
              f'filter:blur(30px);"></div>')
scene = ('<div style="position:absolute;inset:0;background:radial-gradient(85% 70% at 50% 40%, #10131f 0%, #090a12 55%, #030304 100%);"></div>'
         + halos + dots(pts, PAL_NOCT, blur=18))
body = phone(scene, [("Summicron","50 mm f/2",False),("Noctilux","50 mm f/1",True),("Dream Lens","50 mm f/0.95",False)])
page("09-noctilux.html",
     'Le roi de la <span class="accent">nuit.</span>',
     "Leica Noctilux à f/1 : chaque lumière baigne dans un glow onirique, la netteté se réduit à un fil.",
     body, sub_top=330)

# ---------------------------------------------------------------- écran 10 : Noct-Nikkor
PAL_NIKKOR = ["rgba(245,245,250,.95)", "rgba(255,230,170,.9)", "rgba(170,200,255,.85)"]
pts = [(140,240,50,0,.95),(430,170,40,1,.9),(690,300,55,2,.85),(250,540,35,0,.95),
       (570,600,45,1,.9),(120,840,40,2,.85),(730,860,38,0,.9),(390,1020,50,1,.95),
       (210,1280,36,0,.85),(630,1240,42,2,.9),(470,1500,38,1,.9),(780,1490,45,0,.8),
       (100,1620,40,1,.85),(340,1740,44,0,.9),(660,1680,36,2,.8)]
glow_layer = '<div style="position:absolute;inset:0;background:radial-gradient(70% 55% at 50% 35%, rgba(120,150,220,.10) 0%, transparent 70%);"></div>'
scene = ('<div style="position:absolute;inset:0;background:radial-gradient(90% 70% at 50% 38%, #0d1018 0%, #07080d 55%, #020203 100%);"></div>'
         + glow_layer + dots(pts, PAL_NIKKOR, blur=1, hard=True))
body = phone(scene, [("Super Takumar","50 mm f/1.4",False),("Noct-Nikkor","58 mm f/1.2",True),("Angénieux","25–250 mm",False)])
page("10-noctnikkor.html",
     'La nuit, <span class="accent">maîtrisée.</span>',
     "Noct-Nikkor 58 mm : sa lentille asphérique polie à la main dompte le coma — des points nets, un contraste franc.",
     body, sub_top=330)

# ---------------------------------------------------------------- écran 11 : Angénieux
PAL_CINE = ["rgba(255,190,120,.9)", "rgba(120,190,190,.7)", "rgba(255,225,180,.9)",
            "rgba(200,150,110,.8)"]
pts = [(150,700,260,0,.75),(600,620,300,1,.6),(360,900,200,2,.8),(720,1000,240,0,.65),
       (90,1100,280,3,.6),(480,1250,220,1,.65),(260,1450,240,0,.7)]
grain = ("""<svg style="position:absolute;inset:0;width:100%;height:100%;z-index:18;opacity:.32;mix-blend-mode:overlay;">
  <filter id="g"><feTurbulence type="fractalNoise" baseFrequency="0.75" numOctaves="2" stitchTiles="stitch"/>
  <feColorMatrix type="saturate" values="0"/></filter>
  <rect width="100%" height="100%" filter="url(#g)"/></svg>""")
bars = ('<div style="position:absolute;left:0;right:0;top:0;height:560px;background:#000;z-index:16;"></div>'
        '<div style="position:absolute;left:0;right:0;bottom:0;height:560px;background:#000;z-index:16;"></div>')
scene = ('<div style="position:absolute;inset:0;background:linear-gradient(165deg,#2a2018 0%, #1a1a16 45%, #0d1210 100%);"></div>'
         + dots(pts, PAL_CINE, blur=26) + grain + bars)
body = phone(scene, [("Noct-Nikkor","58 mm f/1.2",False),("Angénieux","zoom 25–250 mm",True),("Neutre","—",False)], video=True)
page("11-angenieux.html",
     'Le rendu <span class="accent">cinéma.</span>',
     "Les zooms légendaires d\'Hollywood à la Nouvelle Vague : contraste doux, couleurs chaudes, grain présent — et letterbox CinemaScope.",
     body, sub_top=330)
