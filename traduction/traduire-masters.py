#!/usr/bin/env python3
"""Traduit les masters serveur de FGO Arcade, japonais -> anglais.

POURQUOI. Le patch anglais couvre le CLIENT : 664 archives de ressources et
2224 des 2774 chaines de l executable. Il ne couvre pas le SERVEUR -- les
masters qu ARTEMiS sert lui-meme. D ou du japonais qui remonte en jeu :
`svt_name: でかノブ` dans les quetes cooperatives, `【サーヴァント】アルトリア`
dans les tirages.

CE QU IL FAIT. Extrait les valeurs japonaises des masters, les deduplique
(27998 lignes -> 13393 uniques), les traduit par lots via le modele local, et
ecrit un dictionnaire reutilisable. L application aux fichiers est SEPAREE :
ce programme ne modifie aucun master.

⚠️ REPRENABLE. Le dictionnaire est ecrit apres CHAQUE lot. Une interruption ne
perd qu un lot, et relancer reprend ou on s etait arrete.

⚠️ NE TRADUIT PAS LES CHAMPS `ruby`. Ce sont les lectures phonetiques
(furigana) : les traduire n a aucun sens.

⚠️ VERIFIE LES MARQUEURS. Si {0}, %d, %s ou \n disparaissent de la traduction,
le lot est refuse et retente. Une chaine qui perd son marqueur casse l affichage
du jeu.
"""
import argparse, json, pathlib, re, sys, time, urllib.error, urllib.request

JP = re.compile(r"[぀-ゟ゠-ヿ一-鿿]")
LIGNE = re.compile(r"^([a-z0-9_]+)\.(\d+)\.([a-z0-9_]+)=(.*)$")
MARQUEURS = re.compile(r"\{\d+\}|%[sd]|\\n")
# Tous les marqueurs ne se valent pas. Un {0} ou un %d perdu CASSE l affichage
# du jeu : le moteur substitue une valeur a cet endroit precis. Un \n perdu ne
# change que le retour a la ligne. Mesure a l appui : les chaines restantes
# font 57 caracteres en moyenne contre 21 pour les premieres, 35 % portent un
# marqueur et certaines en ont NEUF. Exiger la conservation exacte des \n sur
# un paragraphe faisait echouer un lot sur deux pour un defaut cosmetique.
STRICTS = re.compile(r"\{\d+\}|%[sd]")

SYSTEME = """You translate Fate/Grand Order Arcade game text from Japanese to English.

Rules:
- Keep every placeholder EXACTLY as-is: {0} {1} %d %s and the two characters \\n.
- Do not add or remove line breaks.
- Keep bracketed tags like 【...】 translated but still bracketed.
- Use the official FGO English terminology from the glossary below.
- Translate names of Servants as the community spells them, never phonetically.
- Answer with a JSON array of strings only: same length, same order, no commentary.

Glossary (Japanese -> English), authoritative:
{glossaire}"""

def lots(seq, n):
    """Regroupe par COUT et non par compte.

    Vingt noms de servants tiennent sans peine dans une requete ; vingt
    paragraphes de 150 caracteres truffes de sauts de ligne echouaient presque
    a chaque fois, et la reprise ligne par ligne ne sauvait plus que la moitie
    du lot. On facture donc chaque chaine a sa longueur et a ses marqueurs : le
    texte court garde des lots de vingt, le paragraphe part seul.
    """
    lot, cout = [], 0
    for t in seq:
        c = 1 + len(t) // 40 + 2 * len(MARQUEURS.findall(t))
        if lot and cout + c > n:
            yield lot
            lot, cout = [], 0
        lot.append(t)
        cout += c
    if lot:
        yield lot

def extraire(racine, repertoires):
    vals = {}
    for rep in repertoires:
        d = racine / rep
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.bin")):
            try:
                lignes = f.read_text(encoding="utf-8-sig", errors="ignore").splitlines()
            except OSError:
                continue
            for l in lignes:
                m = LIGNE.match(l)
                if not m:
                    continue
                champ, valeur = m.group(3), m.group(4)
                if "ruby" in champ or not JP.search(valeur):
                    continue
                vals.setdefault(valeur, 0)
                vals[valeur] += 1
    return vals

