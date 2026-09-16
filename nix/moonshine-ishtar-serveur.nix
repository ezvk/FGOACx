# Moonshine -- serveur de streaming pour clients Moonlight. Remplace Sunshine,
# retire le 2026-08-25.
#
# ── POURQUOI ─────────────────────────────────────────────────────────────────
# Sunshine capture un ecran existant. C'est ce qui nous a impose quatre
# contournements, tous encore dans configuration.nix :
#   - le patch `substituteInPlace` qui injectait GBM_BO_USE_SCANOUT dans
#     wayland.cpp (un --replace-fail qui cassait le build a chaque montee) ;
#   - settings.capture = "wlr", epingle parce que le sondage choisissait KMS ;
#   - settings.output_name = "DP-2", une sortie VIRTUELLE creee expres ;
#   - cudaSupport = true.
# Les quatre ont ete retires le 2026-08-25, en meme temps que Sunshine.
#
# Moonshine n'a besoin d'aucun des quatre : il ouvre son PROPRE compositeur par
# session, se configure a la resolution demandee par le client, et encode par
# Vulkan Video. Mesure du 2026-08-25, Steam Big Picture en 1920x1080 :
# 60 images/s soutenues, encodage p50 = 1,40 ms, total hote p50 = 3,2 ms,
# 0,00 % de perte reseau. Manette DualSense recreee en vrai peripherique HID PS5
# (054C:0CE6) via uhid, capteurs de mouvement compris.
#
# ── PORTS STANDARD ───────────────────────────────────────────────────────────
# Moonshine a d'abord tourne sur des ports decales de +1000, pour cohabiter avec
# Sunshine pendant l'essai -- les deux ont tourne en meme temps le 2026-08-25,
# chacun repondant sur son /serverinfo. Sunshine ayant ete retire le meme jour,
# on revient aux ports standard GameStream : c'est ce que Moonlight attend sans
# qu'on ait a lui preciser un port.
#
# /!\ CONSEQUENCE : les clients apparies sur les ports decales doivent etre
# reapparies. L'etat vit dans ~/.local/share/moonshine/state.toml.
#
# ── LE MODULE VIENT DE L'AMONT ───────────────────────────────────────────────
# nixpkgs a bien un module (nixos/modules/services/networking/moonshine.nix),
# mais il est ABSENT du rev epingle ici (f13ff45, 07/08 -- verifie : HTTP 404,
# temoin sunshine.nix au meme rev : HTTP 200). On prend donc celui du depot
# amont, dans nix/module.nix.
#
# Il fait des choses qu'on n'inventerait pas a la main. La principale : il
# installe la couche WSI Vulkan dans /run/opengl-driver/share. Une couche
# *implicite* n'est trouvee que si son manifeste est dans un repertoire scanne,
# or un service systemd n'a pas de XDG_DATA_DIRS. Sans ca, tout retombe
# SILENCIEUSEMENT sur XWayland -- ca "marche", en degrade, sans un message.
{ inputs, pkgs, ... }:

