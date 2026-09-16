# Moonshine sur enlil -- un GPU par session de streaming.
#
# ── POURQUOI SUR CETTE MACHINE ───────────────────────────────────────────────
# enlil porte DEUX GPU, et le portage de FGO Arcade a besoin des deux :
#
#   01:00.0  10de:28e0  NVIDIA RTX 4060 Laptop   renderD129   -> JOUER
#   65:00.0  1002:1900  AMD Radeon 780M (RDNA3)  renderD128   -> CHERCHER
#
# Jusqu'ici on basculait de l'un a l'autre en SSH, avec ~/jouer.sh et
# ~/chercher-amd.sh. Moonshine ouvre un compositeur PAR SESSION : chaque GPU
# devient une entree distincte dans la liste Moonlight, et le choix se fait
# depuis le client, sans terminal.
#
# ⚠️ CE QUI RESTE EXCLUSIF, et c'est une limite REELLE, pas un oubli.
# Les deux entrees partagent ~/fgo-install/App, et la bascule NVIDIA/AMD se
# joue sur la PRESENCE d'un fichier -- App/opengl32.dll, le shim de fluphus
# (voir docs/MATERIEL.md). Deux sessions simultanees se marcheraient dessus, et
# le cache App/shader-cache-r2 serait ecrase de la meme facon. Les lanceurs
# ci-dessous REFUSENT donc de demarrer si l'autre variante tourne, au lieu de
# corrompre en silence.
# Pour les faire cohabiter -- ce qu'il faudra pour tester le multijoueur a deux
# clients sur une seule machine -- il faut un SECOND arbre App. Piste non
# mesuree a essayer avant de copier des giga-octets : garder le shim en place
# en permanence et le neutraliser cote NVIDIA par WINEDLLOVERRIDES=opengl32=b
# (builtin), au lieu de deplacer le fichier.
#
# ── LE MODULE VIENT DE NIXPKGS, PAS DE L'AMONT ───────────────────────────────
# Contrairement a ishtar (cishtar/moonshine.nix, qui prend le module du depot
# amont), le nixpkgs epingle ici LE CONTIENT.
#   rev 9fbb54b33e91ee4ca368e35a78e0613c720600b3
#   nixos/modules/services/networking/moonshine.nix   -> HTTP 200
#   temoin sunshine.nix au meme rev                   -> HTTP 200
# Donc : pas d'input flake a ajouter, et pas de `disabledModules` -- la
# collision d'options qui oblige ishtar a en declarer un n'existe pas ici.
#
# ⚠️ Ses options NE SONT PAS celles du module amont. Il n'a ni `uid`, ni
# `openFirewall`, ni `logFilter`. Il a en revanche `firewallInterfaces`,
# `environment` et `extraPackages`.
{ config, pkgs, lib, ... }:

