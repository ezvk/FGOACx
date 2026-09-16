#!/usr/bin/env bash
# Lance FGO Arcade sous Proton, sans passer par le launcher d'origine.
#
# ⚠️ POURQUOI PAS « FGOAC scooby.exe » : toute sa chaîne est en PowerShell, que
# Wine ne fournit pas, et PowerShell 7 portable ne s'exécute pas non plus dans
# un préfixe Proton (témoin : `pwsh -Command "exit 42"` rend 0 et n'écrit rien).
#
# Prérequis :
#   1. generer-runtime.py a été exécuté (segatools.runtime.ini en UTF-16 + BOM)
#   2. fgostub.dll est compilée et posée dans App/
#   3. ⚠️ SUR NVIDIA ET AMD : PAS de opengl32.dll dans App/, et cache de shaders
#      vidé. Le shim de fluphus n'est nécessaire QUE sur les GPU sans
#      GL_ARB_bindless_texture — Intel. Voir docs/MATERIEL.md.
set -u

RACINE="${FGOAC_RACINE:-$HOME/fgo-install}"
PREFIXE="${FGOAC_PREFIXE:-$HOME/Games/Heroic/Prefixes/FGOA}"
PROTON="${FGOAC_PROTON:?définir FGOAC_PROTON vers un répertoire Proton}"
UMU="${FGOAC_UMU:-umu-run}"
LETTRE="${FGOAC_LETTRE:-X:}"          # lettre Wine pointant sur $HOME
WIN="${FGOAC_WIN:-$LETTRE\\$(basename "$RACINE")}"
RENDU="${FGOAC_RENDU:--wqhd}"         # donné par generer-runtime.py

export WINEPREFIX="$PREFIXE" PROTONPATH="$PROTON" GAMEID="${GAMEID:-umu-default}"

# Variables que FGO_Launcher.ps1 pose et que fgohook lit. Sans
# SEGATOOLS_CONFIG_PATH : « native-surface patch failed », Win32=203.
export SEGATOOLS_CONFIG_PATH="$WIN\\DEVICE\\runtime\\segatools.runtime.ini"
export FGO_INSTALL_ROOT="$WIN"
export FGO_TARGET_FPS="${FGOAC_FPS:-60}"
export FGO_LOCAL_NETWORK=0
export FGO_LOCAL_HTTP_PORT=777 FGO_LOCAL_BILLING_PORT=9999 FGO_LOCAL_AIME_PORT=7777
export FGO_ZH_ENABLED=0 FGO_FULL_SURFACE_FBO=1 FGO_SMAA=0 FGO_RENDER_SCALE=100
export FGO_SHADOW_RESOLUTION=1024 FGO_ANISOTROPY=16 FGO_MOTION_BLUR=0
export FGO_DEPTH_OF_FIELD=1 FGO_BLOOM=1 FGO_HIDE_UI=0 FGO_HIDE_UI_KEY=121
export FGO_HIDE_TARGET_LINES=1 FGO_DISABLE_CAMERA_SHAKE=1 FGO_HIDE_CABINET_HUD=1
export FGO_TEXTURE_QUALITY=0

# ⚠️ Tuer les restes : l'auteur note que pré-démarrer AMDaemon casse la poignée
# de main d'état du processus. Le launcher d'origine fait de même.
for n in ago.exe amdaemon.exe inject.exe; do
  for p in $(pgrep -x -u "$(id -un)" "$n" 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
done
sleep 1

# ⚠️ La sortie de inject.exe ne remonte pas sur le stdout de umu-run. On passe
# par cmd.exe avec redirection DANS le préfixe, sinon on ne voit jamais les
# messages de fgohook — qui sont le seul diagnostic utile côté client.
cat > "$RACINE/App/lancer.bat" <<BAT
@echo off
cd /d $WIN\\App
inject.exe -d -k "$WIN\\App\\fgostub.dll" -k "$WIN\\App\\fgohook.dll" "$WIN\\App\\ago.exe" $RENDU -w --wasapi-shared > $WIN\\logs\\inject.log 2>&1
echo EXITCODE=%ERRORLEVEL% >> $WIN\\logs\\inject.log
BAT

mkdir -p "$RACINE/logs"
cd "$RACINE/App" || exit 1
exec "$UMU" cmd.exe /c "$WIN\\App\\lancer.bat"