# ── NETTOYAGE DES JEUX ORPHELINS ─────────────────────────────────────────────
#
# Le probleme, constate plusieurs fois les 30 et 31/08 : quand une session de
# streaming se termine alors qu'un jeu tourne, Moonshine arrete bien son
# application (Heroic, Lutris, Steam) mais PAS le jeu. Celui-ci a ete lance par
# le lanceur dans un scope systemd FRERE de moonshine-session.service :
#
#   moonshine-session.service        <- ce que Moonshine detruit
#   app-heroic-235671.scope          <- ou vit le jeu, hors de portee
#
# Le jeu survit donc, invisible, en brulant du CPU et de la VRAM. Mesure le
# 30/08 : un orphelin a 643 % de CPU et 3,3 Go de VRAM.
#
# ⚠️ ET IL DETRUIT LE CACHE DE SHADERS. Deux instances du meme jeu ecrivent le
# meme `vkd3d-proton.cache` : la seconde ecrase le travail de la premiere. Le
# 30/08 a 20:05, le cache de Nioh 3 est passe de 3,6 Mo a 18 Ko de cette facon,
# soit une recompilation complete de 15 396 shaders a refaire.
#
# LA METHODE : le DIFFERENTIEL. On note les scopes existants avant la session,
# on n'arrete apres que ceux apparus depuis. Un `killall` aveugle tuerait aussi
# un jeu lance depuis le bureau mango, qui est l'usage normal de cette machine.
#
# Angle mort assume : un jeu lance depuis le bureau PENDANT un stream serait
# ramasse. Cas de bord, et le seul moyen de l'eviter serait de suivre les
# processus un par un.
let
  scopesAvant = pkgs.writeShellScript "moonshine-scopes-avant" ''
    systemctl --user list-units 'app-*.scope' --plain --no-legend \
      | awk '{print $1}' > /run/user/1000/moonshine-scopes-avant
  '';

  scopesApres = pkgs.writeShellScript "moonshine-scopes-apres" ''
    # `touch` d'abord : si la session s'est ouverte sans pre_command (redemarrage
    # de Moonshine en cours de route), le fichier n'existe pas et `grep -f`
    # echouerait, ce qui ferait tout arreter.
    touch /run/user/1000/moonshine-scopes-avant
    systemctl --user list-units 'app-*.scope' --plain --no-legend \
      | awk '{print $1}' \
      | grep -vxF -f /run/user/1000/moonshine-scopes-avant \
      | xargs -r systemctl --user stop
  '';
  # FGO Arcade — plateforme locale Cloud23333, lancee SANS son launcher.
  #
  # ⚠️ POURQUOI PAS `FGOAC scooby.exe` : toute sa chaine est en PowerShell, que
  # Wine ne fournit pas. PowerShell 7 portable installe dans le prefixe ne
  # s execute pas davantage — temoin du 2026-09-16 : `pwsh -Command "exit 42"`
  # rend 0 et n ecrit aucun fichier. On appelle donc `inject.exe` directement,
  # apres avoir reproduit ce que le launcher preparait : segatools.runtime.ini
  # en UTF-16 avec BOM, amdaemon_main.json, et les variables FGO_*.
  #
  # ⚠️ PAS de PROTON_ENABLE_WAYLAND, contrairement a Steam plus bas. Le jeu est
  # en OpenGL et passe par winex11.drv ; c est la chaine mesuree fonctionnelle
  # le 2026-09-16. On ne la change pas a l aveugle.
  #
  # ⚠️ ON NE FIXE NI WAYLAND_DISPLAY NI DISPLAY : Moonshine cree son propre
  # compositeur et les pose lui-meme. Les ecraser renverrait la fenetre sur
  # l ecran physique au lieu du flux.
  # ── L'INI ET LE .BAT SONT FABRIQUES A CHAQUE SESSION ──────────────────────
  #
  # Porte depuis enlil le 2026-09-16. Sans cela, l'image est coupee des que le
  # client Moonlight demande une resolution differente de celle figee dans
  # segatools.runtime.ini. Constate sur ishtar le meme jour :
  #   Gfx: Main window client created at 2560x1440 ... current=1920x1080@60
  # soit 360 lignes perdues.
  #
  # On lit ce que le CLIENT a demande. Moonshine l'expose dans l'environnement
  # de la session -- releve sur /proc/<pid>/environ d'ago.exe, pas devine :
  #   MOONSHINE_CLIENT_WIDTH / MOONSHINE_CLIENT_HEIGHT / MOONSHINE_CLIENT_FRAMERATE
  #
  # ⚠️ ON DERIVE segatools.stream.ini DE segatools.runtime.ini, on ne le
  # regenere PAS avec generer-runtime.py : runtime.ini porte l'IDENTITE DE LA
  # BORNE (keychip A69E-01B88888888, pcbid ACAE01B99999999, addrSuffix 43),
  # distincte de celle d'enlil pour que le serveur voie deux joueurs. La
  # regenerer d'ici l'ecraserait.
  #
  # ⚠️ L'INI DOIT ETRE EN UTF-16LE AVEC BOM. GetPrivateProfileStringW l'exige.
  # Sans cela : "Resolution mode: native-surface patch failed (hr=80070057)
  # Win32=203" et le jeu refuse de demarrer.
  preparerSession = pkgs.writeText "fgo-preparer-session.py" ''
    """Derive l ini et le .bat de la session a partir de la resolution client."""
    import pathlib, re, sys

    largeur, hauteur = int(sys.argv[1]), int(sys.argv[2])
    import os
    # ── ROLE DE BORNE ET MATCHING SERVER ──────────────────────────────────
    # Releve dans l aide de ago.exe le 2026-09-16, pas devine :
    #     -sm <server|satellite>    Startup Mode
    #     -ntvs_local_ms_ip <adresse>
    # plus -ntvs_port, -ntvs_lan_ifno, -ntvs_use_sw_num, -ntvs_pc,
    # -ntvs_spe_rank. NTVS est le prefixe de l API reseau du client :
    # NTVS_MATCHING, NTVS_MS_PING, connect_ms, connect_gs, is_room_creator.
    #
    # Le launcher d origine met cabinetMode = "saved" et ne passe donc PAS
    # -sm : la borne demarre en autonome, ce qui explique qu aucun appariement
    # ne se declenche jamais et qu UDP 30001 reste muet des deux cotes.
    # Dans une salle, une borne est SERVEUR ou SATELLITE -- l amdaemon a
    # d ailleurs deja lan_install.server = True.
    #
    # ⚠️ ESSAI EN COURS, resultat inconnu. Vide = comportement d avant.
    role = os.environ.get("FGO_SM", "").strip()
    ms_ip = os.environ.get("FGO_MS_IP", "").strip()
    racine = pathlib.Path("/home/ezvk/fgo-install")
    src = racine / "DEVICE/runtime/segatools.runtime.ini"
    dst = racine / "DEVICE/runtime/segatools.stream.ini"

    brut = src.read_bytes()
    if brut[:2] != b"\xff\xfe":
        sys.exit(f"BOM UTF-16LE attendu dans {src}, trouve {brut[:4]!r}")
    texte = brut.decode("utf-16")

    valeurs = {
        "resolutionWidth": largeur, "resolutionHeight": hauteur,
        "width": largeur, "height": hauteur,
        "logicalWidth": largeur, "logicalHeight": hauteur,
    }
    vus = set()

    def remplacer(m):
        vus.add(m.group(1))
        return f"{m.group(1)}={valeurs[m.group(1)]}"

    texte = re.sub(r"(?m)^(" + "|".join(valeurs) + r")=\d+", remplacer, texte)
    manquantes = set(valeurs) - vus
    if manquantes:
        sys.exit(f"cles absentes de {src}, refus : {sorted(manquantes)}")
    dst.write_bytes(b"\xff\xfe" + texte.encode("utf-16-le"))

    # Meme calcul que FGO_Launcher.ps1:379-402, repris de client/generer-runtime.py.
    g, d = largeur * 9, hauteur * 16
    if g > d:
        mode = "-wqhd"
    elif g == d:
        mode = "-hdtv720" if (largeur <= 1280 and hauteur <= 720) else (
            "-hdtv1080" if largeur < 2560 and hauteur < 1440 else "-wqhd")
    else:
        mode = "-wqhd" if largeur >= 2560 else "-hdtv1080"

    app = "X:\\fgo-install\\App"
    jrn = "X:\\fgo-install\\logs\\inject-stream.log"
    ntvs = ""
    if role:
        ntvs += f" -sm {role}"
    if ms_ip:
        ntvs += f" -ntvs_local_ms_ip {ms_ip}"

    bat = racine / "App" / "run-stream.bat"
    bat.write_text(
        "@echo off\r\n"
        f"cd /d {app}\r\n"
        f'inject.exe -d -k "{app}\\fgostub.dll" -k "{app}\\fgohook.dll" '
        f'"{app}\\ago.exe" {mode}{ntvs} -w --wasapi-shared > {jrn} 2>&1\r\n'
        f"echo EXITCODE=%ERRORLEVEL% >> {jrn}\r\n"
    )
    print(f"session : {largeur}x{hauteur} {mode}")
  '';

  lancerFgo = pkgs.writeShellScript "moonshine-fgo-arcade" ''
    set -u
    export WINEPREFIX=/home/ezvk/Games/Heroic/Prefixes/FGOA
    export PROTONPATH=/home/ezvk/.config/heroic/tools/proton/Proton-GE-Proton11-6
    export GAMEID=umu-default
    export SEGATOOLS_CONFIG_PATH="X:\fgo-install\DEVICE\runtime\segatools.stream.ini"
    export FGO_INSTALL_ROOT="X:\fgo-install"
    export FGO_TARGET_FPS=60 FGO_LOCAL_NETWORK=0
    export FGO_LOCAL_HTTP_PORT=777 FGO_LOCAL_BILLING_PORT=9999 FGO_LOCAL_AIME_PORT=7777
    export FGO_ZH_ENABLED=0 FGO_FULL_SURFACE_FBO=1
    export FGO_SMAA=0 FGO_RENDER_SCALE=100
    # Essai du 2026-09-16 : donner un ROLE a la borne. ishtar est la borne
    # SERVEUR de la salle ; enlil est reglee en satellite et pointe ici.
    export FGO_SM="server"
    export FGO_MS_IP=""
    export FGO_SHADOW_RESOLUTION=1024 FGO_ANISOTROPY=16 FGO_MOTION_BLUR=0
    export FGO_DEPTH_OF_FIELD=1 FGO_BLOOM=1 FGO_HIDE_UI=0 FGO_HIDE_UI_KEY=121
    export FGO_HIDE_TARGET_LINES=1 FGO_DISABLE_CAMERA_SHAKE=1 FGO_HIDE_CABINET_HUD=1
    export FGO_TEXTURE_QUALITY=0

    # Le launcher d origine tue les restes avant de lancer : l auteur note que
    # pre-demarrer AMDaemon casse la poignee de main d etat du processus.
    # ⚠️ Chemin complet vers pgrep : le PATH de l unite Moonshine ne porte que
    # coreutils, findutils, gnugrep, gnused, systemd et xwayland — pas procps.
    for n in ago.exe amdaemon.exe inject.exe; do
      for pid in $(${pkgs.procps}/bin/pgrep -x -u ezvk "$n" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null || true
      done
    done
    sleep 1

    cd /home/ezvk/fgo-install/App || exit 1

    # Resolution demandee par le client Moonlight. Les valeurs de repli ne
    # servent que si on lance ce script a la main, hors session.
    ${pkgs.python3}/bin/python3 ${preparerSession} \
      "''${MOONSHINE_CLIENT_WIDTH:-1920}" "''${MOONSHINE_CLIENT_HEIGHT:-1080}" || exit 1
    exec ${pkgs.umu-launcher}/bin/umu-run cmd.exe /c "X:\fgo-install\App\run-stream.bat"
  '';
in
{
  imports = [ inputs.moonshine.nixosModules.default ];

  # ── COLLISION AVEC LE MODULE DE NIXPKGS ─────────────────────────────────────
  #
  # Depuis nixpkgs 34ab9907 (2026-09-01), Moonshine est empaquete DANS nixpkgs,
  # module compris : nixos/modules/services/networking/moonshine.nix. Il declare
  # `services.moonshine.enable`, que le module du flake amont declare deja. Deux
  # declarations de la meme option = erreur d'evaluation, systeme inconstruisible :
  #
  #   error: The option `services.moonshine.enable' in `...nixpkgs/.../moonshine.nix'
  #          is already declared in `...moonshine-source/nix/module.nix'.
  #
  # On garde le module AMONT et on ecarte celui de nixpkgs. Les deux empaquettent
  # la meme version (0.15.0, verifie le 2026-09-02), le choix est donc sans effet
  # sur le binaire -- mais tout ce fichier est ecrit contre le schema d'options du
  # module amont, `applications` avec ses `pre_command`/`post_command` en tete.
  # Changer de schema pendant une mise a jour de la pile 3D melangerait deux
  # chantiers, et c'est precisement ce qu'on evite.
  #
  # À RECONSIDERER : le jour ou nixpkgs sera la seule source raisonnable, migrer
  # vers son module permettrait de retirer l'input `moonshine` du flake. Verifier
  # alors que `applications`, `pre_command` et `post_command` existent bien dans
  # son schema -- sans quoi le nettoyage des jeux orphelins disparait en silence.
  disabledModules = [ "services/networking/moonshine.nix" ];

  services.moonshine = {
    enable = true;

    # L'assertion du module exige un uid : soit users.users.ezvk.uid est
    # declare, soit on le donne ici. Mesure : `id -u ezvk` -> 1000.
    user = "ezvk";
    uid = 1000;

    # Meme posture que Sunshine aujourd'hui (openFirewall = true). L'amont
    # avertit de ne PAS exposer ces ports a Internet : ishtar est derriere la
    # box, et l'usage reel passe par Tailscale.
    openFirewall = true;

    # Un client Moonlight pose sur son ecran "Ordinateurs" sonde le port HTTPS
    # toutes les 5 s ; sans ce filtre le journal se remplit de
    # "TLS handshake failed". Recommande par la doc du module.
    logFilter = "moonshine=info,moonshine_core::tls=error";

    # ⚠️ CHAQUE TABLE DECLAREE DOIT L'ETRE EN ENTIER.
    # Les structures de Moonshine n'ont pas de defaut par champ : declarer
    # [webserver] sans `certificate` fait echouer l'analyse TOML au demarrage --
    # constate le 2026-08-25 :
    #   Failed to parse configuration file: TOML parse error at line 30
    #   [webserver] ^^^^ missing field `certificate`
    # La reference se genere avec le binaire lui-meme : lui passer un chemin
    # inexistant, il ecrit la configuration par defaut et sort.
    settings = {
      # Nom DISTINCT de celui de Sunshine : les deux s'annoncent en mDNS et on
      # doit pouvoir les distinguer dans Moonlight.
      name = "ishtar-moonshine";
      address = "0.0.0.0";
      inhibit_sleep = true;

      webserver = {
        port = 47989;
        port_https = 47984;
        enable_pairing = true;
        # Ecrits au premier demarrage s'ils n'existent pas. Doivent donc etre
        # dans un chemin INSCRIPTIBLE -- pas le magasin Nix.
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
        # ── SUR QUELLE CARTE ────────────────────────────────────────────────
        #
        # Sans ce reglage, find_render_node (healthcheck.rs:1158) note les
        # noeuds -- 100 pour PCI_ID=10DE, 50 pour AMD -- et prend le meilleur
        # PAR ORDRE ALPHABETIQUE. Avec deux NVIDIA, ca tombait sur renderD128 :
        #
        #     renderD128   0000:01:00.0   10DE:2805   RTX 4060 Ti
        #     renderD129   0000:05:00.0   10DE:2503   RTX 3060
        #
        # Autrement dit le compositeur ET l'encodage tournaient sur la 4060 Ti,
        # exactement la carte qu'on veut laisser aux jeux. On les bascule sur
        # la 3060.
        #
        # ⚠️ PAR CHEMIN PCI, jamais par renderD129 : la numerotation DRM de
        # cette machine change d'un demarrage a l'autre (voir la regle udev de
        # configuration.nix, qui epingle deja la 3060 pour la meme raison).
        # find_render_node accepte un chemin absolu tel quel.
        # ⚠️ NE PAS EPINGLER. Essaye le 2026-09-03 avec la 3060, resultat :
        #
        #     Failed to import DMA-BUF: No suitable memory type for DMA-BUF import
        #     No frames received for 5 seconds
        #
        # Aucune image, un flux vide. La raison : `gpu` ne deplace QUE le
        # compositeur. L encodeur NVENC n a aucun reglage equivalent et reste
        # sur le peripherique CUDA 0, soit la 4060 Ti. La trame est alors
        # rendue sur une carte et doit etre importee par l autre -- ce qu un
        # DMA-BUF ne sait pas faire entre deux NVIDIA discretes sans NVLink.
        # Exactement la limite deja rencontree avec Wolf le 2026-09-01.
        #
        # Consequence a accepter : separer le rendu du jeu et l encodage sur
        # deux cartes n est PAS possible dans cette architecture. Le zero-copie
        # impose les deux au meme endroit. Laisser le defaut, qui prend le
        # premier NVIDIA par ordre alphabetique -- renderD128, la 4060 Ti.
        # gpu = "/dev/dri/by-path/pci-0000:05:00.0-render";

        hdr = true;
        keyboard = {
          layout = "fr";
          variant = "";
          model = "";
        };
      };

      # Les defauts amont pointent /usr/bin/steam, qui n'existe pas sur NixOS :
      # il FAUT declarer application.
      application = [
        {
          # ── LE BUREAU ──────────────────────────────────────────────────
          #
          # ⚠️ CORRECTION DU 2026-09-03. La premiere version de cette entree
          # lancait `sleep infinity`, sur la conviction que Moonshine capturait
          # la session mango deja en cours. C'ETAIT FAUX, et ca donnait un
          # ecran noir. Le journal tranche :
          #
          #     Launching session (starting compositor and app).
          #     Compositor started: 1920x1200 @ 120Hz
          #
          # Moonshine demarre un COMPOSITEUR HEADLESS EMBARQUE par session --
          # « Configuration for the embedded headless compositor », dans
          # moonshine-core/src/session/compositor/mod.rs -- et lance
          # l'application dedans, avec WAYLAND_DISPLAY et DISPLAY pointant sur
          # lui (application.rs:225). `moonshine-wsi` que j'avais pris pour le
          # chemin de capture est une bibliotheque cote CLIENT.
          #
          # Il faut donc y lancer un vrai shell. mango imbriqué est un simple
          # client Wayland du compositeur de Moonshine : il ne touche aucun
          # peripherique DRM, et WLR_DRM_DEVICES n'a aucun effet ici. Le GPU
          # est choisi par `compositor.gpu` ci-dessous, pas par mango.
          title = "Desktop";
          # ⚠️ `dbus-run-session` N EST PAS DECORATIF. Sans lui, constate le
          # 2026-09-03 : le flux affiche bien le bureau, mais tout dialogue
          # servi par un portail -- un selecteur de fichiers, typiquement --
          # s ouvre sur l ECRAN PHYSIQUE et reste invisible et inatteignable
          # depuis le flux. Verifie en mesurant : xdg-desktop-portal-gtk tourne
          # avec WAYLAND_DISPLAY=wayland-0, l affichage de l hote, parce qu il
          # a ete active sur le bus de session il y a des heures.
          #
          # TIPS.md du depot amont decrit exactement ce mecanisme : « le backend
          # du portail dit a l application d exposer les sockets Wayland et
          # display de l HOTE, ecrasant les WAYLAND_DISPLAY et DISPLAY que
          # Moonshine positionne ». Un bus neuf n a pas le portail de l hote
          # enregistre, donc l application retombe sur les variables heritees.
          #
          # Contrepartie assumee : dans ce bureau distant, une application
          # Flatpak ne trouvera pas les portails de l hote. C est le compromis
          # que le depot amont recommande lui-meme.
          command = [ "/run/current-system/sw/bin/dbus-run-session" "--" "/run/current-system/sw/bin/mango" ];

          # PAS de pre_command / post_command ici, et c'est DELIBERE.
          #
          # Le nettoyage differentiel arrete tout scope apparu pendant la
          # session. Sur Steam, Heroic et Lutris c'est precisement ce qu'on
          # veut : le jeu lance par le lanceur ne doit pas survivre au flux.
          # Sur le BUREAU c'est l'inverse -- tout ce que l'utilisateur ouvre
          # depuis le bureau streame apparait forcement pendant la session, et
          # serait donc tue en partant. L'angle mort assume dans le bloc en
          # tete de ce fichier devient ici le cas nominal, donc on n'arme pas
          # le nettoyage.
        }
        {
          title = "Steam";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          # Sous un bus D-Bus dedie, pour la meme raison que Desktop plus
          # haut : sans lui le selecteur de fichiers s ouvre sur l ecran
          # physique. Constate sur les trois lanceurs le 2026-09-04.
          command = [
            "/run/current-system/sw/bin/dbus-run-session"
            "--"
          # PROTON_ENABLE_WAYLAND : Proton parle Wayland en direct au lieu de
          # passer par Xwayland. ApplicationConfig de Moonshine n a AUCUN champ
          # d environnement -- title, boxart, command, pre/post_command, stdout,
          # stderr, launch_timeout_secs, rien d autre -- d ou le passage par
          # `env` dans la commande.
          #
          # Le nom est verifie dans le script proton installe, pas devine :
          # PROTON_ENABLE_WAYLAND et PROTON_USE_WAYLAND appellent tous deux
          # check_environment(..., "wayland") ligne 2262-2263. Ce sont des
          # alias ; on garde le nom Valve.
          #
          # ⚠️ EFFET DE BORD CONNU, constate le 2026-09-01 avec Crimson Moon :
          # sous wine-wayland, les fenetres d installateur de prerequis
          # (vcredist et compagnie) NE S AFFICHENT PAS. Le jeu reste bloque a
          # 0 % de CPU sans contexte GPU et ressemble a un plante. Si un jeu
          # neuf se comporte ainsi, le lancer une premiere fois SANS cette
          # variable pour passer ses installateurs.
            "/run/current-system/sw/bin/env"
            "PROTON_ENABLE_WAYLAND=1"
            "/run/current-system/sw/bin/steam"
            "steam://open/bigpicture"
          ];
          # Le defaut est 2 s. Mesure du 2026-08-25 : le client Steam met une
          # quinzaine de secondes a sortir de sa phase de mise a jour.
          launch_timeout_secs = 30;
        }
        # Les deux lanceurs hors-Steam, ajoutes le 2026-08-25.
        #
        # Ils sont declares EXPLICITEMENT plutot que par un
        # `application_scanner` de type "desktop" : ce scanner ratisse les
        # repertoires .desktop, et /run/current-system/sw/share/applications en
        # contient 215 sur ishtar. La liste Moonlight deviendrait illisible.
        #
        # Heroic couvre Epic, GOG et Amazon. Lutris couvre bien plus large --
        # GOG, Epic, Humble, itch.io, emulateurs, et surtout les executables
        # Windows autonomes, qui est exactement ce qu'est Nioh 3 chez nous.
        # Les faire tourner tous les deux est l'usage courant ; ils ne se
        # marchent pas dessus, chacun gere ses propres prefixes.
        {
          title = "Heroic";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          # Sous un bus D-Bus dedie, pour la meme raison que Desktop plus
          # haut : sans lui le selecteur de fichiers s ouvre sur l ecran
          # physique. Constate sur les trois lanceurs le 2026-09-04.
          command = [ "/run/current-system/sw/bin/dbus-run-session" "--" "/run/current-system/sw/bin/heroic" ];
          launch_timeout_secs = 30;
        }
        {
          title = "Lutris";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          # Sous un bus D-Bus dedie, pour la meme raison que Desktop plus
          # haut : sans lui le selecteur de fichiers s ouvre sur l ecran
          # physique. Constate sur les trois lanceurs le 2026-09-04.
          command = [ "/run/current-system/sw/bin/dbus-run-session" "--" "/run/current-system/sw/bin/lutris" ];
          launch_timeout_secs = 30;
        }
        {
          title = "FGO Arcade";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          # Sous bus D-Bus dedie, comme les quatre autres entrees.
          command = [ "/run/current-system/sw/bin/dbus-run-session" "--" "${lancerFgo}" ];
          # ⚠️ NE PAS MONTER CETTE VALEUR. Elle ne mesure PAS le temps de
          # demarrage du jeu : elle est passee a start_transient_service comme
          # delai d attente que l UNITE SYSTEMD passe en etat actif
          # (application.rs:169), ce qui arrive des que le processus demarre.
          # Les ~90 s que met la borne a derouler ses controles se deroulent
          # apres, hors de ce compteur.
          #
          # Et le webserver a son propre plafond de 60 s, en dur : au-dela il
          # demonte la session (webserver/mod.rs:837, \"Timed out waiting for
          # application launch result\"). Une valeur superieure a 60 garantit
          # donc l echec. Constate le 2026-09-16 avec 120 : le jeu demarrait
          # bien, mais la session etait coupee avant qu il aboutisse.
          launch_timeout_secs = 30;
        }
      ];

      # Recense les jeux installes pour ne pas les declarer un par un.
      # Chemin verifie : /home/ezvk/.local/share/Steam existe.
      application_scanner = [
        {
          type = "steam";
          library = "$HOME/.local/share/Steam";
          # Sous bus dedie comme les quatre applications : les jeux lances par
          # le scanner passent par le meme chemin, et rien ne justifie de leur
          # laisser le portail de l hote. TIPS.md donne d ailleurs son exemple
          # de scanner enveloppe de la meme facon.
          command = [
            "/run/current-system/sw/bin/dbus-run-session"
            "--"
            "/run/current-system/sw/bin/env"
            "PROTON_ENABLE_WAYLAND=1"
            "/run/current-system/sw/bin/steam"
            "-bigpicture"
            "steam://rungameid/{game_id}"
          ];
          launch_timeout_secs = 30;
        }
      ];
    };
  };

  # Le module cree le groupe `moonshine` : c'est lui qui autorise, via une regle
  # polkit livree dans le paquet, la prise d'un inhibiteur de veille de type
  # `block`. Sans ca le service demarre quand meme, mais journalise a chaque
  # lancement -- constate le 2026-08-25 :
  #   Cannot acquire sleep inhibit: InteractiveAuthorizationRequired
  # et la machine peut s'endormir en pleine session de streaming.
  users.users.ezvk.extraGroups = [ "moonshine" ];

  # Le module NE donne PAS le groupe `input` au service : il n'en a besoin que
  # pour lui-meme, pas pour les jeux qu'il lance via le gestionnaire systemd de
  # l'utilisateur. En streaming sans session graphique active, l'utilisateur
  # doit donc etre membre d'`input` pour que les jeux voient les manettes
  # virtuelles. Deja le cas ici -- configuration.nix ligne 132 :
  #   extraGroups = [ "networkmanager" "wheel" "input" "uinput" "samba" ];
  # Rien a ajouter, on le note pour que le retrait de ce groupe ne passe pas
  # inapercu.

  # --- Epinglage du GPU : Moonshine n'en choisit pas, il faut le lui imposer --
  #
  # Le 2026-08-28, la 3060 est passee de `minor 0` a `minor 2` au demarrage,
  # donc /dev/dri/renderD128 a change de carte. Moonshine s'est retrouve a
  # rendre sur une carte et encoder sur l'autre, et un DMA-BUF ne traverse pas
  # d'une NVIDIA a l'autre :
  #   WARN moonshine_core::session::stream::video::pipeline:
  #        Failed to import DMA-BUF: No suitable memory type for DMA-BUF import
  #        No frames received for 5 seconds
  # 150 erreurs en quinze minutes, contre 0 au boot precedent ou la 3060 avait
  # le minor 0 -- ce boot-la avait streame 9 Go sans une seule erreur. Le
  # fonctionnement d'avant tenait donc au hasard de la numerotation.
  #
  # `moonshine --help` et sa config TOML n'offrent AUCUN choix de GPU : il
  # enumere /dev/dri lui-meme. La consigne doit venir de l'exterieur.
  #
  # ⚠️ PREMIER ESSAI, ECHOUE, a ne pas refaire : recouvrir renderD129 par
  # renderD128 via BindPaths dans le service. Vulkan a refuse de creer le
  # device -- "Failed to create Vulkan device: Extension specified does not
  # exist" -- et le service est parti en boucle de redemarrage. Lecon : le
  # pilote Vulkan NVIDIA passe par /dev/nvidia*, PAS par /dev/dri/renderD*.
  # Toucher aux noeuds DRM ne choisit pas le GPU, ca desynchronise le pilote.
  #
  # Ce qui marche : la couche VK_LAYER_MESA_device_select, deja visible du
  # chargeur dans /run/opengl-driver/share/vulkan/implicit_layer.d. Elle filtre
  # la liste des VkPhysicalDevice ; le service n'ouvre plus qu'une carte du
  # point de vue de Vulkan, compositeur et encodeur compris. Noms des variables
  # releves dans libVkLayer_MESA_device_select.so, pas devines.
  #
  # 10de:2805 = AD106, RTX 4060 Ti (0000:01:00.0) -- reservee a l'encodage,
  #             mango tenant la 3060 (voir configuration.nix, bloc gpu-3060).
  # 10de:2503 = GA106, RTX 3060 -- valeur de repli si on inverse un jour.
  #
  # L'identifiant PCI vendor:device est stable quel que soit l'ordre au boot.
  # Il ne le serait plus avec deux cartes identiques : dans ce cas, revoir.
  #
  # Mesure avant / apres, sur la meme charge :
  #   18:40:00 -> 18:55:32   150 erreurs DMA-BUF
  #   depuis   18:55:32        0 erreur, 0 "No frames received", session OK
  systemd.services.moonshine.environment = {
    MESA_VK_DEVICE_SELECT = "10de:2805";
    MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE = "1";
  };
  # ---------------------------------------------------------------------------
}
