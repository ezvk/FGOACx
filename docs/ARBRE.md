# Arbre de connaissances — FGO Arcade sous Linux

Carte du terrain. Chaque nœud dit **ce qui est établi**, **comment on le sait**,
et **ce qui reste ouvert**. Les mesures priment sur les suppositions : quand une
affirmation n'a pas été vérifiée, c'est écrit.

---

## 1. LE PAQUET

    FGO Arcade (SDEJ 11.00.00)          dump d'arcade brut, 25 Go
      └─ V1.00 Cloud23333               + AMFS, DEVICE, GameData, Server
           └─ V1.01                     + segatools.ini, Locale_Remulator, FGO_Runtime.dll
                └─ V1.02                + 22 fichiers Server/, correctif 4102
                     └─ FGOAC-scooby    + 1689 fichiers App/ (anglais), 5 Server/

**Établi.** Les trois couches s'appliquent dans l'ordre. Vérifié par SHA-256 :
sur les 22 fichiers `Server/` du manifeste V1.02, 17 sont identiques à l'octet
près après application, et les 5 écarts sont exactement ceux que scooby écrase.

⚠️ **Scooby ne traduit rien côté serveur** : 1689 de ses 1695 fichiers sont dans
`App/`, les 5 autres sont fonctionnels. Il n'y a pas de « serveur anglais ».

**Ouvert.** Rien.

---

## 2. LE SERVEUR

### 2.1 Il tourne déjà sous Linux

**Établi.** ARTEMiS embarque son `Dockerfile`, son `docker-compose.yml` et son
`entrypoint.sh`. Sur 32 283 lignes de Python auditées, **aucune dépendance
Windows dure** hors d'un seul module.

### 2.2 Le seul module Windows ne bloque pas

`titles/fgo/event_damage_bridge.py` fait `ctypes.WinDLL` et
`mmap(tagname=...)`. Trois protections le rendent inoffensif : import paresseux,
opt-in par `server.event_damage_capture`, et `except (OSError, ValueError,
AttributeError)` — exactement ce que Linux lève.

**Conséquence.** Perte de la capture native des dégâts d'événement, désactivée
par défaut et annoncée « not enabled by dispatch yet » par l'auteur.

### 2.3 Trois correctifs nécessaires

| Quoi | Pourquoi |
|---|---|
| `python:3.10`, pas 3.9 ni 3.13 | le paquet embarque 3.10 ; `sqlalchemy==1.4.46` |
| retirer `pylibmc` | ignoré sous Windows, **compilé** sous Linux, et `enable_memcached: false` |
| ajouter `msgpack==1.2.1` | requis par `titles/fgo/index.py:17`, **absent de `requirements.txt`** |

Le manque de `msgpack` s'est trouvé en diffant les 54 paquets du venv Windows
de l'amont contre l'image.

### 2.4 Deux bugs de portage dans ARTEMiS

**`store_id == 0` refusé** (`core/adb_handlers/base.py`). AMDaemon envoie 0 —
vérifié en décodant le paquet ADB, les 4 octets entre `game_id` et le keychip
sont nuls. Le contrôle vise les installations en salle, où `store_id` identifie
une boutique. Symptôme : `Location Server : WAIT` et `Failed to send aime play
log.` chaque minute.

**`path.basename` sur un chemin Windows** (`titles/fgo/index.py:805`).
L'original fait `replace("/", "\\")` puis `basename` : correct sous Windows,
faux sous Linux où `posixpath` ignore l'antislash et renvoie le chemin entier.
Symptôme : `Built FGO card inventory: 0 selected card(s)` **quelle que soit la
notation du deck.json**.

### 2.5 ⚠️ Cinq montages, pas un

Le couplage serveur → client est profond et invisible à l'audit statique.

| Montage | Ce qui casse sans lui |
|---|---|
| `/app` | l'arbre ARTEMiS |
| `/Server` | `data/fgo-master/talk_unlocks.json` → `start` lève FileNotFoundError |
| `/App` | `deck.json`, `rom/aet` |
| `/DEVICE` | `print/FGO11_AllServants` et son manifeste |
| **`/state`** | **la progression est perdue à chaque recréation du conteneur** |

