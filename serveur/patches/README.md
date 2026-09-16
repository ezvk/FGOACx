# Correctifs serveur

Ce répertoire contient **nos modifications** d'ARTEMiS, sous forme de correctifs
lisibles. Il ne contient **pas** l'arbre du serveur.

## Pourquoi des correctifs et pas l'arbre

`titles/fgo/` n'existe pas dans ARTEMiS amont : c'est l'apport du paquet de
Cloud23333 et du patch anglais V1.02 — 34 fichiers, 4,3 Mo, dont un `index.py`
d'un million de caractères. C'est du **code tiers**, et ce dépôt public n'a pas
à le redistribuer. Il en garde les différences, qui sont les nôtres.

## Où vit l'historique complet

Dans un dépôt **git local**, sur la machine serveur, à la racine de l'arbre
ARTEMiS (`Server/artemis`). Cet arbre a l'amont pour référence, ce qui rend nos
modifications immédiatement visibles :

```
git remote rename origin upstream
git remote set-url --push upstream DISABLED-no-push   # jamais pousser chez l'amont
git checkout -b local
```

⚠️ **Le paquet redistribue l'arbre avec des fins de ligne CRLF.** 424 fichiers
apparaissent modifiés, pour 84162 insertions et 84147 suppressions — presque
symétrique, donc du bruit. Pour voir les vraies différences :

```
git diff --ignore-cr-at-eol --ignore-all-space upstream/master
```

Ainsi filtré, **trois** fichiers seulement diffèrent réellement de l'amont.
Isoler ce bruit dans un commit dédié rend tout l'historique suivant lisible.

⚠️ `config/` est déjà couvert par le `.gitignore` amont — les mots de passe de
base et le `id_secret` ne partent donc pas dans l'historique. Le vérifier avant
tout nouveau dépôt : `git check-ignore -v config/core.yaml`.

## Les correctifs

| fichier | ce qu'il corrige |
|---|---|
| `01-store-id.patch` | `core/adb_handlers/base.py` — AMDaemon envoie `store_id = 0` en déploiement mono-borne ; le contrôle d'origine vise les installations en salle et rejetait la borne |
| `02-basename-linux.patch` | `titles/fgo/index.py` — `path.basename` appliqué à des chemins Windows ne découpe rien sous Linux ; l'inventaire de cartes tombait à zéro |
| `03-fenetre-appariement.patch` | `titles/fgo/index.py` — tous les délais d'appariement valaient zéro, donc aucune fenêtre pour trouver un humain et un bot qui entre immédiatement |

## Ce qui n'est pas un correctif

**Les poids de tirage** ne sont pas du code : `config/fgo_summon_weights.json`
est un fichier de configuration prévu par le serveur. Livré avec le paquet, il
mettait `tc_id 6` à 1 et les ~1300 autres cartes à 0 — d'où un gacha qui rendait
toujours le même servant. Un fichier **absent** signifie « uniforme sur tout le
roster éligible », ce qui remonte le pool à 1328 cartes. Format, si on veut le
régler :

```json
{ "version": 1, "weights": { "<tc_id>": <poids entier de 0 à 1000000> } }
```

Les identifiants omis valent zéro. Composition mesurée du pool uniforme :
**92,1 % de Craft Essences** (TrcTypeId 2) contre **7,9 % de servants**
(TrcTypeId 1) — soit un servant sur 12,7.
