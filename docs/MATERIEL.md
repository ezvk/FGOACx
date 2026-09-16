# Matériel : quelles cartes graphiques peuvent faire tourner le client

## Le critère : `GL_ARB_bindless_texture`

FGO Arcade est un jeu **OpenGL** — `ago.exe` importe `OPENGL32.dll`, pas
Direct3D. Il utilise `GL_ARB_bindless_texture`, et c'est cette extension qui
décide de tout.

| Pilote | `ARB_bindless_texture` | Client jouable |
|---|---|---|
| NVIDIA propriétaire | oui, natif | **oui**, mesuré sur RTX 4060 Ti, pilote 610.57.04 |
| Mesa radeonsi (AMD) | oui, implémenté en amont | **probable**, non mesuré ici |
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
