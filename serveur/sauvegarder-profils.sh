#!/usr/bin/env bash
# Rotation des sauvegardes du profil FGO.
#
# POURQUOI : fgo-players.json est reecrit a chaque requete du jeu. Il porte
# toute la progression -- 149 Ko et des mois de jeu -- et le repertoire
# backups/ ne contenait que deux copies manuelles du 2026-08-26. Une fausse
# manoeuvre, un conteneur redemarre au mauvais moment, et tout est perdu.
#
# ⚠️ On ne copie QUE si le contenu a change et si le JSON est VALIDE. Copier un
# fichier tronque par-dessus une bonne sauvegarde serait pire que rien.
set -u
SRC=/home/ezvk/fgo-install/Server/state/fgo-players.json
DST=/home/ezvk/fgo-install/Server/state/backups
RETENTION_JOURS=14

[ -f "$SRC" ] || { echo "source absente : $SRC" >&2; exit 1; }
mkdir -p "$DST"

# Temoin de validite : un JSON tronque ne doit jamais ecraser une sauvegarde.
if ! python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$SRC" 2>/dev/null; then
  echo "REFUS : $SRC n est pas un JSON valide, sauvegarde annulee" >&2
  exit 1
fi

somme=$(sha256sum "$SRC" | cut -c1-16)
derniere=$(ls -t "$DST"/fgo-players-*.json 2>/dev/null | head -1)
if [ -n "$derniere" ] && [ "$(sha256sum "$derniere" | cut -c1-16)" = "$somme" ]; then
  exit 0   # rien n a change
fi

horodatage=$(date +%Y%m%d-%H%M%S)
cible="$DST/fgo-players-$horodatage-$somme.json"
cp -- "$SRC" "$cible"
echo "sauvegarde : $(basename "$cible") ($(stat -c %s "$cible") octets)"

# Retention : on garde tout ce qui a moins de N jours, et au minimum les 20
# dernieres, pour qu une periode sans jeu ne vide pas l historique.
cd "$DST" || exit 0
mapfile -t toutes < <(ls -t fgo-players-*.json 2>/dev/null)
i=0
for f in "${toutes[@]}"; do
  i=$((i+1))
  [ "$i" -le 20 ] && continue
  if [ -n "$(find "$f" -mtime +$RETENTION_JOURS 2>/dev/null)" ]; then
    rm -f -- "$f" && echo "  retiree : $f"
  fi
done
