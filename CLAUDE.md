# Consignes de travail sur Optyx

## Version : NE JAMAIS l'incrémenter

`MARKETING_VERSION` reste à **2.8**. Ne pas la toucher, quelle que soit
l'ampleur d'un changement, et sans le demander à chaque fois : la consigne est
permanente.

Elle avait été montée à chaque livraison pour distinguer les builds de
TestFlight, après une douzaine d'itérations passées à juger un rendu sur une
version antérieure aux correctifs. Ce besoin est déjà couvert autrement : le
viseur affiche `v2.8 (147)`, et **le numéro entre parenthèses est attribué par
Xcode Cloud à chaque archive**. Il s'incrémente donc tout seul et identifie une
livraison sans ambiguïté. Bouger la version commerciale par-dessus n'ajoutait
rien et polluait chaque diff.

Si un jour la version doit changer — vraie évolution du produit, pas un
correctif — c'est l'auteur qui le décide.

## Rendu : vérifier en CALCULANT, pas en relisant

Les bugs les plus coûteux de ce projet ont tous la même forme : **du code qui se
lit bien et qui ne peut pas produire ce qu'il annonce**. Une relecture ne les
voit pas ; seul le calcul des valeurs réelles les révèle.

- Le grain posait une amplitude de 0,32 puis sommait trois canaux : oscillation
  réelle 0,96, le voile REMPLAÇAIT l'image par de la neige. Le recentrage sur
  0,5 étant correct, tout paraissait normal à la lecture — seul l'écart-type
  était monstrueux.
- Le masque de flou était ancré sur la diagonale, réglage calibré pour un cadre
  3:2 : sur le viseur il plafonnait à 0,39 sur toute la bande centrale, soit un
  rayon effectif de 2,6 px pour l'Helios. Le flou existait dans le code et pas à
  l'écran.
- `CIVortexDistortion` DÉPLACE les pixels sans les ÉTIRER. Trois renforcements
  successifs de l'angle n'ont rien donné, parce qu'aucune amplitude ne pouvait
  faire apparaître un filé qui n'était pas calculé.

Avant de livrer un changement de rendu : évaluer l'expression avec les valeurs
réelles des neuf objectifs, dans les trois cadres de l'app (viseur 674×900,
aperçu 900×1200, export 2400×3200), et rapporter les nombres. Un commentaire de
code qui affirme une valeur n'est pas une preuve — plusieurs de ce dépôt se sont
révélés faux.

## Discipline de l'alpha

Ne JAMAIS additionner des images dont l'alpha vaut 1 : l'alpha atteindrait 2 ou
3, et le rendu prémultiplié diviserait les couleurs d'autant. Ce bug a noirci
l'image deux fois.

Composer uniquement par `CIScreenBlendMode`, `CIMaximumCompositing`,
`CIMultiplyCompositing`, `CIBlendWithMask` ou `CIDissolveTransition`. Toute
`CIColorMatrix` laisse sa ligne alpha à `(0, 0, 0, 1)`.

## Longueurs en fraction du cadre

Tout rayon, tout seuil géométrique s'exprime en fraction du grand ou du petit
côté, jamais en pixels absolus. Sans quoi le viseur et le fichier exporté
divergent — et le viseur ment sur ce qu'on va obtenir, ce qui est le défaut
fondateur que cette app a mis une journée à éteindre.

## Structure

- `Optyx/Studio/MoteurOptique.swift` — le moteur, partagé par le viseur et le
  studio. Une seule implémentation d'`appliquer`, aucun drapeau « viseur ».
- `Optyx/Studio/SignatureTonale.swift` — la table des neuf verres. Elle porte un
  invariant de plafond à vérifier sur toute la grille (entrée, intensité).
- `Optyx/Camera/` — capture, viseur, outils professionnels, vidéo.
- `site/` — le site vitrine, source des données du catalogue.
- Le projet Xcode utilise un `PBXFileSystemSynchronizedRootGroup` : tout fichier
  déposé sous `Optyx/` est compilé automatiquement. **Ne jamais éditer le
  pbxproj** pour ajouter un fichier.
- `Info.plist` est à la RACINE. L'y remettre dans `Optyx/` déclenche « Multiple
  commands produce Info.plist » et casse la CI.
