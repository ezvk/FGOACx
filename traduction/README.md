# Traduction des masters serveur

## Le problème

Le patch anglais de scooby couvre le **client** : 664 archives de ressources
(585 Mo — histoire, servants, liens, boutique, coopératif) et **2 224 des 2 774**
chaînes de l'exécutable, déjà traduites dans `App/zh/executable-text.json` au
format `原文` / `译文`.

Il ne couvre pas le **serveur**. Les masters qu'ARTEMiS sert lui-même restent en
japonais, et ça se voit en jeu : `"svt_name": "でかノブ"` dans les quêtes
coopératives, `【サーヴァント】アルトリア＠セイバー` dans les tirages.

Volume mesuré : **27 998 lignes** de valeurs japonaises dans les masters, soit
**13 393 chaînes uniques** et 529 000 caractères, réparties sur 65 champs.
Les plus fournis : `trc.disp_name` (3 704), `skill.name` (3 107),
`skill_detail.detail` (2 918), `coop_quest_svt.svt_name` (1 528).

## La chaîne

    construire-glossaire.py   Atlas Academy -> glossaire complet
    traduire-masters.py       masters -> dictionnaire.json

**Le glossaire d'abord, le modèle ensuite.** Un modèle laissé seul écrit
« Kabuki Toudi » pour 茨木童子 et « Concept Card » pour 概念礼装. Le glossaire
construit depuis l'API publique d'Atlas Academy apporte **2 474 noms officiels**
— 343 servants et 2 080 Craft Essences — appariés par identifiant entre les
exports `JP` et `NA`. Résultat : 茨木童子 → **Ibaraki-Douji**,
カレイドスコープ → **Kaleidoscope**.

Les chaînes qui *sont* exactement un nom du glossaire sont résolues **sans
appeler le modèle** : 629 d'entrée de jeu, avec le nom officiel garanti.

## Ce que le script protège

⚠️ **Il ne traduit pas les champs `ruby`** — ce sont les lectures phonétiques
(furigana), 6 357 lignes. Les traduire n'a aucun sens.

⚠️ **Il vérifie les marqueurs.** Si `{0}`, `%d`, `%s` ou `\n` disparaissent de
la traduction, le lot est refusé. Une chaîne qui perd son marqueur casse
l'affichage du jeu.

⚠️ **Les sauts de ligne sont normalisés.** Les masters les écrivent en **deux
caractères** (`\` puis `n`) ; le modèle rend volontiers un vrai saut de ligne.
Sans conversion au retour, un lot sur deux était rejeté — constaté au premier
essai : `marqueurs perdus : ['\n'] -> []`.

⚠️ **Un lot en échec est repris ligne par ligne.** Une seule chaîne mal rendue
ne doit pas en emporter dix-neuf correctes. Mesure : 40/60 sauvées sans cette
reprise, **58/60** avec. Ce qui résiste finit dans `douteuses.json`, jamais
perdu en silence.

⚠️ **Reprenable.** Le dictionnaire est réécrit après chaque lot, de façon
atomique. Une coupure ne perd qu'un lot.

⚠️ **Le glossaire n'est pas envoyé en entier.** 2 474 entrées coûteraient plus
de jetons que le texte à traduire ; seuls les termes présents dans le lot sont
joints à la requête.

## Ce qui n'est pas ici

Le dictionnaire produit et le glossaire complet **ne sont pas versionnés** :
ils contiennent le texte japonais du jeu. Le glossaire se reconstruit en une
commande depuis l'API publique d'Atlas Academy.

## Débit mesuré

106 chaînes par minute avec `Qwen3-VL-30B-A3B-Instruct-1M` en local, par lots
de 20. Les 12 764 chaînes restantes demandent environ deux heures.

## Ce qui reste à faire

**L'application aux masters n'est pas écrite.** Le dictionnaire est produit,
mais rien ne réécrit encore les fichiers `.bin`. C'est délibéré : produire la
traduction et la relire est une chose, la poser sur les données que le serveur
sert en est une autre, et ça mérite une sauvegarde et un contrôle.
