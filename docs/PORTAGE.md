# Portage FGO Arcade — analyse du serveur

Source : paquet Cloud23333 **V1.00**, arbre `Server/` récupéré le 2026-09-16
depuis les volumes 1–4 (`unrar -kb`, la part5 manquait). 13 829 fichiers sur
13 987 ; les 158 absents sont dans `venv/Lib/site-packages/` — le venv Windows,
jeté de toute façon.

## Ce qui ne demande aucun portage

ARTEMiS embarque déjà `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`.
L'amont tourne sous Linux. Il n'y a pas de code à porter, il y a une pile
Windows à déposer.

Audit des 32 283 lignes de Python (`artemis/` + `tools/`) : **aucune dépendance
Windows dure** en dehors du seul module traité ci-dessous.

## Le seul module Windows — et pourquoi il ne bloque pas

`artemis/titles/fgo/event_damage_bridge.py` fait `ctypes.WinDLL('kernel32')`,
`from ctypes import wintypes` et `mmap.mmap(..., tagname=...)`. Sous Linux le
premier lève `AttributeError`, le second `ValueError`.

Trois protections, vérifiées dans `index.py:4400-4416` :

1. import **paresseux**, dans `_event_damage_channel()`, pas au niveau module ;
2. **opt-in** — sans `server.event_damage_capture: true`, retour avant l'import ;
3. `except (OSError, ValueError, AttributeError)` autour de l'import et de la
   construction — exactement les exceptions que Linux lève ici.

Conséquence : sous Linux le pont renvoie `None`, ARTEMiS tourne. Seule perte, la
capture native des dégâts d'événement, désactivée par défaut et annoncée par
l'auteur « not enabled by dispatch yet ».

## Le vrai travail de portage

### 1. ⚠️ `fgo_account.py` ne s'importe pas sans l'arbre client

`tools/fgo_account.py:59`, **au niveau module**, donc à l'import :

    SERVER_PROBE_PORT = int(json.loads(
        (SERVER_DIR.parent / 'App' / 'fgo-launcher.json').read_text(...)
    ).get('serverPorts', {}).get('http', 80))

Pas de `try`, pas de défaut : sur un déploiement serveur seul, où `App/`
n'existe pas, **l'import lève et l'outil est inutilisable**. C'est le piège
principal du découpage serveur/client sur deux machines.

Deux autres couplages vers le client, moins violents car lus à l'usage :

    :46  ../DEVICE/aime.txt
    :54  ../App/rom/multi/reward_master_level.txt

Donc : soit on déporte ces quelques fichiers avec le serveur, soit on patche.

### 2. Démarrage de MariaDB

`:57` `MARIADB_DAEMON = .../bin/mariadbd.exe`, utilisé en `:936-940` pour lancer
la base si elle est absente. Gardé par `MARIADB_DAEMON.exists()`, donc **il
dégrade proprement** : sous Linux il ne lance rien et ne casse rien. La base
vient du conteneur.

### 3. Les trois scripts PowerShell à remplacer

`Start-FGOLocalServer.ps1`, `Stop-FGOLocalServer.ps1`, `ServerSettings.ps1`.
C'est tout le périmètre PowerShell côté serveur.

### 4. `requirements.txt`

Retirer `pylibmc; platform_system != "Windows"` : ignoré sous Windows, il sera
**compilé sous Linux** et réclamera `libmemcached-dev` — pour rien, puisque
`enable_memcached: false`.

## Contraintes de version, mesurées

| | Paquet | Debian 13 |
|---|---|---|
| Python | **3.10** embarqué (`python310.dll`) ; `Dockerfile` amont en **3.9.15** | 3.13 |
| MariaDB | **10.11.16** (`mysql_upgrade_info`) | 11.8 |

`requirements.txt` épingle `sqlalchemy==1.4.46`, `starlette==0.52.1`,
`pyjwt==2.8.0`. Viser 3.10, pas 3.13.

→ Deux conteneurs (`python:3.10-slim` + `mariadb:10.11`) évitent les deux
migrations d'un coup.

## Configuration réelle de l'install

Rien à voir avec les défauts du script scooby.

| Service | Port |
|---|---|
| allnet / server | 777 |
| billing | 9999 |
| aimedb | 7777 |
| MariaDB | 8888 |
| frontend | 8080 (désactivé) |