`/state` est le plus coûteux : `titles/fgo/config.py` persiste les profils dans
`../state/fgo-players.json`, relatif à `/app`, donc hors de tout montage.

### 2.6 ⚠️ Où lire les pannes

**`logs/fgo_capture/failures.jsonl`.** ARTEMiS y consigne chaque échec de
gestionnaire — commande, type et message d'exception — avant de la relancer
(`index.py:20685-20701`). **Les journaux ordinaires n'en montrent rien.** C'est
ce fichier qui a révélé que `start` levait une `FileNotFoundError`, ce que le
jeu présentait au joueur comme une « erreur de connexion réseau ».

### 2.7 `core.yaml` : `hostname` est l'adresse annoncée AU CLIENT

Héritée de la machine d'origine. Le jeu s'authentifie puis part vers cette
adresse. Symptôme : `NET PARAM : WAIT`.

**Ouvert.** MariaDB 10.11 démarre sans migration sur un `data/` créé sous
Windows — vérifié, mais sur un seul jeu de données.

---

## 3. LE CLIENT

### 3.1 ⚠️ Ne pas lancer `FGOAC scooby.exe`

Toute sa chaîne est en PowerShell, absent de Wine. PowerShell 7 portable
installé dans le préfixe **ne s'exécute pas** non plus — témoin :
`pwsh -Command "exit 42"` rend 0 et n'écrit aucun fichier.

On appelle `inject.exe` directement, après avoir reproduit ce que le launcher
préparait.

### 3.2 Ce que le launcher prépare

1. **`DEVICE/runtime/segatools.runtime.ini`** : copie de `App/segatools.ini`
   plus ~40 clés, **réécrit en UTF-16LE avec BOM** — `GetPrivateProfileStringW`
   l'exige. Sans lui : `native-surface patch failed`, `Win32=203`.
2. `DEVICE/runtime/amdaemon_main.json`.
3. Une vingtaine de variables `FGO_*` et `SEGATOOLS_CONFIG_PATH`.
4. **Tuer les restes** `ago`/`amdaemon`/`inject` : pré-démarrer AMDaemon casse
   la poignée de main d'état du processus.

### 3.3 `SetWindowFeedbackSetting` tue le processus

`ago.exe` importe **statiquement** cette API tactile (ordinal 0311) que Wine
n'implémente pas, et Wine avorte sur ses stubs (`EXCEPTION_WINE_STUB`,
0x80000100). Désactiver `[touch] enable` n'y change rien.

**Contourné** par `client/fgostub` : 9 Ko, réécrit cette seule entrée de la
table d'imports vers un stub renvoyant `TRUE`.

### 3.4 ⚠️ `io4.mode` = keyboard, pas xinput

Le défaut du script d'origine est `xinput`. Sans manette **rien ne répond**, et
ça ne se voit pas : le tutoriel enchaîne ses attaques scriptées tout seul.

Commandes : WASD, **clic droit** attaque, Espace Noble Phantasm, clic gauche
dans les menus, Entrée maintenu pour la carte Aime.

### 3.5 L'anglais, sans le hook

`fgozh.dll` refuse de s'installer sous Wine. Établi par élimination :
`FGO_ZH_ENABLED=1` n'y change rien, il échoue **seul** sans `fgohook`, aucune
exception n'apparaît — la DLL est mappée, relogée, son callback TLS enregistré,
puis elle refuse délibérément. Ses étapes sont `REDIRECT_INDEX` → `EXE_TEXT` →
`FLAVOR_NEWLINES` → `FONT_TRACE` → `TEXT_MEASURE_CACHE`, et son journal
s'arrête après la **première** : l'échec est dans `EXE_TEXT`, la seule étape qui
patche l'exécutable en mémoire.

**Contourné.** `App/zh/rom/` est un miroir anglais de `App/rom/` — 1683
fichiers, tous avec homologue. On copie par-dessus. Réversible.

**Reste japonais** : les chaînes compilées dans `ago.exe`
(`executable-text.json`, 441 Ko) et les artworks non refaits par scooby.

---

## 4. LE MATÉRIEL — la question la plus mal comprise

### 4.1 ⚠️ La raison réelle du « NVIDIA seulement »

