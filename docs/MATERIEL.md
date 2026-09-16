# Matériel : quelles cartes graphiques peuvent faire tourner le client

## Le critère : `GL_ARB_bindless_texture`

FGO Arcade est un jeu **OpenGL** — `ago.exe` importe `OPENGL32.dll`, pas
Direct3D. Il utilise `GL_ARB_bindless_texture`, et c'est cette extension qui
décide de tout.

| Pilote | `ARB_bindless_texture` | Client jouable |
|---|---|---|
| NVIDIA propriétaire | oui, natif | **oui**, mesuré sur RTX 4060 Ti, pilote 610.57.04 |
| Mesa radeonsi (AMD) | **oui**, mesuré sur Radeon 780M | **non** — voir plus bas, l'extension ne suffit pas |
| Mesa Intel (iris) | **non** | **non** — voir plus bas |

Mesure sur Intel Arc B390, Mesa 26.3.0-devel, dans la session graphique
(⚠️ `glxinfo` lancé par SSH sans affichage ne prouve rien — vérifier que la
sortie fait bien un millier de lignes avant de l'interpréter) :

    OpenGL renderer : Mesa Intel(R) Arc(tm) B390 (PTL)
    OpenGL core     : 4.6 (Core Profile) Mesa 26.3.0-devel
    GL_ARB_bindless_texture : absent, aucune extension bindless

## ⚠️ Le shim de fluphus : à RETIRER sur NVIDIA et AMD

`compat/amd-shim/opengl32.dll`, livré par FGOAC-scooby, émule
`ARB_bindless_texture` pour les GPU qui ne l'ont pas. Sur une carte qui
l'implémente nativement, **il casse le jeu** : sa réécriture de shader produit

    0(763) : error C1068: array index out of bounds

sur la ligne `uvec4 pair_words = _amdshim_map_handle_pairs[i >> 1];`. Le
programme de shader reste nul et le jeu le déréférence plus loin —
`0xC0000005` à `ago.exe+0xC084F7`. Le crash est identique sur NVIDIA et sur
Intel ; **seul NVIDIA affiche l'erreur de compilation**, Mesa la tait.

Recette sur NVIDIA et AMD :

    rm -f App/opengl32.dll App/opengl32real.dll
    rm -rf App/shader-cache-r2 && mkdir App/shader-cache-r2
    # et ne pas poser WINEDLLOVERRIDES="opengl32=n,b"

⚠️ **`App/shader-cache-r2/` est écrit à l'exécution.** Les shaders réécrits y
restent en cache : changer de pile GL sans vider ce dossier rejoue les mêmes
erreurs. Toujours le purger après un changement de configuration graphique.

## ⚠️ Si le shim est nécessaire (Intel) : `opengl32real.dll`

Le shim est un **proxy DLL** dont les exports sont des *forwarders* vers
`opengl32real.<fonction>`. Il faut donc copier le vrai `opengl32` à côté sous
ce nom, sinon tous les forwarders pointent dans le vide :

    cp <proton>/files/lib/wine/x86_64-windows/opengl32.dll App/opengl32real.dll

plus `WINEDLLOVERRIDES="opengl32=n,b"`.

**Mais cela ne suffit pas** : c'est justement dans cette configuration que le
shader hors limites apparaît. Faire tourner le client sur Intel demande de
corriger la réécriture du shim, ce qui n'est pas fait ici.

## Ce qu'on observe sur `wglGetProcAddress`, sans conclusion hâtive

`ago.exe` résout ses fonctions GL par `wglGetProcAddress`, y compris des
fonctions du cœur OpenGL 1.1. Wine journalise alors, avec `WINEDEBUG=+wgl` :

    warn:opengl:wrap_wglGetProcAddress Function glClear unknown
    warn:opengl:wrap_wglGetProcAddress Function glEnable unknown
    (203 resolues sur 402 demandees)

C'est conforme à la spécification — `wglGetProcAddress` **peut** renvoyer NULL
pour les entrées de GL 1.1, qui sont exportées directement par `opengl32.dll`.
Le pilote NVIDIA sous Windows, lui, les renvoie quand même.

⚠️ **Ne pas en conclure que le shim est nécessaire pour ça.** La configuration
qui fonctionne ici — NVIDIA, **sans** shim — produit ces mêmes avertissements et
démarre sans problème. Le jeu récupère donc ces fonctions autrement. Le seul
rôle mesuré du shim est l'émulation de `ARB_bindless_texture`.

Ce qui reste établi : sur Intel, l'extension manque et le shim est
indispensable ; sa réécriture de shader est cassée sous Wine ; le client n'y
tourne pas.


---

# ⚠️ AMD : l'extension ne suffit pas (mesuré le 2026-09-16)

Testé sur **Radeon 780M** (radeonsi, phoenix, ACO, Mesa 26.2.1), GE-Proton11-5,
sur une machine qui porte aussi une RTX 4060 — donc mêmes Mesa, même Proton,
même installation que le témoin NVIDIA.

`GL_ARB_bindless_texture` **est bien présent** sur radeonsi. Et pourtant :

| configuration | shaders | résultat |
|---|---|---|
| **sans shim** | — | `0xC0000005` à l'adresse **0**, `ago.exe+0xBE1E06`, `rbp=0x8892` (`GL_ARRAY_BUFFER`) |
| **avec shim + `opengl32real`** | 109 compilés, **0 avec `_amdshim_`** | `0xC0000005` à `ago.exe+0xC084F7` |

Deux enseignements qui corrigent l'analyse initiale.

**Le shim ne sert pas qu'à `bindless`.** Sans lui, AMD tombe sur le même appel
de pointeur nul qu'Intel — `ago.exe+0xBE1E06`, à l'adresse exacte. La
résolution des fonctions GL par `wglGetProcAddress` échoue donc aussi sur Mesa.
**Seule la NVIDIA s'en passe.**

**Mais le shim intercepte les shaders même quand il n'a rien à émuler.** Preuve
par comparaison : ishtar (NVIDIA, sans shim, fonctionne) a **0 shader** dans
`App/shader-cache-r2/`, enlil en a **109**. Ce cache est celui du shim, pas du
jeu. Sur AMD il ne réécrit rien en `_amdshim_` — l'extension étant présente —
mais son interposition suffit à produire une ressource nulle à
`ago.exe+0xC084F7`.

Mesa ne signale **aucune erreur GL** (`MESA_DEBUG=1`), donc les appels
réussissent : le problème est dans le proxy, pas dans le pilote.

## La piste pour débloquer AMD

Le shim n'a aucune option pour désactiver son interception de shaders — ses
chaînes montrent qu'il est entièrement bâti autour de `bindless`, et son
`amdcfg` ne porte que deux réglages numériques du pilote.

Il faudrait donc **un proxy minimal** qui ne corrige QUE `wglGetProcAddress`,
en retombant sur `GetProcAddress` de l'`opengl32` réel pour les fonctions du
cœur GL 1.1, et qui forwarde tout le reste sans y toucher. C'est la même
technique que `client/fgostub`, et elle est à portée.

**En attendant : le client ne tourne que sur NVIDIA.**

---

# 🔍 LA RAISON RÉELLE DU « NVIDIA SEULEMENT » (2026-09-16)

Trouvée en instrumentant un proxy `opengl32` minimal qui journalise chaque
résolution de `wglGetProcAddress` qu'aucune voie ne satisfait. Deux noms
sortent, et ils expliquent tout.

## `ago.exe` utilise DEUX extensions NVIDIA propriétaires

| Extension demandée | Équivalent ARB | Mesa / radeonsi |
|---|---|---|
| `GL_NV_bindless_texture` (`glGetTextureHandleNV`) | **oui**, `glGetTextureHandleARB` | **traduisible** |
| `GL_NV_shader_buffer_load` (`glGetNamedBufferParameterui64vNV`) | **AUCUN** | **absent, sans substitut** |

Mesuré sur Radeon 780M : `glxinfo` n'expose **ni** `GL_NV_bindless_texture`
**ni** `GL_NV_shader_buffer_load`. Il expose `GL_ARB_bindless_texture`, ce qui
suffit pour la première mais pas pour la seconde.

`GL_NV_shader_buffer_load` fournit des **adresses GPU brutes**
(`GL_BUFFER_GPU_ADDRESS_NV`). C'est un concept que radeonsi n'expose pas, et
que l'ARB ne remplace pas : l'approche standard passe par des mécanismes
entièrement différents (SSBO).

## Ce que ça implique

**Le shim de fluphus n'est pas sur-conçu.** Sa table
`_amdshim_map_handle_pairs`, qu'on avait prise pour la cause du problème, est
l'**émulation de ces adresses par une indirection**. C'est la seule voie
possible sur un GPU non-NVIDIA, et elle impose forcément la réécriture des
shaders.

Un proxy minimal corrigeant `wglGetProcAddress` ne peut donc **pas** s'y
substituer. Il fait progresser — la traduction NV→ARB résout bien
`glGetTextureHandleNV` — puis bute sur ce qui n'a pas d'équivalent.

## Le proxy reste utile, et il est dans ce dépôt

`client/fgoglproxy` : 360 forwarders vers `opengl32real.dll`, et
`wglGetProcAddress` réimplémenté en trois passes — voie normale, puis
`GetProcAddress` sur le vrai `opengl32` (pour le cœur GL 1.1 que la spec
autorise à renvoyer NULL), puis traduction du suffixe `NV` en `ARB`.

⚠️ **Il journalise dans `logs/fgoglproxy.log` tout ce qu'aucune voie ne
résout.** C'est cet outil qui a permis le diagnostic, et il resservira.

## Où en est le support AMD

**Pas résolu.** Il faudrait faire fonctionner l'émulation du shim sous Wine —
sur AMD elle ne réécrit rien (l'ARB étant présent, elle se croit inutile) et le
jeu plante quand même à `ago.exe+0xC084F7`. C'est un chantier à part entière,
pas une correction de quelques lignes.

**Intel reste plus loin encore** : ni ARB ni NV, donc même la traduction
NV→ARB ne s'applique pas.
