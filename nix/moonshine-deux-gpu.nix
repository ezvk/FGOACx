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
# Les deux entrees partagent ~/fgo-install/App, donc le cache de shaders
# App/shader-cache-r2, que chaque lanceur purge. Deux sessions simultanees se
# marcheraient dessus. Les lanceurs REFUSENT donc de demarrer si l'autre
# variante tourne, au lieu de corrompre en silence.
# Pour les faire cohabiter -- ce qu'il faudra pour tester le multijoueur a deux
# clients sur une seule machine -- il faut un SECOND arbre App.
#
# La bascule NVIDIA/AMD, elle, ne passe PLUS par le deplacement d'un fichier :
# elle se joue sur la chaine d'injection du .bat (fgoglcompat.dll sur AMD,
# rien sur NVIDIA). Voir le preparateur ci-dessous.
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

  # ── L'INI ET LE .BAT SONT FABRIQUES A CHAQUE SESSION ──────────────────────
  #
  # Le 2026-09-16, premiere session Moonlight sur enlil : image coupee. Le
  # journal du jeu tranchait sans ambiguite --
  #   Resolution mode: patched mode 13 to native surface 1920x1200
  #   Gfx: Main window client created at 1920x1200
  #   Gfx: display state ... window=0,0 1920x1200 ... current=1920x1080@60
  # soit une fenetre de 1200 lignes dans une sortie de 1080 : 120 pixels
  # perdus. La cause n'etait PAS le .bat, qui demandait deja -hdtv1080, mais
  # segatools.runtime.ini, regle sur la dalle physique d'enlil (1920x1200,
  # 16:10) pour le jeu en local.
  #
  # Plutot que de figer 1080, on lit ce que le CLIENT a demande. Moonshine
  # l'expose dans l'environnement de la session -- releve sur /proc/<pid>/environ
  # d'ago.exe, pas devine :
  #   MOONSHINE_CLIENT_WIDTH=1920
  #   MOONSHINE_CLIENT_HEIGHT=1080
  #   MOONSHINE_CLIENT_FRAMERATE=60
  # Changer la resolution dans Moonlight suffit donc, sans rien retoucher ici.
  #
  # ⚠️ L'INI DOIT ETRE EN UTF-16LE AVEC BOM. GetPrivateProfileStringW l'exige.
  # Sans cela : "Resolution mode: native-surface patch failed (hr=80070057)
  # Win32=203" (ERROR_ENVVAR_NOT_FOUND) et le jeu refuse de demarrer.
  #
  # segatools.runtime.ini n'est JAMAIS modifie : il reste la reference pour le
  # jeu sur la dalle locale. On en derive segatools.stream.ini.
  preparerSession = pkgs.writeText "fgo-preparer-session.py" ''
    """Derive l ini et le .bat de la session a partir de la resolution client."""
    import pathlib, re, sys

    largeur, hauteur, variante = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
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
        cle = m.group(1)
        vus.add(cle)
        return f"{cle}={valeurs[cle]}"

    texte = re.sub(r"(?m)^(" + "|".join(valeurs) + r")=\d+", remplacer, texte)
    manquantes = set(valeurs) - vus
    if manquantes:
        sys.exit(f"cles absentes de {src}, refus de continuer : {sorted(manquantes)}")

    dst.write_bytes(b"\xff\xfe" + texte.encode("utf-16-le"))

    # Meme calcul que FGO_Launcher.ps1:379-402, repris de client/generer-runtime.py.
    g, d = largeur * 9, hauteur * 16
    if g > d:
        mode = "-wqhd"
    elif g == d:
        if largeur <= 1280 and hauteur <= 720:
            mode = "-hdtv720"
        else:
            mode = "-hdtv1080" if largeur < 2560 and hauteur < 1440 else "-wqhd"
    else:
        mode = "-wqhd" if largeur >= 2560 else "-hdtv1080"

    app = "X:\\fgo-install\\App"
    jrn = f"X:\\fgo-install\\logs\\inject-{variante}.log"

    # Chaine d injection. fgostub corrige SetWindowFeedbackSetting, absent de Wine.
    #
    # ⚠️ SUR AMD ON INJECTE fgoglcompat.dll, ET AVANT fgohook.
    # Le paquet embarque DEUX couches de compatibilite, et on utilisait la
    # mauvaise. GUIDE_EN.md, tableau des prerequis :
    #   "AMD: the launcher installs the older compatibility layer ... it runs on
    #    RX 500, RX 6000, RX 7600 and desktop Ryzen graphics. The newer layer by
    #    fluphus (Settings > Display) runs on the RX 7900 XTX; on other cards it
    #    crashes at the first battle."
    # La couche fluphus est le App\opengl32.dll qu on deplacait ; la couche
    # "older" est fgoglcompat.dll. FGO_Launcher.ps1:660 distingue les deux et
    # precise l ordre : "fgoglcompat.dll (before fgohook)". run-gl.bat, livre
    # avec le paquet, fait exactement cela.
    #
    # Ce que fgoglcompat fait, releve dans ses chaines :
    #   "FGO GL compatibility: WGL resolver installed"
    #   "#extension GL_ARB_bindless_texture : require"
    #   "#extension GL_ARB_gpu_shader_int64 : require"
    #   "#extension GL_ARB_enhanced_layouts : require"
    # soit un resolveur wglGetProcAddress + une traduction des shaders au
    # passage par glShaderSource/glCompileShader.
    #
    # ⚠️ RESERVE ECRITE : le meme tableau dit "Intel integrated graphics and
    # Ryzen laptop graphics are not covered by either layer yet". Le 780M
    # d enlil est precisement du Ryzen portable. Cette entree reste donc un
    # BANC D ESSAI, pas une configuration supposee fonctionner.
    # variante : nvidia | amd-compat | amd-fluphus
    dlls = ["fgostub.dll"]
    if variante == "amd-compat":
        dlls.append("fgoglcompat.dll")
    dlls.append("fgohook.dll")
    chaine = " ".join(f'-k "{app}\\{d}"' for d in dlls)

    bat = racine / "App" / f"run-stream-{variante}.bat"
    bat.write_text(
        "@echo off\r\n"
        f"cd /d {app}\r\n"
        f'inject.exe -d {chaine} "{app}\\ago.exe" {mode} -w --wasapi-shared > {jrn} 2>&1\r\n'
        f"echo EXITCODE=%ERRORLEVEL% >> {jrn}\r\n"
    )
    print(f"session {variante} : {largeur}x{hauteur} {mode} | injection {dlls}")
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
    export SEGATOOLS_CONFIG_PATH="X:\fgo-install\DEVICE\runtime\segatools.stream.ini"
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

    # Resolution demandee par le client Moonlight. Les valeurs de repli ne
    # servent que si on lance ce script a la main, hors session.
    ${pkgs.python3}/bin/python3 ${preparerSession} \
      "''${MOONSHINE_CLIENT_WIDTH:-1920}" \
      "''${MOONSHINE_CLIENT_HEIGHT:-1080}" \
      "$FGO_VARIANTE" || exit 1
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
      ${pkgs.coreutils}/bin/mv -f opengl32.dll /home/ezvk/shim-de-cote/ 2>/dev/null || true
      ${pkgs.coreutils}/bin/rm -rf shader-cache-r2
      ${pkgs.coreutils}/bin/mkdir -p shader-cache-r2
    fi
    # run-stream-nvidia.bat est ECRIT par preparerSession ci-dessus, avec le
    # mode de rendu calcule depuis la resolution client et un journal propre a
    # la variante. Les run-*.bat qui trainent dans App/ viennent d essais a la
    # main et ne sont plus utilises par le streaming. ~/jouer.sh, lui,
    # s annoncait NVIDIA mais appelait run-amd.bat : les deux variantes
    # ecrivaient dans le meme journal.
    exec ${pkgs.umu-launcher}/bin/umu-run cmd.exe /c "X:\fgo-install\App\run-stream-nvidia.bat"
  '';

  # ── RELACHEMENT DU COMPILATEUR GLSL DE MESA POUR ago.exe ──────────────────
  #
  # Mesure du 2026-09-16, couche fgoglcompat sur le 780M :
  #   compile shader=316 capture=185 success=0
  #     0:77(3): error: embedded structure declarations are not allowed
  # puis 0xC0000005, le moteur se servant d'un programme qui n'a pas compile.
  #
  # Ce n'est PAS une extension manquante : le 780M a bien
  # GL_ARB_bindless_texture, GL_ARB_gpu_shader_int64 et GL_ARB_enhanced_layouts
  # (releve glxinfo, Mesa 26.2.1). C'est la SEVERITE du compilateur GLSL de
  # Mesa, plus stricte que celle de NVIDIA. Et la construction fautive n'est
  # pas dans App/rom/shader.farc -- les 170 shaders en ont ete extraits, aucun
  # ne declare de structure imbriquee : elle est produite par la reecriture de
  # la couche elle-meme.
  #
  # Mesa prevoit exactement ce relachement, et l'applique deja a un autre jeu
  # Windows sous Wine dans share/drirc.d/00-mesa-defaults.conf :
  #     <application name="MDK2 HD" executable="mdk2hd.exe">
  #       <option name="allow_glsl_embedded_structure_declarations" value="true"/>
  #     </application>
  # Ce precedent vaut confirmation que la correspondance se fait sur le nom de
  # l'executable Windows : Mesa lit /proc/<pid>/comm, et `pgrep -x ago.exe`
  # repond sur cette machine.
  #
  # RESULTAT MESURE : 1719 shaders compiles sans une erreur, puis
  #   present frames=2297 -> 2597 -> 2897 -> 3197, par pas de 5 s
  # soit 300 images toutes les 5 secondes, 60 img/s en regime, sur un iGPU que
  # GUIDE_EN.md donne pour "not covered by either layer yet".
  drirc = pkgs.writeText "drirc-fgo" ''
    <?xml version="1.0" standalone="yes"?>
    <driconf>
      <device>
        <application name="FGO Arcade" executable="ago.exe">
          <option name="allow_glsl_embedded_structure_declarations" value="true"/>
        </application>
      </device>
    </driconf>
  '';

  # ── AMD : DEUX COUCHES, AUCUNE VALIDEE SUR CE MATERIEL ────────────────────
  #
  # GUIDE_EN.md du paquet, tableau des prerequis -- c est la source, pas une
  # deduction :
  #   "AMD: the launcher installs the older compatibility layer on a fresh
  #    install without an NVIDIA card; it runs on RX 500, RX 6000, RX 7600 and
  #    desktop Ryzen graphics. The newer layer by fluphus (Settings > Display)
  #    runs on the RX 7900 XTX; on other cards it crashes at the first battle.
  #    Intel integrated graphics and Ryzen laptop graphics are not covered by
  #    either layer yet."
  #
  #   couche "older"  = compat/fgoglcompat.dll, injectee AVANT fgohook
  #                     (FGO_Launcher.ps1:606 : "Must load before fgohook:
  #                      MinHook on opengl32 exports, IAT left for fgohook")
  #   couche "newer"  = compat/amd-shim/opengl32.dll, de fluphus, posee dans
  #                     App/ et chargee par l editeur de liens
  # Les deux s EXCLUENT.
  #
  # Mesure du 2026-09-16 sur le 780M, couche fgoglcompat : elle fonctionne loin.
  # compat.log montre toute la table d alias NV->ARB en OK, un tas de 256 Mo,
  # 1719 shaders a compiler, puis :
  #   present frames=1 success=1
  #   compile shader=316 capture=185 success=0
  #     0:77(3): error: embedded structure declarations are not allowed
  #   unhandled exception 0xc0000005 at 0000000140C084F7
  # Une image est donc bien presentee avant l echec, et le 0xC0000005 est la
  # CONSEQUENCE du programme non compile, pas la cause. Le refus vient du
  # compilateur GLSL de Mesa, plus strict que celui de NVIDIA.
  #
  # ⚠️ La construction fautive n est PAS dans App/rom/shader.farc : les 170
  # shaders en ont ete extraits et aucun ne declare de structure imbriquee.
  # Elle est donc produite par la reecriture de la couche elle-meme.
  #
  # ⚠️ Le 780M a bien ce que la couche vise -- releve glxinfo, Mesa 26.2.1 :
  # GL_ARB_bindless_texture, GL_ARB_gpu_shader_int64, GL_ARB_enhanced_layouts.
  # Le "not covered yet" du guide est un non-test, pas un verdict materiel.
  # Intel, lui, est exclu par construction : iris n a pas ARB_bindless_texture.
  lanceurAmd = couche: pkgs.writeShellScript "moonshine-fgo-amd-${couche}" ''
    export FGO_VARIANTE=amd-${couche}
    ${communFgo}
    # Pas de PRIME : on veut precisement le rendu sur le 780M.
    export DRI_PRIME=0
    ${if couche == "fluphus" then ''
    # Couche fluphus : elle DOIT etre App/opengl32.dll, et fgoglcompat ne doit
    # pas etre injectee en meme temps (le .bat s en charge).
    # AMD_CONFIG_DIR est lu par le pilote OpenGL AMD de Windows ; sous Mesa il
    # ne fait rien, on le pose quand meme pour coller a ce que fait la couche.
    export AMD_CONFIG_DIR="X:\fgo-install\compat\amd-shim\amdcfg"
    export WINEDLLOVERRIDES="opengl32=n,b"
    ${pkgs.coreutils}/bin/cp -f /home/ezvk/fgo-install/compat/amd-shim/opengl32.dll . || exit 1
    '' else ''
    # Couche fgoglcompat : AUCUN opengl32.dll dans App. CHANGELOG.md du paquet
    # signale "App\opengl32.dll is a copy the launcher did not put there"
    # comme une anomalie a corriger.
    if [ -f opengl32.dll ]; then
      ${pkgs.coreutils}/bin/mkdir -p /home/ezvk/opengl32-ecarte
      ${pkgs.coreutils}/bin/mv -f opengl32.dll /home/ezvk/opengl32-ecarte/ 2>/dev/null || true
    fi
    if [ ! -f fgoglcompat.dll ]; then
      echo "REFUS : fgoglcompat.dll absent de App/." >&2
      exit 1
    fi
    ''}
    ${pkgs.coreutils}/bin/rm -rf shader-cache-r2
    ${pkgs.coreutils}/bin/mkdir -p shader-cache-r2
    exec ${pkgs.umu-launcher}/bin/umu-run cmd.exe /c "X:\fgo-install\App\run-stream-amd-${couche}.bat"
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
          title = "FGO Arcade (AMD - couche fgoglcompat)";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          command = [
            "/run/current-system/sw/bin/dbus-run-session"
            "--"
            "${lanceurAmd "compat"}"
          ];
          launch_timeout_secs = 30;
        }
        {
          title = "FGO Arcade (AMD - couche fluphus)";
          pre_command = [ [ "${scopesAvant}" ] ];
          post_command = [ [ "${scopesApres}" ] ];
          command = [
            "/run/current-system/sw/bin/dbus-run-session"
            "--"
            "${lanceurAmd "fluphus"}"
          ];
          launch_timeout_secs = 30;
        }
      ];
    };
  };

  # ── RELACHEMENT DU COMPILATEUR GLSL DE MESA POUR ago.exe ──────────────────
  #
  # Mesure du 2026-09-16, couche fgoglcompat sur le 780M :
  #   compile shader=316 capture=185 success=0
  #     0:77(3): error: embedded structure declarations are not allowed
  # puis 0xC0000005, le moteur utilisant un programme qui n a pas compile.
  #
  # Ce n est PAS une extension manquante : le 780M a bien
  # GL_ARB_bindless_texture, GL_ARB_gpu_shader_int64 et
  # GL_ARB_enhanced_layouts (releve glxinfo, Mesa 26.2.1). C est la SEVERITE du
  # compilateur GLSL de Mesa, plus stricte que celle de NVIDIA.
  #
  # Mesa prevoit exactement ce relachement -- option `allow_glsl_embedded_
  # structure_declarations`, listee dans share/drirc.d/00-mesa-defaults.conf,
  # qui l applique deja a un autre jeu Windows sous Wine :
  #     <application name="MDK2 HD" executable="mdk2hd.exe">
  #       <option name="allow_glsl_embedded_structure_declarations" value="true"/>
  #     </application>
  # Le precedent vaut confirmation que la correspondance se fait bien sur le
  # nom de l executable Windows : Mesa lit /proc/<pid>/comm, et `pgrep -x
  # ago.exe` repond sur cette machine.
  #
  # ⚠️ CE N EST PAS PROUVE FONCTIONNEL. L option leve le refus du compilateur ;
  # elle ne dit rien de ce que le shader fera ensuite. Le prochain point
  # d arret, s il y en a un, sera different -- c est justement l interet.
  #
  # Ordre de lecture de Mesa : share/drirc.d/*.conf, puis /etc/drirc, puis
  # ~/.drirc. Aucun /etc/drirc n existait sur enlil avant ce bloc.
  # ⚠️ /etc/drirc NE SUFFIT PAS, et c'est la mesure qui l'a montre.
  # Pose une premiere fois dans /etc, la regle n'a rien change : erreur
  # identique, meme shader 316, meme message. Le jeu tourne dans
  # PRESSURE-VESSEL, le conteneur d'umu-launcher, dont le /etc n'est pas celui
  # de l'hote -- l'environnement du processus le disait deja
  # (XDG_DATA_DIRS commence par /usr/lib/pressure-vessel/overrides/share, et ce
  # chemin n'existe pas sur l'hote).
  # En revanche HOME=/home/ezvk A L'INTERIEUR du conteneur : le repertoire
  # personnel y est monte. C'est donc ~/.drirc qui porte, et l'essai suivant a
  # compile les 1719 shaders sans une erreur, 60 images/s en regime.
  # Ordre de lecture de Mesa : share/drirc.d/*.conf, /etc/drirc, puis ~/.drirc.
  # On garde les deux : /etc pour un lancement hors conteneur, ~/ pour dedans.
  environment.etc."drirc".source = drirc;
  systemd.tmpfiles.rules = [ "L+ /home/ezvk/.drirc - - - - ${drirc}" ];


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