`core.yaml` : `hostname: "192.168.1.42"`, `listen_address: 0.0.0.0`,
`log_dir: ../../logs`. L'install est **déjà** réglée pour une adresse du LAN et
non pour le réseau virtuel `192.168.100.1` — le mode serveur distant est le mode
en place.

Base : `aime` / utilisateur `aime`, `data/mariadb` récupéré intact (199 Mo,
674 fichiers ; les 3 fichiers à zéro octet le sont par nature).

---

# Résultat : le serveur tourne sous Linux (2026-09-16)

Sur **ishtar**, podman rootless, deux conteneurs dans un pod `fgo`.

    [2026-09-16 08:27:46] Aimedb  | INFO | Start on port 7777
    [2026-09-16 08:27:47] Core    | INFO | Artemis starting in production mode
    [2026-09-16 08:27:47] Title   | INFO | Serving 1 game codes on port 777
    [2026-09-16 08:27:47] Billing | INFO | Ready on port 9999

Contrôle de santé du launcher (`Get-FgoLocalHealth`) : **HTTP 200**, corps
`Service OK`. Les quatre ports ouverts, 1234 fermé comme témoin.

## Ce qu'il a fallu

1. **`python:3.10-slim`**, pas 3.9.15 ni 3.13.
2. **Retirer `pylibmc`** de `requirements.txt` (voir plus haut).
3. **Ajouter `msgpack==1.2.1`** — requis par `titles/fgo/index.py:17` mais
   ABSENT de `requirements.txt`. Trouvé en comparant les 54 paquets du venv
   Windows de l'amont avec ceux de l'image ; c'était le seul manque réel, les
   autres écarts étant `colorama`/`pyreadline3` (console Windows) et `meson`.
4. **MariaDB 10.11 sur le `data/mariadb` créé sous Windows** : démarre sans
   migration ni `mariadb-upgrade`. Base `aime`, 236 tables, 0 utilisateur —
   c'est une base V1.00 vierge. Le pod donne un `localhost` commun, donc en
   lançant MariaDB avec `--port=8888` **`core.yaml` n'a aucune modification à
   subir**.

## ⚠️ Piège de copie, à ne pas refaire

Un `rsync --exclude 'data/'` s'applique à **tous** les niveaux : il emporte
`artemis/core/data/` et `artemis/titles/fgo/data/`, et ARTEMiS meurt sur
`ModuleNotFoundError: No module named 'core.data'`. N'exclure que
`__pycache__/`.

## Ce qui reste

- **Port 777 et podman rootless.** `net.ipv4.ip_unprivileged_port_start` vaut
  1024 sur ishtar ; témoin : liaison de 777 refusée, de 9999 acceptée. Le pod
  écoute bien sur 777 en interne, mais on ne peut pas le publier vers le LAN.
  Deux voies : `boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 777`
  dans la conf NixOS d'ishtar, ou déplacer le port ALL.Net — il est
  configurable des deux côtés via `fgo_server_config.py` (`core.yaml` +
  `segatools.ini` `dns.startupPort`).
- **`fgo_account.py`** : le correctif de l'import (cf. plus haut).
- **Déclaratif** : passer le pod en quadlet podman dans le dépôt `horde`.

---

# Récupération des sources (2026-09-16)

## ⚠️ Le quota Google Drive, et comment il ment

Le partage Drive de l'amont est **épuisé** : « Download quota exceeded » sur
tous les fichiers. Mais Drive ne le dit pas tout de suite.

1. Une requête sur `drive.usercontent.google.com/download?id=…&export=download`
   renvoie un interstitiel **« Virus scan warning »** de 2442 octets, identique
   pour tous les volumes, **sans un mot sur le quota**.
2. Ce n'est qu'après avoir renvoyé le formulaire avec `confirm=t&uuid=…` qu'on
   reçoit 2009 octets de « Quota exceeded ».

Un script qui ne lit pas le corps de la réponse croit donc avoir téléchargé.
**Toujours vérifier la taille ET le contenu.**

## Le contournement qui marche : le zip de dossier

Le quota est **par fichier**. Le zip que Drive fabrique quand on télécharge un
**dossier** depuis l'interface web n'est pas soumis au même compteur.

C'est ainsi que `FGOA_Cloud23333.part5.rar` (2 015 040 814 o) est arrivé :
dans `V1.00-20260916T075447Z-1-001.zip`, intègre (`unzip -t` sans erreur),
alors que son téléchargement direct restait refusé.

