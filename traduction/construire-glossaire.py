import json, pathlib, re
JP = re.compile(r"[぀-ゟ゠-ヿ一-鿿]")
base = json.loads(pathlib.Path("glossaire.json").read_text(encoding="utf-8"))
avant = len(base)
ajouts = {"servant": 0, "ce": 0}
for quoi, cle in (("servant", "servant"), ("ce", "ce")):
    jp = {x["id"]: x["name"] for x in json.load(open(f"basic_{quoi}_JP.json"))}
    na = {x["id"]: x["name"] for x in json.load(open(f"basic_{quoi}_NA.json"))}
    for i, nom_jp in jp.items():
        nom_en = na.get(i)
        if not nom_en or nom_en == nom_jp:
            continue
        if not JP.search(nom_jp) or JP.search(nom_en):
            continue           # on n ajoute que des paires japonais -> latin
        if nom_jp in base:
            continue
        base[nom_jp] = nom_en
        ajouts[cle] += 1
pathlib.Path("glossaire.json").write_text(json.dumps(base, ensure_ascii=False, indent=1), encoding="utf-8")
print(f"glossaire : {avant} -> {len(base)} entrees")
print(f"   servants ajoutes : {ajouts['servant']}")
print(f"   craft essences   : {ajouts['ce']}")
print("\nexemples :")
for k in ("茨木童子", "酒呑童子", "両儀式", "カレイドスコープ", "２０３０年の欠片"):
    if k in base: print(f"   {k} -> {base[k]}")
