# Kit App Store d'Optyx

Tout ce qu'il faut pour publier la fiche App Store : visuels aux
dimensions exigées, textes prêts à coller, et check-list de mise en
ligne (faisable depuis un iPhone, Safari en « version ordinateur »).

## Contenu

| Fichier | Rôle |
|---|---|
| `01-hero.png` … `11-angenieux.png` | 11 captures marketing 1320 × 2868 px (iPhone 6,9″) — le héros, la profondeur, et chacun des 9 objectifs |
| `fiche-app-store-fr.md` | Fiche française : nom, sous-titre, description, mots-clés… |
| `fiche-app-store-en.md` | Localisation anglaise |
| `generate.py` | Générateur des visuels (HTML → PNG via Chromium headless) |

App Store Connect accepte **10 captures maximum** ; il y en a 11.
Ordre conseillé (en écartant par exemple le Biotar, doublon visuel de
l'Helios) : héros, Helios, Trioplan, Dream Lens, Noctilux, Takumar,
Summicron, Noct-Nikkor, Angénieux, Profondeur.

## Check-list de publication

1. **Build** : attendre qu'un build TestFlight soit validé (Xcode Cloud
   téléverse chaque merge sur `master`).
2. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) →
   **Apps** → **Optyx** → onglet **App Store**.
3. **Captures d'écran** : section iPhone 6,9″ → glisser les 6 PNG dans
   l'ordre. Ce format se décline automatiquement pour les autres tailles
   d'iPhone. (iPad : jeu 13″ 2064 × 2752 à générer si l'app est
   proposée sur iPad.)
4. **Textes** : copier depuis `fiche-app-store-fr.md` (langue
   principale : français), puis ajouter la localisation anglaise depuis
   `fiche-app-store-en.md`.
5. **Confidentialité** : questionnaire App Privacy → « Aucune donnée
   collectée ».
6. **Général** : catégorie Photo et vidéo, classification 4+, prix.
7. Sélectionner le build, puis **Soumettre pour examen**.

## Régénérer les visuels

```bash
# Police (une fois) :
curl -L -o /tmp/inter.zip \
  https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
unzip -j /tmp/inter.zip InterVariable.ttf -d fonts/

python3 generate.py
for f in 01-hero 02-helios 03-trioplan 04-dreamlens 05-takumar 06-profondeur; do
  chromium --headless=new --hide-scrollbars --force-device-scale-factor=1 \
    --window-size=1320,2868 --screenshot="$f.png" "file://$PWD/$f.html"
done
```

Les scènes des visuels sont des illustrations stylisées ; elles peuvent
être remplacées par de vraies captures de l'app (mêmes cadres, même
mise en page) dès qu'un build final est disponible — les règles d'Apple
demandent que les captures reflètent l'expérience réelle de l'app.