## Miroirs : deux culs-de-sac

- **123Pan** — `code 5112`, « 您需要注册登录或付费后下载 ». Vérifié avec les
  métadonnées exactes du listing pour écarter une requête malformée. Et son
  découpage de la V1.00 est **différent** (2 volumes de 16,1 et 9,5 Go contre 5
  de 5,5 Gio) : ses volumes ne sont donc pas interchangeables avec ceux de Drive.
- **Baidu** — inscription avec numéro de téléphone chinois. `baidupcs-go` 4.0.2
  est dans nixpkgs et fonctionne, mais le compte reste le mur.

## ⚠️ Outils d'archive : ce que chacun sait faire

Mesuré sur les vraies archives, pas supposé :

| | lister | extraire |
|---|---|---|
| `unar` | oui | **NON** — s'arrête au 1er volume, **sort en code 0** |
| `p7zip` | non (`Errors: 1`) | non |
| `_7zz` | **oui**, tous volumes | **NON** (`Open Errors: 1`) |
| `unrar` (non libre) | oui | **oui**, et `-kb` sauve un lot incomplet |

Donc : `7zz` pour inspecter, `unrar` pour extraire. Et `unrar -kb` a sorti
13 829 fichiers sur 13 987 du `Server/` alors qu'il manquait un volume.

⚠️ Le listing de `7zz` vient de l'index **QuickOpen** du RAR5, qui énumère
*tous* les fichiers, y compris ceux des volumes absents. Lister n'est pas avoir.

## ⚠️ Google Drive renomme les volumes

Les fichiers arrivent en `FGOA_Cloud23333.part1-003.rar`, `part2-005.rar`… Les
suffixes sont des numéros de désambiguïsation de Drive. `7zz` les prend pour le
motif de volume et cherche `part1-004.rar`, qui n'existe pas, pendant que les
autres volumes ne sont jamais lus. **Renommer avant toute chose.**

## Deux sources, et ce que chacune apporte

`/mnt/ygg/Fate Grand Order Arcade (SDEJ 11.00.00).7z` (21,9 Go, 31 880 entrées)
est le **dump d'arcade brut**. Diff avec le paquet Cloud V1.00 :

- 104 fichiers seulement sont propres à Cloud dans `App/` — dont
  `fgohook.dll`, `inject.exe`, `amdaemon.exe`, `fgo-launcher.json`, `ICF1/2`,
  les BGM et les manuels ;
- tout le reste du jeu (25 Go) est identique, mêmes dates (2025-06-14).

Ni l'un ni l'autre ne porte `App/segatools.ini` ni `App/Tools/Locale_Remulator/`
— ceux-là viennent de la **V1.01**, que `FGO_Runtime.dll` accompagne (elle est
aussi dans le manifeste V1.02).

## ⚠️ Yggdrasil : l'export parent l'emporte

`showmount -e 192.168.1.21` affiche `/volume1/Yggdrasil` restreint à quatre IP
(.38, .36, .133, .25) — mais la ligne suivante, `/volume1
192.168.1.25/255.255.255.0`, est une notation **adresse/masque** qui désigne le
`192.168.1.0/24` entier. Le montage de `/volume1/Yggdrasil` passe donc par
l'export parent et **fonctionne depuis n'importe quelle machine du LAN**.
Inutile de toucher aux ACL, et inutile de recopier les 21,9 Go.

---

# Assemblage de l'installation client (2026-09-16)

Sur **utu**, `~/fgo-install` — 26 Go, 54 927 fichiers, V1.00 + V1.01 + V1.02.

## V1.00

`unrar x` sur les 5 volumes réunis : `CODE=0`, aucune erreur. Contrôle des
fichiers exigés par `FGO_EnvironmentCheck.ps1` : tous présents.

160 fichiers vides sur disque — et **tous** déclarés `Size = 0` dans l'archive,
donc vides par nature. Zéro perte réelle.

## ⚠️ Ce que la part5 contenait, contre toute attente

`App/segatools.ini` et tout `App/Tools/Locale_Remulator/` sont dans la **part5**,
pas dans la V1.01 comme je l'avais déduit. L'inventaire qui disait le contraire
avait été fait sans la part5 : le listing passe de 51 507 à **56 354 entrées**
une fois le volume ajouté. Leçon : ne pas conclure d'une liste tirée d'un lot
incomplet, même quand l'index QuickOpen prétend tout énumérer.

