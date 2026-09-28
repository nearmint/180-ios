#!/bin/sh
# Xcode Cloud — exécuté juste après le clone du dépôt.
#
# 1. GoogleService-Info.plist n'est pas versionné. Il est reconstitué depuis la
#    variable d'environnement secrète GOOGLE_SERVICE_INFO_PLIST_BASE64, à
#    déclarer dans chaque workflow Xcode Cloud. Format attendu : le fichier
#    compressé en gzip puis encodé en base64, sans padding `=` (Xcode Cloud
#    refuse la valeur brute, trop longue) :
#      gzip -9 -n -c 180/GoogleService-Info.plist | base64 | tr -d '\n='
#    Le base64 simple du fichier (avec ou sans padding) reste accepté.
# 2. Config/Private.xcconfig (optionnel) surcharge les adresses de contact de
#    l'écran Compte si CONTACT_EDITORIAL_EMAIL / CONTACT_SUPPORT_EMAIL sont
#    définies. Sans elles, les valeurs publiques des xcconfig s'appliquent.
set -eu

: "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH absent : ce script est prévu pour Xcode Cloud}"

if [ -z "${GOOGLE_SERVICE_INFO_PLIST_BASE64:-}" ]; then
  echo "error: GOOGLE_SERVICE_INFO_PLIST_BASE64 absente. Déclarer la variable secrète dans le workflow Xcode Cloud (base64 de GoogleService-Info.plist)." >&2
  exit 1
fi

dest="$CI_PRIMARY_REPOSITORY_PATH/180/GoogleService-Info.plist"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Retire les blancs éventuels, rétablit le padding base64 retiré à la saisie.
value="$(printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | tr -d ' \n\r\t')"
while [ $(( ${#value} % 4 )) -ne 0 ]; do value="${value}="; done
printf '%s' "$value" | base64 --decode > "$tmp"

# gzip (octets 1f 8b) → décompression ; sinon le contenu est déjà le plist.
if [ "$(head -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
  gunzip -c < "$tmp" > "$dest"
else
  cp "$tmp" "$dest"
fi
plutil -lint "$dest" >/dev/null || { echo "error: GoogleService-Info.plist décodé invalide." >&2; exit 1; }
echo "GoogleService-Info.plist écrit ($(wc -c < "$dest" | tr -d ' ') octets)."

private="$CI_PRIMARY_REPOSITORY_PATH/Config/Private.xcconfig"
: > "$private"
if [ -n "${CONTACT_EDITORIAL_EMAIL:-}" ]; then
  echo "CONTACT_EDITORIAL_EMAIL = $CONTACT_EDITORIAL_EMAIL" >> "$private"
fi
if [ -n "${CONTACT_SUPPORT_EMAIL:-}" ]; then
  echo "CONTACT_SUPPORT_EMAIL = $CONTACT_SUPPORT_EMAIL" >> "$private"
fi
