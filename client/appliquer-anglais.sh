#!/usr/bin/env bash
# Applique le patch anglais de FGOAC-scooby SANS passer par fgozh.dll.
#
# ⚠️ POURQUOI PAS LE HOOK : sous Wine, la DllMain de fgozh.dll renvoie FALSE et
# inject.exe avorte. Établi par élimination — FGO_ZH_ENABLED=1 n'y change rien,
# il échoue même seul sans fgohook, et aucune exception n'apparaît dans le
# journal Wine : la DLL est mappée, relogée, son callback TLS enregistré, puis
# elle refuse délibérément. Ses étapes internes sont REDIRECT_INDEX → EXE_TEXT →
# FLAVOR_NEWLINES → FONT_TRACE → TEXT_MEASURE_CACHE, et son journal s'arrête
# après la PREMIÈRE : l'échec est dans EXE_TEXT, la seule étape qui patche du
# texte dans l'exécutable en mémoire.
#
# Tout le reste n'étant que de la redirection de fichiers, on la fait en dur :
# App/zh/rom/ est un miroir anglais complet de App/rom/.
#
# ⚠️ CE QUI RESTERA JAPONAIS, et qu'aucune copie de fichier ne peut atteindre :
#   - les chaînes compilées dans ago.exe (App/zh/executable-text.json, 441 Ko)
#   - les artworks que scooby n'a pas refaits : bannières et écrans de résultat
#     co-op, boutiques d'événements tardives (documenté par l'amont)
set -u

RACINE="${1:-$HOME/fgo-install}"
APP="$RACINE/App"
SAUVEGARDE="$RACINE/_sauvegarde-rom-jp"

[ -d "$APP/zh/rom" ] || { echo "App/zh/rom introuvable : le patch scooby n est pas applique" >&2; exit 1; }

case "${2:-appliquer}" in
  appliquer)
    mkdir -p "$SAUVEGARDE"
    n=0
    while IFS= read -r rel; do
      if [ -f "$APP/$rel" ]; then
        mkdir -p "$SAUVEGARDE/$(dirname "$rel")"
        cp -n "$APP/$rel" "$SAUVEGARDE/$rel" 2>/dev/null && n=$((n+1))
      fi
    done < <(cd "$APP/zh" && find rom -type f)
    echo "$n original(aux) japonais sauvegarde(s) dans $SAUVEGARDE"

    remplaces=0
    while IFS= read -r rel; do
      if [ -f "$APP/zh/$rel" ] && [ -f "$APP/$rel" ]; then
        cmp -s "$APP/zh/$rel" "$APP/$rel" || { cp "$APP/zh/$rel" "$APP/$rel" && remplaces=$((remplaces+1)); }
      fi
    done < <(cd "$APP/zh" && find rom -type f)
    echo "$remplaces fichier(s) remplace(s) par la version anglaise"
    ;;
  restaurer)
    [ -d "$SAUVEGARDE" ] || { echo "aucune sauvegarde dans $SAUVEGARDE" >&2; exit 1; }
    n=0
    while IFS= read -r rel; do
      cp "$SAUVEGARDE/$rel" "$APP/$rel" && n=$((n+1))
    done < <(cd "$SAUVEGARDE" && find rom -type f)
    echo "$n fichier(s) restaure(s) en japonais"
    ;;
  *)
    echo "usage : $0 [racine] [appliquer|restaurer]" >&2; exit 2;;
esac