## ⚠️ Les deux manifestes ne sont pas au même format

| | V1.01 | V1.02 |
|---|---|---|
| BOM UTF-8 | oui | oui |
| fins de ligne | CRLF | CRLF |
| séparateur | **antislash** `App\rom\…` | **barre oblique** `App/rom/…` |

Un script qui ne normalise pas les trois croit que 1013 fichiers sur 1017
manquent. Normaliser BOM + CRLF + séparateur avant toute comparaison.

## ⚠️ Casse : contrôle obligatoire sous Linux

Windows ignore la casse, pas nous : un chemin de manifeste qui diffère en casse
d'un chemin existant créerait un doublon au lieu de remplacer. Contrôlé avant
copie sur les 2 067 entrées des deux manifestes : **0 collision**. 33 fichiers
réellement nouveaux en V1.01, 59 en V1.02.

## Application des mises à jour

`Update-1.0N.ps1` reproduit en shell : contrôle de complétude du paquet,
sauvegarde dans `_update-backup/`, copie, retrait de `App/fgohook.pending.dll`.
Puis la migration de `App/fgo-launcher.json` : `serverHost`,
`localServerLauncher`, `autoStartLocalServer` ajoutés s'ils manquent,
`wasapiShared=true` et `audioHook=false` forcés.

La récupération des renforcements (`repair_fgo_grail.py`) est **ignorée** : elle
ne se déclenche que si `Server/state/fgo-players.json` contient des profils, ce
qui n'est pas le cas d'une installation neuve.

Résultat : 1017 puis 1050 fichiers copiés. Binaires après mise à jour —
`fgohook.dll` 811 008 (V1.00 en donnait 761 856), `inject.exe` 169 472 (contre
18 432), `FGO_Runtime.dll` 6 656, `segatools.ini` 9 476.

`App/fgo-launcher.json` déclare `serverPorts: {http:777, billing:9999,
aime:7777, database:8888}` — cohérent avec le `core.yaml` du serveur.

## Patch anglais scooby v1.1.2

Release GitHub (pas de quota) : 633 Mo, SHA-256 conforme à l'asset `.sha256`.

`Apply-EN-Patch.ps1` reproduit en Python : pour chaque entrée de
`manifest.json` (1695, chemins en antislash), copie de `payload/<chemin>` vers
l'install avec vérification SHA-256 des deux côtés. Résultat : **1691 copiés,
3 déjà en place, 0 somme incorrecte**. La seule entrée hors `payload/` est
`FGOAC scooby.exe`, qui vit à la racine du paquet — vérifié séparément,
134,1 Mo, somme conforme.

Puis le marqueur `App/zh/en-patch.json` (`version` + `manifestHash`, ce que le
script relit pour son idempotence) et le contrôle de `chineseEnabled`, déjà à
`true` — c'est le drapeau qui fait lire `App\zh` au jeu.

**État final : 29 Go, 58 938 fichiers, `App/zh/` peuplé de 1687 fichiers.**

---

# Client sous Proton (2026-09-16) — état et diagnostic

Sur **utu** : Heroic 2.22.1, Proton-CachyOS-11.0, préfixe
`~/Games/Heroic/Prefixes/shared`, umu-launcher 1.4.4, Mesa 26.2.99 sur Arc B390.

## Ce qui marche

La chaîne segatools tourne sous Wine. `inject.exe` injecte, `fgohook.dll`
installe tous ses hooks, `ago.exe` lance `amdaemon.exe` lui-même, la fenêtre est
créée **et affichée** en 1280x720, l'audio WASAPI tourne (441 frames rendues),
les shaders se compilent.

## ⚠️ Ne PAS lancer `FGOAC scooby.exe` sous Wine

Toute la chaîne du launcher est en **PowerShell**, absent de Wine. On appelle
`inject.exe` directement :

    inject.exe -d -k fgostub.dll -k fgohook.dll ago.exe -hdtv720 -w --wasapi-shared

`-w` et `--wasapi-shared` sont **après** `ago.exe` : ils lui sont destinés.
`inject.exe` a son propre `-w` (« attendre la cible »), incompatible avec `-d`.

