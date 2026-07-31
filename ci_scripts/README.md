# Téléversement de secours vers TestFlight

`ci_post_xcodebuild.sh` téléverse l'IPA app-store vers TestFlight avec une
**clé API App Store Connect** — une authentification indépendante de la
session interne de Xcode Cloud. À utiliser quand la livraison intégrée
échoue à l'étape « Prepare Build for App Store Connect » avec
`Unable to authenticate with App Store Connect` alors que l'archive et les
exports réussissent.

Tant que les variables ci-dessous ne sont pas définies, le script ne fait
rien du tout ; il ne fait jamais échouer un build.

## Activation (faisable depuis un iPhone, Safari en « version ordinateur »)

### 1. Créer la clé API

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) →
   **Utilisateurs et accès** → onglet **Intégrations** →
   **App Store Connect API** → **Clés d'équipe**.
2. Notez l'**Issuer ID** (UUID affiché en haut de la page).
3. **+** pour générer une clé : nom libre (ex. « Optyx CI »), rôle
   **App Manager**.
4. Notez l'**ID de la clé** (10 caractères) et **téléchargez le fichier
   `.p8`** — téléchargeable **une seule fois**. Ouvrez-le (c'est du texte)
   et copiez tout son contenu, lignes `-----BEGIN/END PRIVATE KEY-----`
   comprises. (Si les retours à la ligne se perdent au collage, ce n'est
   pas grave : le script reconstruit le format.)

### 2. Renseigner les variables dans le workflow

App Store Connect → l'app **Optyx** → **Xcode Cloud** → **Gérer les
workflows** → **Default** → **Modifier** → section **Environnement** →
**Variables d'environnement** :

| Nom | Valeur | Secret |
|---|---|---|
| `ASC_KEY_ID` | l'ID de la clé (10 caractères) | non |
| `ASC_ISSUER_ID` | l'Issuer ID (UUID) | non |
| `ASC_KEY_P8` | tout le contenu du fichier `.p8` | **oui** |

### 3. Relancer un build

Le script téléverse l'IPA à la fin de l'archive. Le build peut rester
marqué « échoué » tant que la livraison intégrée d'Apple est en panne —
sans importance : l'app arrive quand même dans TestFlight (comptez
quelques minutes de traitement après le téléversement).

## Désactivation

Quand la livraison intégrée refonctionne, supprimez les trois variables
(ou seulement `ASC_KEY_P8`). Un double téléversement du même numéro de
build serait de toute façon simplement refusé par Apple, sans casser le
build.