`ago.exe` demande **deux extensions NVIDIA propriétaires**, trouvées en
instrumentant un proxy `opengl32` qui journalise les résolutions échouées :

| Extension | Équivalent ARB | radeonsi |
|---|---|---|
| `GL_NV_bindless_texture` | **oui** (`glGetTextureHandleARB`) | traduisible |
| `GL_NV_shader_buffer_load` | **AUCUN** | absent, sans substitut |

La seconde fournit des **adresses GPU brutes** (`GL_BUFFER_GPU_ADDRESS_NV`),
concept que Mesa n'expose pas et que l'ARB ne remplace pas.

### 4.2 Ce que ça implique pour le shim de fluphus

Sa table `_amdshim_map_handle_pairs` **n'est pas une lubie** : c'est
l'émulation de ces adresses par indirection, seule voie possible hors NVIDIA,
et qui impose forcément de réécrire les shaders.

⚠️ **Mais sur un GPU qui a `bindless` nativement, le retirer est obligatoire** —
sa réécriture produit `0(763) : error C1068: array index out of bounds`.

⚠️ **Et `App/shader-cache-r2/` est le cache DU SHIM**, pas du jeu. Preuve :
NVIDIA sans shim → 0 fichier et ça marche ; AMD avec shim → 109. **Le purger
après tout changement de pile graphique.**

### 4.3 État par pilote

| Pilote | État | Comment |
|---|---|---|
| NVIDIA propriétaire | **fonctionne** | sans shim, cache vide |
| NVIDIA sur machine hybride | **fonctionne** | `__NV_PRIME_RENDER_OFFLOAD=1` + `__GLX_VENDOR_LIBRARY_NAME=nvidia` |
| Mesa radeonsi (AMD) | **non** | ARB présent, NV absent ; le shim ne sauve pas |
| Mesa iris (Intel) | **non** | ni ARB ni NV |

⚠️ **Ce tableau décrit NOTRE paquet, pas le jeu.** Un patch AMD tiers existe et
fonctionne sur RX 9070XT — voir §6.2. La ligne « Mesa radeonsi » dit donc « pas
encore chez nous », pas « impossible ».

---

## 5. LE STREAMING

**Moonshine** (ishtar) crée son **propre compositeur imbriqué** — donc le script
de lancement ne doit fixer **ni `WAYLAND_DISPLAY` ni `DISPLAY`**.

⚠️ `launch_timeout_secs` **ne mesure pas le démarrage du jeu** : il attend que
l'**unité systemd** passe active (`application.rs:169`). Et le webserver a un
plafond **codé en dur à 60 s** (`webserver/mod.rs:837`). Une valeur supérieure
garantit l'échec. **30 fonctionne.**

**Sunshine** (enlil) capture un écran existant — logique inverse, le script de
Moonshine ne s'y transpose pas. Il reste installé mais n'est plus autodémarré :
enlil est passée à Moonshine le 2026-09-16, voir §5.1.

### 5.1 Un GPU par session — `nix/moonshine-deux-gpu.nix`

Moonshine ouvre un compositeur **par session**. Sur une machine à deux cartes,
chaque GPU peut donc devenir une **entrée distincte dans la liste Moonlight** :
plus besoin de SSH et d'un script pour basculer entre « jouer » et « chercher ».

