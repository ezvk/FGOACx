# FGO AC Linux Server

Faire tourner **Fate/Grand Order Arcade** et son serveur local **sous Linux**,
serveur en conteneurs et client sous Proton.

**Ça marche.** Écran de démarrage franchi, `ALL.Net : OK`, profil joueur créé,
tutoriel jouable, le tout streamé par Moonlight.

> ⚠️ **Ce dépôt ne contient aucun fichier de jeu** — ni binaire, ni carte, ni
> donnée. Uniquement des scripts, des correctifs et de la documentation. Il
> s'applique sur une installation que vous possédez déjà.

## Ce qu'il faut avoir

- Le paquet **FGO Arcade local platform de Cloud23333** (V1.00 + V1.01 + V1.02),
  et éventuellement le patch anglais **FGOAC-scooby**.
- Un GPU exposant **`GL_ARB_bindless_texture`** : NVIDIA, ou AMD sous Mesa.
  **Intel ne convient pas** — voir [docs/MATERIEL.md](docs/MATERIEL.md).
- podman (ou docker), et Proton via Steam, Heroic ou umu-launcher.

## Ce qui marche, ce qui ne marche pas

| | état |
|---|---|
| Serveur ARTEMiS + MariaDB en conteneurs | **oui** |
| Client sous Proton, jusqu'au jeu | **oui**, sur NVIDIA |
| Carte Aime, profil, deck, session de jeu | **oui** |
| Streaming Moonlight (Moonshine) | **oui**, tactile compris |
| Client sur GPU Intel | **non** — le shim qui émule `bindless_texture` casse un shader |
| Patch anglais | **oui**, sans `fgozh.dll` — voir [`client/appliquer-anglais.sh`](client/appliquer-anglais.sh) |
| Lecteur de cartes physique | vide — seul le launcher d'origine alimente sa mémoire partagée |
| Multijoueur | **non** — le serveur n'a ni lobby ni état partagé entre clients |

## Démarrage

### Serveur

```sh
FGOAC_SERVEUR=/chemin/vers/Server FGOAC_CLIENT=/chemin/vers/install \
  ./serveur/lancer-serveur.sh
```

L'image se construit depuis [`serveur/Containerfile`](serveur/Containerfile) :
`python:3.10-slim`, sans `pylibmc`, **avec `msgpack`** — requis par le titre FGO
mais absent de son `requirements.txt`.

Appliquer ensuite les deux correctifs de [`serveur/patches/`](serveur/patches),
tous deux indispensables sous Linux.

### Client

```sh
./client/generer-runtime.py --racine ~/fgo-install --serveur 192.168.1.60 \
                            --largeur 2560 --hauteur 1440 --entree keyboard
make -C client/fgostub                     # DLL de contournement, voir plus bas
./client/appliquer-anglais.sh ~/fgo-install   # anglais, réversible
FGOAC_PROTON=/chemin/vers/proton ./client/lancer.sh
```

⚠️ **`--entree keyboard`, pas `xinput`.** Le défaut du script d'origine est
`xinput` : sans manette, *rien ne répond*, et ça ne se voit pas — le tutoriel
enchaîne ses attaques scriptées tout seul. Commandes clavier : **WASD**
déplacement, **clic droit** attaque, Espace Noble Phantasm, clic gauche dans
les menus, Entrée maintenu pour la carte Aime.

## Les pièges, condensés

Chacun a coûté du temps. Le détail et les mesures sont dans
[docs/PORTAGE.md](docs/PORTAGE.md).

**Le shim AMD est à RETIRER sur NVIDIA et AMD.** Il émule
`ARB_bindless_texture` et produit un shader hors limites
(`0(763) : error C1068`) sur les cartes qui l'ont nativement. Et
`App/shader-cache-r2/` étant écrit à l'exécution, **il faut le purger** après
tout changement de pile graphique, sinon les erreurs rejouent.

**`segatools.runtime.ini` doit être en UTF-16LE avec BOM.**
`GetPrivateProfileStringW` l'exige. Sinon : `native-surface patch failed`,
`Win32=203`.

**`SetWindowFeedbackSetting` tue le processus.** `ago.exe` importe
statiquement cette API tactile que Wine n'implémente pas, et Wine avorte sur
ses stubs. [`client/fgostub`](client/fgostub) est une DLL de 9 Ko qui réécrit
cette seule entrée de la table d'imports vers un stub renvoyant `TRUE`.

**`logs/fgo_capture/failures.jsonl` avant tout.** ARTEMiS y enregistre chaque
échec de gestionnaire — commande, type et message d'exception — avant de la
relancer. Les journaux ordinaires n'en montrent **rien**. C'est ce fichier qui a
révélé que `start` levait une `FileNotFoundError` sur un fichier de données non
monté, ce que le jeu affichait comme « erreur de connexion réseau ».

**Le conteneur a besoin de cinq montages**, pas d'un seul. Le couplage
serveur → client est profond : `/Server` pour `data/fgo-master`, `/App` pour
`deck.json`, `/DEVICE` pour le manifeste des cartes.

Et surtout **`/state`, le plus facile à oublier** : le titre FGO persiste les
profils dans `../state/fgo-players.json`, chemin relatif à `/app` qui résout
hors de tout montage. Sans lui la progression s'écrit dans la couche éphémère
du conteneur, disparaît à chaque recréation, et le joueur refait le tutoriel
sans comprendre pourquoi.

**Ne pas lancer `FGOAC scooby.exe`.** Toute sa chaîne est en PowerShell, absent
de Wine — et PowerShell 7 portable ne s'exécute pas non plus dans un préfixe
Proton (témoin : `pwsh -Command "exit 42"` rend 0 et n'écrit aucun fichier).

## Crédits

**Cloud23333** a écrit la plateforme locale FGO Arcade — serveur, front-end et
hook — sans laquelle rien de tout ceci n'existe, et il la distribue
gratuitement. **FGOAC-scooby** (githubuser420x) fournit le patch anglais et le
launcher. **ARTEMiS** est le serveur de jeux d'arcade sur lequel tout repose
(WTFPL). **fluphus** a écrit le shim OpenGL. **Moonshine** (hgaiser) assure le
streaming.

**Fate/Grand Order Arcade appartient à SEGA et TYPE-MOON.**

## Licence

MIT pour les scripts et la documentation de ce dépôt. Les correctifs de
[`serveur/patches/`](serveur/patches) s'appliquent à ARTEMiS, sous WTFPL.
