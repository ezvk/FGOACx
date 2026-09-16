#!/usr/bin/env python3
"""Remplit App/deck.json avec les cartes réellement tirées par le joueur.

POURQUOI. Les cartes gagnées au gacha n'apparaissent pas dans l'inventaire du
jeu, et ce n'est pas un bug du serveur : il les enregistre bien
(`summoned_card_counts`). Sur une vraie borne, une carte tirée est **imprimée**,
puis le joueur la **pose sur le lecteur** pour s'en servir. `App/deck.json`
est l'émulation de ce lecteur : une liste d'images de cartes posées dessus.
Les tirages n'y entrent pas tout seuls.

    {"SelectedCards": ["../DEVICE/print/FGO11_AllServants/00006_SVT00001_A00_NORMAL.bmp", ...]}

Ce script fait le lien : profil serveur → `TradingCardId` → `FileName` du
manifeste → `deck.json`.

⚠️ Le lecteur émulé a une CAPACITÉ LIMITÉE. Sa mémoire partagée fait
1 + 30 × 44 octets, soit **30 cartes au maximum**. Au-delà, il faut choisir.
"""
import argparse, json, pathlib, sys

def charger(chemin, quoi):
    try:
        return json.loads(pathlib.Path(chemin).read_text(encoding="utf-8-sig"))
    except OSError as e:
        sys.exit(f"{quoi} illisible : {e}")

def main():
    a = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--racine", required=True, help="racine de l'installation FGO Arcade")
    a.add_argument("--profils", default=None,
                   help="fgo-players.json (déduit de --racine sinon)")
    a.add_argument("--joueur", default=None,
                   help="clé du profil, par exemple aime:9. Le premier sinon")
    a.add_argument("--max", type=int, default=30,
                   help="capacité du lecteur émulé (30 par défaut, sa limite réelle)")
    a.add_argument("--tri", default="recent", choices=("recent", "tc_id"),
                   help="recent = les dernières confirmées d'abord")
    a.add_argument("--servants-seulement", action="store_true",
                   help="exclure les Craft Essences (CardTypeId != 1)")
    a.add_argument("--appliquer", action="store_true",
                   help="écrire deck.json. Sans cette option : simulation seule")
    args = a.parse_args()

    racine = pathlib.Path(args.racine).expanduser().resolve()
    profils = pathlib.Path(args.profils) if args.profils else racine / "Server/state/fgo-players.json"
    manifeste = racine / "DEVICE/print/FGO11_AllServants/library-manifest.json"
    deck = racine / "App/deck.json"

    joueurs = charger(profils, "fichier de profils")
    cle = args.joueur or next(iter(joueurs))
    if cle not in joueurs:
        sys.exit(f"profil {cle} absent. Disponibles : {list(joueurs)}")
    p = joueurs[cle]

    par_id = {int(c["TradingCardId"]): c for c in charger(manifeste, "manifeste")["Cards"]}

    # quand chaque carte a ete confirmee, pour pouvoir trier par fraicheur
    quand = {}
    for e in (p.get("tc_confirmations") or {}).values():
        cd = e.get("card_data")
        if not cd:
            continue
        tcid = ((cd.get("tc_detail") or {}).get("tc_id"))
        if tcid:
            quand[int(tcid)] = max(quand.get(int(tcid), ""), e.get("confirmed_at") or "")

    possedees = {int(k): int(v) for k, v in (p.get("summoned_card_counts") or {}).items() if int(v) > 0}
    print(f"profil {cle} : {len(possedees)} cartes distinctes tirees")

    connues = {t: par_id[t] for t in possedees if t in par_id}
    inconnues = sorted(set(possedees) - set(connues))
    if inconnues:
        print(f"  ⚠️ {len(inconnues)} absentes du manifeste, ignorees : {inconnues[:8]}")

    if args.servants_seulement:
        avant = len(connues)
        connues = {t: c for t, c in connues.items() if int(c.get("CardTypeId", 0)) == 1}
        print(f"  filtre servants : {avant} -> {len(connues)}")

    ordre = (sorted(connues, key=lambda t: (quand.get(t, ""), t), reverse=True)
             if args.tri == "recent" else sorted(connues))
    retenues = ordre[:args.max]
    print(f"  retenues : {len(retenues)} sur {len(connues)} (capacite {args.max})")
    print()
    for t in retenues:
        c = connues[t]
        print(f"   tc_id={t:6d}  type={c['CardTypeId']}  {c['DisplayName'][:44]:46s} {c['FileName']}")

    chemins = [f"../DEVICE/print/FGO11_AllServants/{connues[t]['FileName']}" for t in retenues]
    manquantes = [c for c in chemins if not (racine / "App" / c).exists()]
    if manquantes:
        print(f"\n⚠️ {len(manquantes)} images absentes du disque, non ecrites : {manquantes[:3]}")
        chemins = [c for c in chemins if c not in manquantes]

    if not args.appliquer:
        print(f"\nSIMULATION. {len(chemins)} cartes seraient ecrites dans {deck}.")
        print("Ajouter --appliquer pour ecrire (une sauvegarde horodatee est faite).")
        return
    import datetime, shutil
    h = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copyfile(deck, deck.with_suffix(f".json.avant-sync-{h}"))
    deck.write_text(json.dumps({"SelectedCards": chemins}, ensure_ascii=False), encoding="utf-8")
    print(f"\n{deck} ecrit : {len(chemins)} cartes. Sauvegarde : {deck.name}.avant-sync-{h}")

if __name__ == "__main__":
    main()
