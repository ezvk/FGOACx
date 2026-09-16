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

Second client sur le meme serveur -- il lui faut une IDENTITE DISTINCTE, sinon
ARTEMiS le voit comme la meme borne et le meme joueur :
    generer-runtime.py --racine ~/fgo-install --serveur 192.168.1.60 \
                       --keychip A69E-01B88888888 --pcbid ACAE01B99999999 \
                       --suffixe-adresse 43
⚠️ Le caractere qui differe doit etre DANS LES ONZE PREMIERS : le serveur ne
voit que ceux-la, tirets retires. Voir le commentaire de --keychip.
et une carte Aime differente : supprimer DEVICE/aime.txt, aimeGen=1 en genere
une neuve au premier scan.
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
    # ── IDENTITE DE LA BORNE ──────────────────────────────────────────────
    # Deux clients sur le meme serveur DOIVENT differer sur ces trois points,
    # sinon ils sont la meme borne et le meme joueur pour ARTEMiS.
    # Constate le 2026-09-16 : ishtar et enlil partageaient keychip, pcbid,
    # carte Aime ET addrSuffix.
    # ⚠️ LES DEUX SONT TRONQUES A 11 CARACTERES dans l en-tete du protocole.
    # Mesure du 2026-09-16 : le serveur journalise kc_serial='A69E01A8888' et
    # b_serial='ACAE01A9999'. Les tirets sautent, et seuls les ONZE PREMIERS
    # caracteres comptent. Une premiere tentative avait modifie le 9e chiffre --
    # A69E-01A88888888 vs A69E-01A88888889 -- ce qui ne change RIEN : les deux
    # donnent A69E01A8888. Pour distinguer deux bornes, modifier un caractere
    # DANS les onze premiers, par exemple la lettre de groupe :
    #   A69E-01A88888888  ->  A69E01A8888
    #   A69E-01B88888888  ->  A69E01B8888   (distinct)
    a.add_argument("--keychip", default=None,
                   help="numero de serie du keychip. Motif observe en vrai : "
                        r"A\d{2}(E|X)-(01|20)[ABCDU]\d{8}. ATTENTION : seuls "
                        "les 11 premiers caracteres, tirets retires, sont vus "
                        "par le serveur")
    a.add_argument("--pcbid", default=None,
                   help="ALLS MAIN ID, sans tiret. Meme troncature a 11 "
                        "caracteres que le keychip")
    a.add_argument("--suffixe-adresse", default="42",
                   help="dernier octet sur le sous-reseau virtualise par netenv")
    a.add_argument("--netenv", default="1", choices=("0", "1"),
                   help="0 = utiliser le VRAI reseau local. segatools avertit "
                        "que netenv 'may interfere with head-to-head play' ; "
                        "si on le desactive, --sous-reseau doit etre celui de "
                        "la machine et commencer par 192.168.")
    a.add_argument("--version", default="11.00")
    args = a.parse_args()
    identite = []
    if args.keychip:
        identite.append(("keychip", "id", args.keychip))
    if args.pcbid:
        identite.append(("pcbid", "serialNo", args.pcbid))

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
        ("netenv", "enable", args.netenv),
        ("netenv", "routerSuffix", "1"),
        ("netenv", "addrSuffix", args.suffixe_adresse),
        ("netenv", "broadcast", args.diffusion),
        *identite,
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
