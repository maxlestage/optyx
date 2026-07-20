#!/bin/bash
# Téléversement de secours vers TestFlight, par clé API App Store Connect.
#
# Contexte : la livraison intégrée de Xcode Cloud (« Prepare Build for App
# Store Connect ») s'authentifie via la session interne du compte. Quand
# cette session est cassée côté Apple (« Unable to authenticate with App
# Store Connect », « Failed to find an account with App Store Connect
# access »), l'archive et les exports réussissent mais rien n'arrive sur
# TestFlight. Ce script contourne la session : il téléverse lui-même l'IPA
# app-store avec une clé API App Store Connect (authentification JWT,
# totalement indépendante de la session).
#
# Activation — définir 3 variables d'environnement dans le workflow
# Xcode Cloud (voir ci_scripts/README.md) :
#   ASC_KEY_ID     identifiant de la clé (10 caractères)
#   ASC_ISSUER_ID  identifiant d'émetteur (UUID de la page Intégrations)
#   ASC_KEY_P8     contenu du fichier AuthKey_XXXXXXXXXX.p8 (marquer secret)
# Sans ces variables, le script ne fait rien. Il ne fait JAMAIS échouer le
# build : en cas de problème il journalise et sort en succès.

set -uo pipefail

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
    exit 0
fi

if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_KEY_P8:-}" ]]; then
    echo "Optyx : variables ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 absentes — téléversement de secours désactivé."
    exit 0
fi

# --- Reconstruit un .p8 PEM valide, quelle que soit la façon dont le
# --- contenu a été collé (retours à la ligne perdus, en-têtes présents ou
# --- non) : on extrait le corps base64 et on replie à 64 colonnes.
KEYDIR="$HOME/private_keys"
KEYFILE="$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
mkdir -p "$KEYDIR"
BODY=$(printf '%s' "$ASC_KEY_P8" \
    | sed -e 's/-----BEGIN PRIVATE KEY-----//g' -e 's/-----END PRIVATE KEY-----//g' \
    | tr -d '[:space:]')
if [[ -z "$BODY" ]]; then
    echo "Optyx : ASC_KEY_P8 est vide après nettoyage — téléversement abandonné."
    exit 0
fi
{
    echo "-----BEGIN PRIVATE KEY-----"
    printf '%s\n' "$BODY" | fold -w 64
    echo "-----END PRIVATE KEY-----"
} > "$KEYFILE"
chmod 600 "$KEYFILE"

upload_ipa() {
    local ipa="$1"
    echo "Optyx : téléversement de $(basename "$ipa") vers App Store Connect (clé ${ASC_KEY_ID})…"
    xcrun altool --upload-app --type ios -f "$ipa" \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
}

upload_archive() {
    local plist="$CI_DERIVED_DATA_PATH/optyx-upload-options.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
    echo "Optyx : téléversement via xcodebuild -exportArchive (destination upload)…"
    xcodebuild -exportArchive \
        -archivePath "$CI_ARCHIVE_PATH" \
        -exportOptionsPlist "$plist" \
        -exportPath "$CI_DERIVED_DATA_PATH/optyx-upload" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEYFILE" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

IPA=""
if [[ -n "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]]; then
    IPA=$(find "$CI_APP_STORE_SIGNED_APP_PATH" -name '*.ipa' -print -quit 2>/dev/null)
fi

if [[ -n "$IPA" ]] && upload_ipa "$IPA"; then
    echo "Optyx : ✔ téléversement réussi — le build apparaîtra dans TestFlight après le traitement d'Apple."
elif [[ -n "${CI_ARCHIVE_PATH:-}" ]] && upload_archive; then
    echo "Optyx : ✔ téléversement (voie xcodebuild) réussi — le build apparaîtra dans TestFlight après traitement."
else
    echo "Optyx : ✘ le téléversement de secours a échoué — voir les messages ci-dessus. (Le build n'est pas marqué en échec pour autant.)"
fi

exit 0
