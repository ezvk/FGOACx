#!/usr/bin/env python3
"""Génère DEVICE/runtime/segatools.runtime.ini et amdaemon_main.json.

Reproduit ce que FGO_Launcher.ps1 prépare avant de lancer le jeu, parce que
toute sa chaîne est en PowerShell — absent de Wine, et PowerShell 7 portable
ne s'exécute pas non plus dans un préfixe Proton.

⚠️ LE FICHIER DOIT ÊTRE EN UTF-16LE AVEC BOM. GetPrivateProfileStringW l'exige.
Sans cela : « Resolution mode: native-surface patch failed (hr=80070057) …
Win32=203 », soit ERROR_ENVVAR_NOT_FOUND, et le jeu refuse de démarrer.

Usage :
    generer-runtime.py --racine ~/fgo-install --serveur 192.168.1.60 \
                       --largeur 2560 --hauteur 1440 --entree keyboard
"""
import argparse
import pathlib
import re
import shutil

def poser(texte: str, section: str, cle: str, valeur: str) -> str:
    """Écrit cle=valeur dans [section], en la créant au besoin."""
    entete = re.search(r"(?m)^\[" + re.escape(section) + r"\]\s*$", texte)
    if not entete:
        return texte.rstrip("\r\n") + f"\r\n\r\n[{section}]\r\n{cle}={valeur}\r\n"
    suivante = re.search(r"(?m)^\[", texte[entete.end():])
    fin = entete.end() + (suivante.start() if suivante else len(texte) - entete.end())
    corps = texte[entete.end():fin]
    ligne = re.search(r"(?m)^" + re.escape(cle) + r"\s*=.*$", corps)
    if ligne:
        corps = corps[:ligne.start()] + f"{cle}={valeur}" + corps[ligne.end():]
    else:
        corps = corps.rstrip("\r\n") + f"\r\n{cle}={valeur}\r\n"
    return texte[:entete.end()] + corps + texte[fin:]

def argument_rendu(largeur: int, hauteur: int) -> str:
    """Même calcul que FGO_Launcher.ps1:379-402."""
    gauche, droite = largeur * 9, hauteur * 16
    if gauche > droite:
        return "-wqhd"
    if gauche == droite:
        if largeur <= 1280 and hauteur <= 720:
            return "-hdtv720"
        return "-hdtv1080" if largeur < 2560 and hauteur < 1440 else "-wqhd"
    return "-wqhd" if largeur >= 2560 else "-hdtv1080"

def main() -> None:
    a = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--racine", required=True, help="racine de l'installation FGO Arcade")
    a.add_argument("--serveur", required=True, help="adresse IPv4 du serveur ARTEMiS")
    a.add_argument("--lettre", default="X:", help="lettre Wine pointant sur $HOME (défaut X:)")
    a.add_argument("--prefixe-win", default=None,
                   help="chemin Windows de l'install (déduit de --lettre sinon)")
    a.add_argument("--largeur", type=int, default=1280)
    a.add_argument("--hauteur", type=int, default=720)
    a.add_argument("--entree", default="keyboard", choices=("keyboard", "xinput"))
    a.add_argument("--sous-reseau", default="192.168.1.0")
    a.add_argument("--diffusion", default="192.168.1.255")
    a.add_argument("--version", default="11.00")
    args = a.parse_args()

    racine = pathlib.Path(args.racine).expanduser().resolve()
    win = args.prefixe_win or (args.lettre + "\\" + racine.name)

    base = racine / "App" / "segatools.ini"
    runtime = racine / "DEVICE" / "runtime" / "segatools.runtime.ini"
    runtime.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(base, runtime)
    t = runtime.read_text(encoding="utf-8")

    reglages = [
        ("vfs", "amfs", win + r"\AMFS"),
        ("vfs", "option", win + r"\App\option"),
        ("vfs", "appdata", win + r"\GameData"),
        ("aime", "aimePath", win + r"\DEVICE\aime.txt"),
        ("printer", "mainFwPath", win + r"\DEVICE\printer_main_fw.bin"),
        ("printer", "paramFwPath", win + r"\DEVICE\printer_param_fw.bin"),
        ("printer", "dspFwPath", win + r"\DEVICE\printer_dsp_fw.bin"),
        ("keychip", "billingCa", win + r"\DEVICE\ca.crt"),
        ("keychip", "billingPub", win + r"\DEVICE\billing.pub"),
        ("keychip", "subnet", args.sous_reseau),
        ("misc", "nextProcessFilePath", win + r"\DEVICE\NextProcess.txt"),
        ("dns", "default", args.serveur),
        ("dns", "startupPort", "777"),
        ("dns", "billingPort", "9999"),
        ("dns", "aimedbPort", "7777"),
        ("netenv", "enable", "1"),
        ("netenv", "routerSuffix", "1"),
        ("netenv", "addrSuffix", "42"),
        ("netenv", "broadcast", args.diffusion),
        ("gfx", "windowed", "1"),
        ("gfx", "framed", "0"),
        ("gfx", "width", str(args.largeur)),
        ("gfx", "height", str(args.hauteur)),
        ("gfx", "logicalWidth", str(args.largeur)),
        ("gfx", "logicalHeight", str(args.hauteur)),
        ("gfx", "preserveAspect", "1"),
        ("gfx", "monitor", "0"),
        ("gfx", "monitorDevice", ""),
        ("amvideo", "resolutionWidth", str(args.largeur)),
        ("amvideo", "resolutionHeight", str(args.hauteur)),
        ("io4", "mode", args.entree),
        ("touch", "enable", "1"),
        ("touch", "remap", "1"),
        ("touch", "cursor", "1"),
        ("touch", "inputWidth", "1920"),
        ("touch", "inputHeight", "1080"),
        ("touch", "nativeCoordinates", "0"),
        ("system", "freeplay", "0"),
        ("clock", "timezone", "0"),
        ("clock", "daystart", "0"),
        ("clock", "startHour", "0"),
        ("clock", "startMinute", "0"),
        ("clock", "timewarp", "0"),
        ("clock", "writeable", "0"),
    ]
    for section, cle, valeur in reglages:
        t = poser(t, section, cle, valeur)

    # ⚠️ UTF-16LE + BOM, comme [IO.File]::WriteAllText(..., Encoding.Unicode)
    runtime.write_bytes(b"\xff\xfe" + t.encode("utf-16-le"))

    (racine / "DEVICE" / "runtime" / "amdaemon_main.json").write_text(
        '{\n  "credit": {\n    "max_credit": 99\n  },\n'
        '  "allnet_auth": {\n    "develop_version": "%s"\n  }\n}\n' % args.version,
        encoding="utf-8")

    print(f"{runtime} : {runtime.stat().st_size} octets, UTF-16LE + BOM")
    print(f"argument de rendu à passer à ago.exe : {argument_rendu(args.largeur, args.hauteur)}")

if __name__ == "__main__":
    main()