def appeler(url, modele, systeme, textes, delai):
    corps = {
        "model": modele, "temperature": 0.1,
        "max_tokens": max(800, 12 * sum(len(t) for t in textes) // 3),
        "messages": [{"role": "system", "content": systeme},
                     {"role": "user", "content": json.dumps(textes, ensure_ascii=False)}],
    }
    req = urllib.request.Request(url, json.dumps(corps).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=delai) as rep:
        d = json.load(rep)
    txt = d["choices"][0]["message"]["content"].strip()
    # le modele encadre parfois sa reponse d un bloc de code
    txt = re.sub(r"^```(?:json)?\s*|\s*```$", "", txt)
    i, j = txt.find("["), txt.rfind("]")
    if i < 0 or j < 0:
        raise ValueError("pas de tableau JSON dans la reponse")
    return json.loads(txt[i:j + 1])

def normaliser(t):
    """Les masters ecrivent les sauts de ligne en DEUX caracteres : \\ puis n.

    Le modele, lui, rend volontiers un vrai saut de ligne. Sans cette
    conversion, le controle des marqueurs rejetait un lot sur deux -- constate
    au premier essai : `marqueurs perdus : ['\\n'] -> []`.
    """
    return t.replace("\r\n", "\\n").replace("\n", "\\n")

def ecrire(chemin, donnees):
    """Ecriture atomique : une coupure ne peut pas laisser un fichier tronque."""
    tmp = chemin.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(donnees, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(chemin)

def valider(source, trad):
    if len(source) != len(trad):
        return f"longueurs differentes ({len(source)} vs {len(trad)})"
    for s, t in zip(source, trad):
        if not isinstance(t, str):
            return "element non textuel"
        if not t.strip():
            return f"traduction vide pour {s[:40]!r}"
        attendus = sorted(STRICTS.findall(s))
        obtenus = sorted(STRICTS.findall(t))
        if attendus != obtenus:
            return f"marqueurs perdus : {attendus} -> {obtenus} sur {s[:40]!r}"
    return None

def tenter(args, systeme_pour, lot, essais=3):
    """Traduit un lot, ou renvoie None si la validation echoue a chaque essai."""
    for n in range(essais):
        try:
            trad = appeler(args.url, args.modele, systeme_pour(lot), lot, args.delai)
            trad = [normaliser(t) if isinstance(t, str) else t for t in trad]
            probleme = valider(lot, trad)
            if probleme:
                raise ValueError(probleme)
            return trad
        except Exception:
            if n < essais - 1:
                time.sleep(3)
    return None

def main():
    a = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--masters", default="/home/ezvk/fgo-install/Server/data/fgo-master")
    a.add_argument("--glossaire", default="/home/ezvk/fgoac-linux/traduction/glossaire.json")
    a.add_argument("--sortie", default="/home/ezvk/fgoac-linux/traduction/dictionnaire.json")
    a.add_argument("--url", default="http://127.0.0.1:8090/v1/chat/completions")
    a.add_argument("--modele", default="Qwen3-VL-30B-A3B-Instruct-1M-MXFP4_MOE")
    a.add_argument("--lot", type=int, default=20)
    a.add_argument("--delai", type=int, default=600)
    a.add_argument("--repertoires", default="trc,flavor,skill,material,craft_essence,svt,np,synthesis,coop_quest,skill_func,rental_party_setting")
    a.add_argument("--limite", type=int, default=0, help="s arreter apres N chaines (essai)")
    args = a.parse_args()

    sortie = pathlib.Path(args.sortie)
    sortie.parent.mkdir(parents=True, exist_ok=True)
    glossaire = json.loads(pathlib.Path(args.glossaire).read_text(encoding="utf-8"))
    # ⚠️ 2474 entrees : les mettre TOUTES dans chaque requete couterait plus de
    # jetons que le texte a traduire. On n envoie que les termes qui
    # apparaissent reellement dans le lot.
    def systeme_pour(lot):
        pertinents = {k: v for k, v in glossaire.items() if any(k in t for t in lot)}
        if not pertinents:
            pertinents = {k: glossaire[k] for k in list(glossaire)[:20]}
        return SYSTEME.replace("{glossaire}",
                               "\n".join(f"  {k} -> {v}" for k, v in pertinents.items()))

    deja = {}
    if sortie.exists():
        deja = json.loads(sortie.read_text(encoding="utf-8"))
        print(f"reprise : {len(deja):,} chaines deja traduites", flush=True)

    vals = extraire(pathlib.Path(args.masters), args.repertoires.split(","))
    # les plus repetees d abord : le gain en jeu est immediat si on s arrete tot
    # ── CORRESPONDANCE DIRECTE ────────────────────────────────────────────
    # Beaucoup de valeurs SONT exactement un nom de carte ou de servant. Les
    # resoudre par le glossaire evite un appel au modele et garantit le nom
    # officiel -- le modele, lui, ecrivait "Kabuki Toudi" pour 茨木童子.
    directs = 0
    for v in vals:
        if v not in deja and v in glossaire:
            deja[v] = glossaire[v]
            directs += 1
    if directs:
        print(f"{directs:,} chaines resolues directement par le glossaire", flush=True)
        sortie.write_text(json.dumps(deja, ensure_ascii=False, indent=1), encoding="utf-8")

    restantes = [v for v, _ in sorted(vals.items(), key=lambda x: -x[1]) if v not in deja]
    if args.limite:
        restantes = restantes[:args.limite]
    print(f"{len(vals):,} chaines uniques | {len(restantes):,} a traduire", flush=True)
    if not restantes:
        print("rien a faire"); return

    t0 = time.time()
    faits = echecs = 0
    douteux = []
    for n, lot in enumerate(lots(restantes, args.lot), 1):
        trad = tenter(args, systeme_pour, lot)
        if trad is None:
            # ⚠️ ON NE JETTE PAS LE LOT ENTIER. Une seule chaine mal rendue --
            # typiquement une qui perd un saut de ligne -- ne doit pas en
            # emporter dix-neuf autres correctes. On reprend une par une.
            recuperes = {}
            for un in lot:
                r = tenter(args, systeme_pour, [un], essais=2)
                if r:
                    recuperes[un] = r[0]
                else:
                    douteux.append(un)
            deja.update(recuperes)
            faits += len(recuperes)
            echecs += len(lot) - len(recuperes)
            print(f"  lot {n} repris un par un : {len(recuperes)}/{len(lot)} sauves", flush=True)
            # ON ECRIT AUSSI ICI. Avant, l ecriture etait sautee quand le lot
            # partait en reprise : trente minutes de travail sont restees en
            # memoire parce que plus aucun lot ne passait entier.
            ecrire(sortie, deja)
            if douteux:
                ecrire(sortie.with_name("douteuses.json"), douteux)
            trad = None
        if trad:
            deja.update(dict(zip(lot, trad)))
            faits += len(lot)
            # ecriture atomique apres chaque lot : une coupure ne perd qu un lot
            ecrire(sortie, deja)
        if n % 5 == 0 or faits + echecs >= len(restantes):
            ecoule = time.time() - t0
            reste = len(restantes) - faits - echecs
            vitesse = faits / ecoule if ecoule else 0
            eta = reste / vitesse / 60 if vitesse else 0
            print(f"  {faits:,}/{len(restantes):,} faites, {echecs} echouees, "
                  f"{vitesse*60:.0f}/min, reste ~{eta:.0f} min", flush=True)
    if douteux:
        # Les chaines irrecuperables sont ECRITES A PART, jamais perdues en
        # silence : elles se relisent et se traduisent a la main.
        d = sortie.with_name("douteuses.json")
        d.write_text(json.dumps(douteux, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"{len(douteux)} chaines non traduites, listees dans {d}", flush=True)
    print(f"TERMINE : {faits:,} traduites, {echecs} echecs, "
          f"{(time.time()-t0)/60:.0f} min. Dictionnaire : {sortie}", flush=True)

if __name__ == "__main__":
    main()