⚠️ **`compositor.gpu` est GLOBAL, pas par application.** On ne peut pas donner
une carte à chaque session ; le GPU du **jeu** se choisit dans le `command` de
chaque entrée (`__NV_PRIME_RENDER_OFFLOAD` + `__GLX_VENDOR_LIBRARY_NAME` d'un
côté, rien de l'autre). Le compositeur, lui, est **unique et partagé**.

D'où le choix qui compte : **le compositeur va sur l'iGPU AMD**, pas sur la
NVIDIA. Raison mesurée sur ishtar (2026-09-03) : un DMA-BUF ne traverse pas
d'une carte à l'autre sans peine — « No suitable memory type for DMA-BUF
import », flux vide. En plaçant le compositeur sur l'iGPU, la session AMD est en
zéro-copie et la session NVIDIA emprunte le PRIME offload, **le sens normal sur
un portable hybride**. L'inverse mettrait la session AMD en reverse-PRIME, le
sens fragile.

Les deux cartes savent encoder — relevé `vulkaninfo` du 2026-09-16, témoin
`VK_KHR_swapchain` présent 9 fois pour prouver que le relevé a tourné :

| GPU | encodage Vulkan |
|---|---|
| AMD Radeon 780M (RADV PHOENIX) | av1, h264, h265, intra_refresh, quantization_map, queue, + `VK_VALVE_video_encode_rgb_conversion` |
| NVIDIA RTX 4060 Laptop | av1, h264, h265, intra_refresh, quantization_map, queue |

⚠️ **Les deux sessions sont EXCLUSIVES aujourd'hui**, et c'est une vraie limite :
elles partagent `App/`, où la bascule se joue sur la **présence** du shim
`opengl32.dll`, et le cache `App/shader-cache-r2`. Les lanceurs **refusent** de
démarrer si l'autre variante tourne, plutôt que de corrompre en silence. Pour le
test multijoueur à deux clients sur une seule machine, il faudra un second arbre
`App` — ou, piste non mesurée, garder le shim en place et le neutraliser côté
NVIDIA par `WINEDLLOVERRIDES=opengl32=b` (builtin).

⚠️ **Le module de nixpkgs n'est pas celui de l'amont.** Pas de `uid`, pas
d'`openFirewall`, pas de `logFilter` ; à la place `firewallInterfaces` (qui
n'ouvre **rien** si la liste est vide), `environment` et `extraPackages`. Et
`environment` **n'est pas hérité par les applications lancées** — c'est ce qui
permet d'épingler le GPU du service sans aveugler la session NVIDIA.

**Établi.** Le tactile passe : `TOUCH: synthetic event physical=1`.

---

## 6. LE MULTIJOUEUR — tranché le 2026-09-16

**La contradiction est levée, et les deux lectures étaient justes.**

Ce que dit le code d'ARTEMiS reste exact : **ni lobby ni état partagé entre
clients**, le code co-op ne gère que la comptabilité des récompenses, et son
test « online » traite les adversaires comme des PNJ. Mais ARTEMiS est le
**单机版** — la version *solo*. Il existe une autre distribution, le **联机版**,
la version *en réseau*, et c'est elle qui a le multijoueur.

Trois sources indépendantes le disent :

1. **Un commentaire sous la vidéo YouTube `UZkV_xaG_iE`** :
   « Guys, the information is confirmed. On Bilibili, besides the single-player
   version shown in the video, there is also an online multiplayer version that
   supports matchmaking. »

2. **Les titres Bilibili opposent explicitement les deux mots.** Le même auteur
   (凡一尘) a publié, à deux jours d'intervalle, `【FGOArcade】AMD A卡补丁`
   **`单机版`** `PVP模式4K分辨率测试` (`BV1PoYv6oEhx`) *et* le même titre avec
   **`联机版`** (`BV1rAYi6XEmN`). Même patch, deux versions du jeu.

3. **La vidéo tutoriel `BV1oaYU6nEUJ`** (猜不到的未来) nomme l'infrastructure :
   « 启动器制作及服务器维护者：SinnohDawn » — créateur du launcher **et
   mainteneur du serveur**.

### 6.1 ⚠️ Ce n'est pas un déploiement local

Point de cadrage décisif : le multi chinois est un **serveur hébergé** par
SinnohDawn, auquel un launcher dédié se connecte. Le paquet de Cloud23333 qu'on
a déployé installe un serveur **local** — d'où l'absence de lobby, qui n'est
donc ni un oubli ni une fonction désactivée.

Conséquence : il n'y a **rien à « activer »** dans ARTEMiS. Deux chemins
restent, et ils ne s'excluent pas :

- **(a)** observer le protocole du 联机版 pour le réimplémenter — le client
  chinois parle à un serveur dont on peut capturer les échanges ;
- **(b)** écrire la couche de zéro au-dessus d'ARTEMiS.

Coordonnées relevées, à exploiter pour (a) :

| quoi | où |
|---|---|
| SinnohDawn (launcher + serveur) | `space.bilibili.com/18526617` — QQ群 **1103409252** |
| co-op en ligne, événement CCC | `BV1Rpe56pEqc` |
| co-op en ligne, « 柱子战 » | `BV1pKe56NEig` |

### 6.2 Le patch AMD existe, et il est signé

Trouvaille collatérale qui vise §4. Description de `BV1rAYi6XEmN` :

> 操作系统：win10 GPU：9070XT 驱动版本26.5.1 联机游戏版本，分辨率4K，无插帧嗯跑
> 本补丁由@Vancion 制作

Patch par **@Vancion**, testé sur une **RX 9070XT**, pilote 26.5.1, en 4K.
Autrement dit le « NVIDIA seulement » de §4 est une limite **du paquet**, pas du
jeu : quelqu'un a déjà franchi l'obstacle de §4.1. À récupérer — c'est
probablement le chemin le plus court vers le client AMD, plus court que de
réparer nous-mêmes l'émulation du shim.

Réserve honnête : la 9070XT est une carte **discrète** RDNA4. Rien ne dit encore
que le patch couvre un **iGPU** comme le 780M d'enlil.

### 6.3 ⚠️ Piège : l'API Bilibili ment par le silence

`api.bilibili.com/x/web-interface/wbi/search/type` répond correctement quelques
requêtes, puis renvoie **`code: 0`, `message: OK`** avec un `data` qui ne
contient plus que `v_voucher` — **aucun résultat**. C'est un blocage anti-bot
déguisé en réponse vide, et sans précaution on le lit comme « ce contenu
n'existe pas ».

Parade : **relancer une requête témoin** dont on sait qu'elle a déjà renvoyé 20
résultats. Si le témoin passe à 0, c'est le blocage, pas le corpus.

L'endpoint `x/web-interface/view` (détail d'une vidéo), lui, est bloqué
d'emblée : il rend une page HTML « 出错啦 » et non du JSON. Passer par la page
web de la vidéo.