let
  # ── NETTOYAGE DES RESTES ──────────────────────────────────────────────────
  # Meme mecanique que sur ishtar : on note les scopes systemd presents AVANT
  # la session, on n'arrete APRES que ceux apparus depuis. Un arret aveugle
  # tuerait un jeu lance depuis le bureau mango, qui est l'usage normal ici.
  scopesAvant = pkgs.writeShellScript "moonshine-scopes-avant" ''
    ${pkgs.systemd}/bin/systemctl --user list-units --type=scope --no-legend --plain \
      | ${pkgs.gawk}/bin/awk '{print $1}' > /run/user/1000/moonshine-scopes-avant
  '';
  scopesApres = pkgs.writeShellScript "moonshine-scopes-apres" ''
    ${pkgs.coreutils}/bin/touch /run/user/1000/moonshine-scopes-avant
    ${pkgs.systemd}/bin/systemctl --user list-units --type=scope --no-legend --plain \
      | ${pkgs.gawk}/bin/awk '{print $1}' \
      | ${pkgs.gnugrep}/bin/grep -vxF -f /run/user/1000/moonshine-scopes-avant \
      | while read -r s; do ${pkgs.systemd}/bin/systemctl --user stop "$s" || true; done
  '';

  # ── LE TRONC COMMUN DES DEUX LANCEURS ─────────────────────────────────────
  #
  # ⚠️ ON NE FIXE NI WAYLAND_DISPLAY NI DISPLAY. Moonshine cree son propre
  # compositeur et les pose lui-meme (application.rs:225). Les ecraser
  # renverrait la fenetre sur l'ecran physique au lieu du flux -- exactement
  # ce que font ~/jouer.sh et ~/chercher-amd.sh, qui sont ecrits pour une
  # session locale et ne conviennent PAS ici.
  communFgo = ''
    set -u
    export WINEPREFIX=/home/ezvk/Games/Heroic/Prefixes/FGOA
    export PROTONPATH=/home/ezvk/.config/heroic/tools/proton/GE-Proton11-5-x86_64
    export GAMEID=umu-default
    export SEGATOOLS_CONFIG_PATH="X:\fgo-install\DEVICE\runtime\segatools.runtime.ini"
    export FGO_INSTALL_ROOT="X:\fgo-install"
    export FGO_TARGET_FPS=60 FGO_LOCAL_NETWORK=0
    export FGO_LOCAL_HTTP_PORT=777 FGO_LOCAL_BILLING_PORT=9999 FGO_LOCAL_AIME_PORT=7777
    export FGO_ZH_ENABLED=0 FGO_FULL_SURFACE_FBO=1

    # ⚠️ Chemin complet vers pgrep : le PATH de l'unite Moonshine ne porte que
    # coreutils, findutils, gnugrep, gnused, systemd et xwayland -- pas procps.
    PGREP=${pkgs.procps}/bin/pgrep

    # Exclusion mutuelle -- voir le bloc en tete de fichier.
    if [ -e /run/user/1000/fgo-gpu-actif ]; then
      autre=$(${pkgs.coreutils}/bin/cat /run/user/1000/fgo-gpu-actif)
      if [ "$autre" != "$FGO_VARIANTE" ] && $PGREP -x -u ezvk ago.exe >/dev/null 2>&1; then
        echo "REFUS : une session FGO tourne deja sur $autre." >&2
        echo "Fermer l autre session Moonlight avant de lancer $FGO_VARIANTE." >&2
        exit 1
      fi
    fi
    echo "$FGO_VARIANTE" > /run/user/1000/fgo-gpu-actif

    # Le launcher d'origine tue les restes avant de lancer : pre-demarrer
    # AMDaemon casse la poignee de main d'etat du processus.
    for n in ago.exe amdaemon.exe inject.exe; do
      for pid in $($PGREP -x -u ezvk "$n" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null || true
      done
    done
    sleep 1

    cd /home/ezvk/fgo-install/App || exit 1
  '';

  # ── NVIDIA : LA CONFIGURATION QUI FONCTIONNE ──────────────────────────────
  # Sans shim, cache de shaders vide, rendu force sur la 4060 par PRIME.
  # Le shim casse la compilation des shaders sur NVIDIA :
  #   0(763) : error C1068  (_amdshim_map_handle_pairs)
  lancerFgoNv = pkgs.writeShellScript "moonshine-fgo-nvidia" ''
    export FGO_VARIANTE=nvidia
    ${communFgo}
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    if [ -f opengl32.dll ]; then
      ${pkgs.coreutils}/bin/mkdir -p /home/ezvk/shim-de-cote
      ${pkgs.coreutils}/bin/mv -f opengl32.dll opengl32real.dll /home/ezvk/shim-de-cote/ 2>/dev/null || true
      ${pkgs.coreutils}/bin/rm -rf shader-cache-r2
      ${pkgs.coreutils}/bin/mkdir -p shader-cache-r2
    fi
    # ⚠️ run-nvidia.bat, PAS run-nv.bat. run-nv.bat traine sur cette machine
    # depuis un essai en -wqhd (2560x1440) qui n a jamais tourne ici.
    # run-nvidia.bat est la copie exacte de l invocation PROUVEE le 2026-09-16
    # (-hdtv1080), au nom de journal pres : inject-nvidia.log au lieu de
    # inject-amd.log, pour que les deux variantes cessent d ecrire dans le
    # meme fichier -- ce que faisait ~/jouer.sh, qui appelait run-amd.bat tout
    # en s annoncant NVIDIA.
    exec ${pkgs.umu-launcher}/bin/umu-run cmd.exe /c "X:\fgo-install\App\run-nvidia.bat"
  '';

  # ── AMD : POUR CHERCHER, NE FONCTIONNE PAS ENCORE ─────────────────────────
  # Mesa n'expose ni GL_NV_bindless_texture ni GL_NV_shader_buffer_load, et ce
  # dernier n'a AUCUN equivalent ARB (docs/MATERIEL.md). Le shim de fluphus est
  # l'emulation necessaire, mais il echoue sous Wine a ago.exe+0xC084F7.
  #
  # ⚠️ Une solution tierce existe : le patch AMD de @Vancion, valide sur RX
  # 9070XT (docs/ARBRE.md §6.2). Il n'est PAS encore recupere, et rien ne dit
  # qu'il couvre un iGPU. Cette entree reste donc un banc d'essai.
  lancerFgoAmd = pkgs.writeShellScript "moonshine-fgo-amd" ''
    export FGO_VARIANTE=amd
    ${communFgo}
    # Pas de PRIME : on veut precisement le rendu sur le 780M.
    export DRI_PRIME=0
    export WINEDLLOVERRIDES="opengl32=n,b"
    ${pkgs.coreutils}/bin/cp -f /home/ezvk/shim-de-cote/opengl32.dll . 2>/dev/null || true
    ${pkgs.coreutils}/bin/cp -f /home/ezvk/shim-de-cote/opengl32real.dll . 2>/dev/null || true
    ${pkgs.coreutils}/bin/rm -rf shader-cache-r2
    ${pkgs.coreutils}/bin/mkdir -p shader-cache-r2
    exec ${pkgs.umu-launcher}/bin/umu-run cmd.exe /c "X:\fgo-install\App\run-amd.bat"
  '';
in
{
  services.moonshine = {
    enable = true;
    user = "ezvk";

    # Le module n'a pas d'`openFirewall` : il faut NOMMER les interfaces, et il
    # n'ouvre rien si la liste est vide. L'amont avertit de ne pas exposer ces
    # ports a Internet.
    #   tailscale0    100.127.65.87  -- l'usage nomade
    #   wlp3s0        192.168.1.29   -- le wifi du lab
    #   enp101s0f3u1  192.168.1.190  -- l'ethernet du dock
    firewallInterfaces = [ "tailscale0" "wlp3s0" "enp101s0f3u1" ];

    # ── SUR QUELLE CARTE TOURNE LE COMPOSITEUR ET L'ENCODEUR ────────────────
    #
    # Les deux GPU savent encoder. Mesure du 2026-09-16, `vulkaninfo` :
    #   AMD Radeon 780M (RADV PHOENIX) : encode av1, h264, h265, intra_refresh,
    #                                    quantization_map, queue,
    #                                    + VK_VALVE_video_encode_rgb_conversion
    #   NVIDIA RTX 4060 Laptop         : encode av1, h264, h265, intra_refresh,
    #                                    quantization_map, queue
    # (temoin : VK_KHR_swapchain present 9 fois -- le releve a bien tourne.)
    #
    # ON CHOISIT L'AMD, et ce n'est pas arbitraire. La lecon d'ishtar
    # (cishtar/moonshine.nix, 2026-09-03) est qu'un DMA-BUF ne traverse pas
    # d'une carte a l'autre sans peine : rendre sur l'une et encoder sur
    # l'autre donnait "No suitable memory type for DMA-BUF import", flux vide.
    # Ici les deux sessions doivent partager UN compositeur. Donc :
    #
    #   compositeur sur l'AMD  -> session AMD    : meme carte, zero-copie
    #                          -> session NVIDIA : PRIME offload, le sens
    #                             NORMAL sur un portable hybride (l'iGPU est
    #                             le moteur d'affichage).
    #   compositeur sur NVIDIA -> session NVIDIA : zero-copie
    #                          -> session AMD    : reverse-PRIME, le sens
    #                             FRAGILE, celui qui a echoue sur ishtar.
    #
    # On place donc le point dur du cote qui a une route eprouvee.
    #
    # ⚠️ BASCULE si le flux NVIDIA se revele mauvais : passer les deux reglages
    # ci-dessous sur 10de:28e0 / pci-0000:01:00.0, et REMESURER les deux
    # sessions -- pas seulement celle qu'on vient de favoriser.
    environment = {
      # Noms releves dans libVkLayer_MESA_device_select.so (mesure ishtar),
      # pas devines. La couche filtre la liste des VkPhysicalDevice : le
      # service n'ouvre plus qu'une carte, compositeur ET encodeur compris.
      #
      # L'identifiant PCI vendor:device est stable quel que soit l'ordre au
      # boot -- contrairement a renderD128/129, qui peuvent permuter.
      #
      # Le module documente que ces variables ne sont PAS heritees par les
      # applications lancees. C'est ce qui rend ce reglage sans danger pour la
      # session NVIDIA, qui doit voir sa carte.
      MESA_VK_DEVICE_SELECT = "1002:1900";
      MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE = "1";
    };

    # ⚠️ CHAQUE TABLE DECLAREE DOIT L'ETRE EN ENTIER. Les structures de
    # Moonshine n'ont pas de defaut par champ : declarer [webserver] sans
    # `certificate` fait echouer l'analyse TOML au demarrage.
    settings = {
      # Nom DISTINCT de "enlil" tout court et de Sunshine : les deux
      # s'annoncent en mDNS et on doit pouvoir les distinguer dans Moonlight.
      name = "enlil-moonshine";
      address = "0.0.0.0";
      inhibit_sleep = true;

      webserver = {
        port = 47989;
        port_https = 47984;
        enable_pairing = true;
        # Ecrits au premier demarrage. Doivent etre dans un chemin
        # INSCRIPTIBLE -- pas le magasin Nix.
        certificate = "$HOME/.config/moonshine/cert.pem";
        private_key = "$HOME/.config/moonshine/key.pem";
      };

      stream = {
        port = 48010; # RTSP
        timeout = 60;
        video = {
          port = 47998;
          fec_percentage = 20;
          encrypt = false;
          log_frame_spikes = false;
        };
        audio.port = 48000;
        control.port = 47999;
      };

      compositor = {
        # PAR CHEMIN PCI, jamais par renderD128 : la numerotation DRM peut
        # changer d'un demarrage a l'autre. find_render_node accepte un chemin
        # absolu tel quel. Sans ce reglage il note les noeuds -- 100 pour
        # 10DE, 50 pour AMD -- et prendrait donc la NVIDIA.
        gpu = "/dev/dri/by-path/pci-0000:65:00.0-render";
        hdr = true;
        keyboard = {
          layout = "fr";
          variant = "";
          model = "";
        };
      };

      application = [
        {
          # ⚠️ `dbus-run-session` n'est pas decoratif : sans lui, un dialogue
          # servi par un portail s'ouvre sur l'ECRAN PHYSIQUE et reste
          # invisible depuis le flux.
          title = "Desktop";
          command = [
            "/run/current-system/sw/bin/dbus-run-session"
            "--"
            "/run/current-system/sw/bin/mango"
          ];
          # Pas de pre/post_command : sur le bureau, tout ce qu'on ouvre
          # apparait forcement pendant la session et serait tue en partant.
        }
        {
          title = "FGO Arcade (NVIDIA)";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          command = [
            "/run/current-system/sw/bin/dbus-run-session"
            "--"
            "${lancerFgoNv}"
          ];
          # ⚠️ NE PAS MONTER AU-DELA DE 60. Cette valeur ne mesure PAS le
          # demarrage du jeu : elle attend que l'UNITE systemd passe active
          # (application.rs:169), ce qui arrive des que le processus demarre.
          # Le webserver a son propre plafond de 60 s EN DUR
          # (webserver/mod.rs:837) ; au-dela il demonte la session. Constate
          # sur ishtar le 2026-09-16 avec 120 : le jeu demarrait, la session
          # etait coupee avant qu'il aboutisse.
          launch_timeout_secs = 30;
        }
        {
          title = "FGO Arcade (AMD - recherche)";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          command = [
            "/run/current-system/sw/bin/dbus-run-session"
            "--"
            "${lancerFgoAmd}"
          ];
          launch_timeout_secs = 30;
        }
      ];
    };
  };

  # Le module cree le groupe `moonshine` et lui donne, par une regle polkit
  # livree dans le paquet, le droit de prendre un inhibiteur de veille `block`.
  # Sans appartenance au groupe le service demarre quand meme, mais journalise
  # "Cannot acquire sleep inhibit: InteractiveAuthorizationRequired" et la
  # machine peut s'endormir en plein flux.
  users.users.ezvk.extraGroups = [ "moonshine" ];

  # ── COHABITATION AVEC SUNSHINE ────────────────────────────────────────────
  # configuration.nix garde services.sunshine.enable = true avec
  # autoStart = false. Les deux occupent LES MEMES ports GameStream ; ils ne
  # peuvent pas ecouter en meme temps. Sunshine reste installe et lancable a la
  # main, Moonshine prend les ports au demarrage. Si on veut Sunshine
  # ponctuellement : `systemctl stop moonshine` d'abord.
  # Mesure du 2026-09-16 avant d'ecrire ce fichier : sunshine inactif, et
  # aucun processus n'ecoutait sur 47984/47989/47998/47999/48000/48010.
}