Avec `cabinetMode: saved`, `-sm` **n'est pas passé** (`if ($effectiveCabinetMode
-ne "saved")`).

## ⚠️ Ce que le launcher fait et qu'il faut refaire à la main

1. **Générer `DEVICE/runtime/segatools.runtime.ini`** : copie de
   `App/segatools.ini`, puis ~40 clés réécrites (ports dns, netenv, `gfx`
   width/height/logical, `amvideo`, `io4`, `touch`, `clock`), **et réécriture en
   UTF-16 avec BOM** — `GetPrivateProfileStringW` l'exige. Sans ce fichier :
   `Resolution mode: native-surface patch failed (hr=80070057) ... Win32=203`,
   c'est-à-dire `ERROR_ENVVAR_NOT_FOUND`.
2. **Poser les variables d'environnement** : `SEGATOOLS_CONFIG_PATH`,
   `FGO_INSTALL_ROOT`, `FGO_TARGET_FPS`, `FGO_LOCAL_{HTTP,BILLING,AIME}_PORT`,
   `FGO_LOCAL_NETWORK`, `FGO_FULL_SURFACE_FBO`, plus la douzaine de `FGO_*`
   graphiques.
3. Écrire `DEVICE/runtime/amdaemon_main.json` (`develop_version: 11.00`).
4. **Tuer les restes** `ago/amdaemon/inject` avant chaque lancement : le
   launcher le fait, et l'auteur note que pré-démarrer AMDaemon casse la
   poignée de main d'état du processus.

## ⚠️ Le shim OpenGL : `opengl32real.dll` est obligatoire

`compat/amd-shim/opengl32.dll` (fluphus) est un **proxy DLL** dont les exports
sont des *forwarders* vers **`opengl32real.<fonction>`**. Il faut donc copier le
vrai `opengl32.dll` à côté sous ce nom — sous Proton :

    cp <proton>/files/lib/wine/x86_64-windows/opengl32.dll App/opengl32real.dll

plus `WINEDLLOVERRIDES="opengl32=n,b"`. Sans `opengl32real.dll`, tous les
forwarders pointent dans le vide.

**Pourquoi ce shim est indispensable ici** : `ago.exe` résout *toutes* ses
fonctions GL par `wglGetProcAddress`, **y compris le cœur OpenGL 1.1**. La
spécification autorise NULL pour celles-là ; le pilote NVIDIA les renvoie quand
même, Wine non (203 résolues sur 402 demandées, `Function glClear unknown`…).
D'où un appel vers l'adresse 0. **C'est exactement l'« incompatibilité AMD/Intel »
que l'auteur documente**, et elle vaut aussi pour Wine sur NVIDIA.

## ⚠️ `SetWindowFeedbackSetting` : Wine avorte le processus

`ago.exe` importe **statiquement** `USER32!SetWindowFeedbackSetting`
(ordinal 0311), une API de retour visuel tactile que Wine n'implémente pas.
Wine lève `EXCEPTION_WINE_STUB` (0x80000100) et **tue le processus**.
Désactiver `[touch] enable` n'y change rien : l'import est statique.

Contournement écrit ici : `~/fgostub/fgostub.c`, une DLL de 8,9 Ko compilée en
croisé (`pkgsCross.mingwW64`, sans CRT) qui réécrit cette seule entrée de la
table d'imports vers un stub renvoyant `TRUE`. Injectée par `-k` avant
`fgohook`. Elle journalise dans `logs/fgostub.log`.

## Où ça bloque aujourd'hui

    Debugger: unhandled exception 0xc0000005 at 0000000140C084F7

Instruction fautive `mov 0x1c(%rax),%edx` : `rax`, chargé depuis `*rdi`, est
invalide. C'est dans une boucle qui lit un identifiant à l'offset 0x1c d'un
objet puis appelle une fonction de la table GL (`0x141c8c100`) — donc une
liaison de ressource (texture/sampler) dont l'objet est nul. Vraisemblablement
une ressource GL dont la création a échoué plus tôt sous Mesa.

Piste suivante : tracer les erreurs GL (`MESA_DEBUG`, `WINEDEBUG=+opengl`) pour
trouver la création qui échoue, plutôt que de deviner.

## Second problème, indépendant

`fgozh.dll` (le patch anglais) charge, écrit son index —
`REDIRECT_INDEX files=1683` — puis **son `DllMain` renvoie FALSE** :
`DLL failed to load inside target process`. Tous les essais ci-dessus tournent
donc **sans** l'anglais. À traiter séparément une fois le jeu démarré.

---

# Test NVIDIA (ishtar, 2026-09-16) — la cause réelle

Install transférée sur ishtar (55 378 fichiers, 27 Go), préfixe dédié
`~/Games/Heroic/Prefixes/FGOA`, **GE-Proton11-6**, RTX 4060 Ti pilote 610.57.04.
`X:` pointe sur `/home/ezvk` dans les deux préfixes, donc la configuration
runtime se transpose sans modification.

## Le crash est identique sur NVIDIA

    Debugger: unhandled exception 0xc0000005 at 0000000140C084F7

**La même adresse qu'avec Mesa sur Arc B390.** Ce n'est donc ni un problème de
pilote Intel, ni un défaut de Mesa. L'avertissement « NVIDIA seulement » de
l'amont ne couvre pas ce cas.

## Ce que NVIDIA révèle et que Mesa taisait

    Fragment info
    -------------
    0(763) : error C1068: array index out of bounds

**Huit shaders fragment qui ne compilent pas.** `C1068` est un code du
compilateur GLSL de NVIDIA. Le programme reste nul, et le jeu le déréférence
plus loin — `mov 0x1c(%rax),%edx` à `ago.exe+0xC084F7`, dans une boucle de
liaison de ressources. Le crash n'est qu'une conséquence.

## Bisection : ce n'est pas le hook

| configuration | réécritures de shader | erreurs | crash |
|---|---|---|---|
| toutes les variables `FGO_*` graphiques | 12 | 8 | oui |
| `FGO_MOTION_BLUR=1`, patches UI/HUD désactivés | 12 | 8 | oui |
| variables réduites au strict minimum | 12 | 8 | oui |
| **sans `fgohook` du tout** | **0** | **8** | oui |

Les réécritures de `fgohook` (« shader role patched: UI visibility ») sont hors
de cause : sans lui, zéro patch et exactement les mêmes huit erreurs.

**Conclusion : c'est un shader livré par le jeu qui ne compile pas sous Wine.**
Piste suivante : extraire la source du shader fautif pour lire la ligne 763 —
`__GL_WRITE_TEXT_SHADERS=1` côté NVIDIA, ou apitrace. L'hypothèse à vérifier est
un tableau dimensionné d'après une limite `GL_MAX_*` que Wine rapporte
différemment de la pile Windows.

## Au passage : PowerShell 7 ne tourne pas sous GE-Proton11-6

Installé dans le préfixe (325 fichiers, runtime .NET complet). Témoin :
`pwsh.exe -Command "exit 42"` renvoie **`CODE=0`**, et un script demandant
d'écrire un fichier n'écrit rien. Fichier `.bat` vérifié octet par octet.

Donc **la chaîne officielle est inaccessible** : `FGOAC scooby.exe` est du WPF
qui délègue tout à PowerShell. Il faut appeler `inject.exe` directement et
reproduire à la main ce que le launcher prépare.

---

# ✅ LE JEU DÉMARRE (ishtar, 2026-09-16 ~13h)

Écran d'attente atteint : **画面をタッチしてください** (« touchez l'écran »).
`ago.exe` stable au-delà de cinq minutes, serveur ARTEMiS local répondant.

## ⚠️ Ce qui débloquait tout : RETIRER le shim AMD sur NVIDIA

Le crash `0xC0000005 at ago.exe+0xC084F7` venait de **huit shaders fragment qui
ne compilaient pas** :

    0(763) : error C1068: array index out of bounds

Ligne 763 du shader fautif, trouvée dans `App/shader-cache-r2/` :

    uvec4 pair_words = _amdshim_map_handle_pairs[i >> 1];

Le préfixe **`_amdshim_`** dit tout : c'est une réécriture du shim de fluphus,
qui émule `GL_ARB_bindless_texture` pour les GPU qui ne l'ont pas. **Les NVIDIA
l'ont nativement** — le README de l'amont le dit d'ailleurs, le shim « ne
fonctionne pas » sur NVIDIA. Je le lui avais imposé à tort via
`WINEDLLOVERRIDES`.

⚠️ **Et `App/shader-cache-r2/` est écrit à l'exécution.** Les shaders réécrits y
restent en cache : changer de pile GL sans purger le cache rejoue les mêmes
erreurs. **Toujours vider ce dossier après un changement de configuration GL.**

Recette sur NVIDIA :

    rm -f App/opengl32.dll App/opengl32real.dll     # pas de shim
    rm -rf App/shader-cache-r2 && mkdir App/shader-cache-r2
    # et retirer WINEDLLOVERRIDES="opengl32=n,b"

Sur Intel/AMD le shim reste nécessaire — mais il faudra alors comprendre
pourquoi sa réécriture produit un index hors limites sous Wine.

## ⚠️ `core.yaml` : `hostname` est l'adresse annoncée AU CLIENT

Héritée de la machine d'origine, elle valait `192.168.1.42`. Le jeu
s'authentifiait correctement puis partait vers cette adresse morte :

    Allnet | Allnet response: {'uri': 'http://192.168.1.42:777/SDEJ/1100/', ...}

Résultat, `NET PARAM : WAIT (0/1)` à l'écran. Mise à `192.168.1.60` (l'adresse
réelle du serveur), **`NET PARAM : OK`**.

## État de l'écran de démarrage

    TOUCH PANEL / CABINET LED / CARD SYSTEM / DECK READER / PRINTER : OK
    ALL.Net : OK        DATA INFORMATION : OK        NET PARAM : OK
    Location Server : WAIT (A, 1)      <- non bloquant, le jeu passe outre

## Points restants, non bloquants

- **`Aimedb | ERROR | Store ID cannot be 0!`**, une fois par minute, et
  `Failed to send aime play log.` côté `amdaemon`. Contrôle strict dans
  `core/adb_handlers/base.py:121`. Le jeu démarre quand même.
- **Chemins serveur → client.** ARTEMiS en conteneur cherche `/App/deck.json`
  et `/App/rom/aet` : c'est le couplage documenté plus haut. Conséquence
  visible : bannières de summon ignorées.
- **`fgozh.dll` toujours pas chargé**, donc **le jeu est en japonais**.
  C'est le prochain chantier.

## Recette complète qui marche (ishtar, GE-Proton11-6, RTX 4060 Ti)

1. Générer `DEVICE/runtime/segatools.runtime.ini` (UTF-16LE + BOM).
2. Écrire `DEVICE/runtime/amdaemon_main.json`.
3. `App/fgostub.dll` injecté en premier (neutralise
   `SetWindowFeedbackSetting`).
4. Pas de shim GL, cache de shaders vide.
5. `core.yaml` `hostname` = adresse réelle du serveur.
6. Variables `SEGATOOLS_CONFIG_PATH`, `FGO_INSTALL_ROOT`, `FGO_TARGET_FPS`,
   `FGO_LOCAL_*_PORT`, `FGO_FULL_SURFACE_FBO`.
7. `inject.exe -d -k fgostub.dll -k fgohook.dll ago.exe -hdtv720 -w
   --wasapi-shared`

---

# ✅ CHAÎNE COMPLÈTE (2026-09-16 ~13h48)

Serveur ARTEMiS + MariaDB en conteneurs sur ishtar, client sous Proton dans le
compositeur de Moonshine, flux Moonlight vers un client distant. Profil joueur
créé, `pre_start` accepté : le jeu est jouable.

## ⚠️ `Store ID cannot be 0!` — le dernier verrou

`amdaemon` envoyait `store_id = 0`, vérifié en décodant le paquet ADB : les
quatre octets entre `game_id` (« SDEJ ») et le keychip sont nuls. ARTEMiS le
refusait (`core/adb_handlers/base.py:121`), d'où `Failed to send aime play log.`
une fois par minute et `Location Server : WAIT` à l'écran.

C'est un contrôle écrit pour de vraies installations en salle : `store_id`
identifie une **boutique**, notion qui n'existe pas dans un déploiement local
mono-borne. Assoupli en forçant la valeur à 1. Effet immédiat :

    Aimedb | Register access code 95093735305876512151 -> user_id 9
    FGO    | Registered local FGO profile 9 for aime:9
    FGO    | Offline response for pre_start: 352 bytes, 14 body fields

Sauvegarde : `base.py.avant-storeid`.

## ⚠️ Moonshine : `launch_timeout_secs` NE mesure PAS le démarrage du jeu

Piège coûteux. Il est passé à `start_transient_service` comme délai d'attente
que l'**unité systemd** passe en état actif (`application.rs:169`), pas que le
jeu soit prêt. Et le webserver a un plafond **codé en dur à 60 s**
(`webserver/mod.rs:837`) au-delà duquel il démonte la session.

Une valeur supérieure à 60 garantit donc l'échec : testé avec 120, le jeu
démarrait normalement mais la session était coupée pendant qu'il montait.
**30 s** fonctionne — mesuré, l'unité met ~30 s à être déclarée active.

## Bruit à ne pas confondre avec des pannes

- ~200 `Registry: RegGetValueW Failed to find (null)\Driver, passing on` et
  variantes : le jeu énumère des clés de pilotes que Wine ne crée pas, et le
  hook passe outre. Tous se terminent par `passing on`.
- `Printer: C3XXusb: chcusb_getErrorLog` : interrogation périodique de
  l'imprimante de cartes émulée, pas une erreur.
- `drkonqi-coredump-launcher` en échec côté systemd : le gestionnaire de
  plantage de KDE hors session Plasma, sans rapport.

## Reste à faire

- **`fgozh.dll`** ne se charge toujours pas : le jeu est **en japonais**.
- `Location Server : WAIT (A, 1)` — à revérifier maintenant que l'Aime passe.
- Chemins `/App/deck.json` et `/App/rom/aet` introuvables côté serveur
  conteneurisé (couplage serveur→client documenté plus haut).

---

# ✅✅ EN JEU (2026-09-16 ~14h30)

Tutoriel atteint, **`Location Server : OK`**. Chaîne complète : ARTEMiS +
MariaDB en conteneurs sur ishtar, client sous Proton dans le compositeur de
Moonshine, flux Moonlight vers un Mac en bureau distant.

## Les trois derniers verrous, dans l'ordre où ils sont tombés

### 1. ⚠️ `Store ID cannot be 0!` → `Location Server : WAIT`

`amdaemon` envoie `store_id = 0` (déploiement mono-borne : pas de boutique).
Contrôle d'ARTEMiS assoupli dans `core/adb_handlers/base.py`. C'est ce qui
faisait aussi `Failed to send aime play log.` une fois par minute.

### 2. ⚠️ Chemins Windows traités par un serveur Linux

`titles/fgo/index.py:805` faisait :

    selected_name = path.basename(str(selected_card).replace("/", "\\"))

Correct sous Windows, **faux sous Linux** : `posixpath.basename` ne connaît pas
l'antislash comme séparateur et renvoie le chemin entier. Résultat :
`Built FGO card inventory: 0 selected card(s)` **quelle que soit la notation
employée dans deck.json**. Corrigé en portable :

    selected_name = str(selected_card).replace("\\", "/").rsplit("/", 1)[-1]

### 3. ⚠️ `start` levait FileNotFoundError, invisible dans les journaux

Treize échecs identiques, **aucune trace dans le log ordinaire** :

    [Errno 2] No such file or directory: '/Server/data/fgo-master/talk_unlocks.json'

L'exception remontait au framework, qui renvoyait une erreur HTTP — d'où
« erreur de connexion réseau » côté jeu et retour à l'écran de départ, en
boucle.

**⚠️ OÙ LE TROUVER : `logs/fgo_capture/failures.jsonl`.** ARTEMiS y enregistre
chaque échec de gestionnaire (commande, type et message d'exception) avant de
la relancer — `index.py:20685-20701`. Sans ce fichier, le diagnostic était
invisible. **À consulter en premier quand une commande reste sans réponse.**

## Les quatre montages nécessaires au conteneur

Le couplage serveur → client est plus profond que l'audit statique ne le
montrait :

    -v <serveur>/Server/artemis:/app
    -v <serveur>/Server:/Server:ro        <- data/fgo-master, indispensable a `start`
    -v <client>/App:/App:ro               <- deck.json, rom/aet
    -v <client>/DEVICE:/DEVICE:ro         <- print/FGO11_AllServants + manifeste

## Ce qui reste

- **`fgozh.dll`** ne se charge pas : le jeu est **en japonais**.
- **Deck** : les 10 Craft Essences de ma sélection produisent
  `Selected FGO servant id is outside uint16: 0` — une CE n'a pas d'identifiant
  de Servant. À remplacer par des Servants.
- **Lecteur de cartes physique** : la mémoire partagée de 1321 octets
  (`1 + 30 × 44`) reste vide, seul le launcher l'alimente. Non bloquant jusqu'ici.
- Le billing (port 9999) n'est jamais contacté ; la chaîne TLS est pourtant
  valide (`server.pem` signé par `DEVICE/ca.crt`, `CN=ib.naominet.jp`).