---

## 7. LES SOURCES ET LEURS PIÈGES

**Google Drive** sert un interstitiel « Virus scan warning » de 2442 octets,
identique pour tous les volumes, **sans un mot sur le quota**. Le refus
(« Quota exceeded », 2009 octets) n'arrive qu'**après** avoir renvoyé le
formulaire avec `confirm=t`. Un script qui ne lit pas le corps croit avoir
réussi.

⚠️ **Le zip de dossier fabriqué par l'interface web contourne le quota**, qui
est par fichier.

⚠️ **Drive renomme les volumes** en `part1-003.rar`. `7zz` y voit le motif de
volume et cherche `part1-004.rar`. **Renommer avant toute chose.**

**Outils d'archive**, mesuré sur les vraies archives :

| | lister | extraire |
|---|---|---|
| `unar` | oui | **NON** — s'arrête au 1er volume et **sort en code 0** |
| `p7zip` | non | non |
| `_7zz` | **oui** | **NON** (`Open Errors: 1`) |
| `unrar` | oui | **oui**, et `-kb` sauve un lot incomplet |

⚠️ Le listing de `7zz` vient de l'index **QuickOpen**, qui énumère *tous* les
fichiers y compris ceux des volumes absents. **Lister n'est pas avoir.**

**Mot de passe des archives** : `bilibili Cloud23333`, avec l'espace. Publié par
l'auteur sur Bilibili.

---

## 8. MÉTHODE — ce qui a fait gagner du temps

**Le témoin.** Tester avec une valeur volontairement invalide pour calibrer ce
qu'un échec ressemble. Sans lui, un « 0 » ne prouve rien : `glxinfo` lancé par
SSH sans affichage ne mesure que son propre échec ; `strings` absent renvoie
zéro occurrence ; `unar` sort en code 0 après une extraction tronquée.

**Compter, ne pas supposer.** 42 fichiers extraits sur 1050, 215 Mo sur 675 —
c'est le comptage qui a révélé la troncature, pas le message de l'outil.

**Lire le fichier de diagnostic avant le journal.** `failures.jsonl` a donné en
une ligne ce que trois heures de journaux n'avaient pas montré.

**Bisecter par retrait.** Le shader fautif s'est identifié en lançant **sans
`fgohook`** : zéro réécriture, mêmes huit erreurs, donc le hook était hors de
cause.
