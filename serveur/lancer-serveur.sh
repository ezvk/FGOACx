#!/usr/bin/env bash
# Démarre ARTEMiS + MariaDB dans un pod podman.
#
# ⚠️ LES QUATRE MONTAGES SONT TOUS NÉCESSAIRES. Le couplage serveur → client
# est plus profond qu'il n'y paraît :
#   /app     l'arbre ARTEMiS lui-même
#   /Server  data/fgo-master/talk_unlocks.json — SANS LUI la commande `start`
#            lève FileNotFoundError et le jeu affiche « erreur de connexion
#            réseau » en boucle, sans rien dans les journaux ordinaires
#   /App     deck.json (configuration du deck) et rom/aet (bannières de summon)
#   /DEVICE  print/FGO11_AllServants + library-manifest.json
set -u

SERVEUR="${FGOAC_SERVEUR:?répertoire Server/ du paquet Cloud23333}"
CLIENT="${FGOAC_CLIENT:?racine de installation FGO Arcade}"
IMAGE="${FGOAC_IMAGE:-fgo-artemis:3.10}"
POD="${FGOAC_POD:-fgo}"

# Le pod donne un localhost commun aux deux conteneurs : en lançant MariaDB sur
# le port que core.yaml attend (8888 par défaut), la configuration d'origine
# n'a AUCUNE modification à subir.
PORT_DB="${FGOAC_PORT_DB:-8888}"

podman rm -f fgo-artemis fgo-mariadb >/dev/null 2>&1 || true
podman pod rm -f "$POD" >/dev/null 2>&1 || true

# ⚠️ Port 777 : podman rootless ne peut pas lier un port privilégié. Soit
#   sysctl net.ipv4.ip_unprivileged_port_start=777  (vérifier d'abord qu'aucun
#   service n'écoute entre 777 et 1023), soit déplacer le port ALL.Net des deux
#   côtés via Server/tools/fgo_server_config.py.
podman pod create --name "$POD" \
  -p 0.0.0.0:777:777 -p 0.0.0.0:9999:9999 -p 0.0.0.0:7777:7777 >/dev/null

# ⚠️ MariaDB 10.11 : le data/ du paquet porte mysql_upgrade_info = 10.11.16.
# L'image officielle démarre dessus sans migration, y compris sur un jeu de
# données créé sous Windows.
podman run -d --pod "$POD" --name fgo-mariadb \
  -v "$SERVEUR/data/mariadb:/var/lib/mysql:Z" \
  docker.io/library/mariadb:10.11 --port="$PORT_DB" \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci >/dev/null

sleep 15

podman run -d --pod "$POD" --name fgo-artemis \
  -v "$SERVEUR/artemis:/app:Z" \
  -v "$SERVEUR:/Server:ro" \
  -v "$CLIENT/App:/App:ro" \
  -v "$CLIENT/DEVICE:/DEVICE:ro" \
  -v "${FGOAC_LOGS:-$SERVEUR/../logs}:/logs:Z" \
  -w /app "$IMAGE" >/dev/null

sleep 15
echo "état :"
podman ps --format "  {{.Names}}  {{.Status}}"
echo "contrôle de santé ALL.Net :"
curl -sS -o /tmp/fgoac-sante -w "  HTTP %{http_code}  " --max-time 8 http://127.0.0.1:777/ || true
cat /tmp/fgoac-sante 2>/dev/null; echo
echo
echo "⚠️  Si le jeu reste bloqué, lire d'abord logs/fgo_capture/failures.jsonl :"
echo "    ARTEMiS y enregistre chaque échec de gestionnaire (commande, type et"
echo "    message d'exception) avant de la relancer. Les journaux ordinaires"
echo "    n'en montrent RIEN."
