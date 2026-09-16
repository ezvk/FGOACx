# NTVS — le réseau pair-à-pair des bornes

Tout ce qui suit est **mesuré**, sur deux bornes réelles (ishtar `192.168.1.60`,
enlil `192.168.1.190`) la nuit du 16 au 17 septembre 2026. Les hypothèses non
vérifiées sont marquées comme telles.

## Ce que le serveur ne fait pas

⚠️ **ARTEMiS ne joue aucun rôle dans l'appariement.** Sa réponse à
`multi_battle_start` contient neuf champs — `cmd_result`,
`special_matching_type`, `lot_res_list`, `server_mb_rating`, `server_mb_rank`,
`drop_printing_ticket_list`, `play_data_tlf_info_list`, `raid_battle_info_list`,
`tlf_bb_slot_result_list` — et **aucune coordonnée de salon** : pas d'adresse,
pas d'identifiant de salle, pas de port. Il dit seulement « oui, tu peux lancer
un multi » et donne les notes et les gains du joueur.

Ses réponses sont d'ailleurs des `Offline response` : des captures rejouées, pas
une réimplémentation du protocole. Cela explique les quatre `multi_battle_start`
aux charges identiques quel que soit le mode, mesurés le 16/09.

Le salon vit donc **entièrement dans `ago.exe`**.

## Le protocole LFSS

Trois ports, tous en dur dans le binaire (`mov edx,0x7532` / `mov r9d,0x7531`
en `0x14081ae9b` et `0x14081b48c`) :

| port | rôle |
|---|---|
| UDP 30001 | le serveur y écoute les diffusions de découverte |
| UDP 30002 | le satellite y émet, le serveur y répond |
| TCP 30000 | la session de salon |

⚠️ **Les six options `-ntvs_*` sont mortes.** `-ntvs_port`, `-ntvs_lan_ifno`,
`-ntvs_local_ms_ip`, `-ntvs_use_sw_num`, `-ntvs_pc` et `-ntvs_spe_rank` sont
analysées et rangées dans la struct globale `0x141c101e0`, puis **jamais
relues**. Contrôle : la plage voisine de la struct totalise 29 références, donc
la méthode voit bien les accès ; l'adresse de la struct n'est prise que deux
fois dans tout le binaire (constructeur statique, appel du parseur), donc aucune
copie ne peut cacher une lecture ; et aucune adresse de ces champs n'apparaît en
immédiat. Seul `-sm` (décalage `+0x34`) est relu, par le getter `0x14027ae60`.

⚠️ **`-sm` ne compare qu'à `"server"`.** La chaîne `"satellite"` n'existe pas
dans le binaire : tout ce qui n'est pas exactement `server` vaut satellite, sans
détection de faute de frappe. `[opt+0x34] = (argv == "server")`, en `0x14027d0cd`.

### Format des trames

    [4 octets BE : longueur][4 octets "LFSS"][opcode][00][06 01][4 octets LE : longueur][charge]

### Séquence complète, capturée le 17/09 à 23:53

    23:53:54  UDP  enlil:30002  -> 255:30001   LFSS 00              découverte
    23:53:54  UDP  ishtar:30001 -> enlil:30002 LFSS 01 ... 30 75    « moi, port 30000 »
    23:53:57  TCP  ishtar:30000 -> enlil       LFSS 02              invitation
    23:53:57  TCP  enlil -> ishtar:30000       LFSS 03 ... 2a       inscription, identifiant 42
    23:53:57  TCP  ishtar:30000 -> enlil       LFSS 04 ... 2a 0001  acceptation
    23:54:26  TCP  enlil -> ishtar:30000       LFSS 07              abandon, 29 s plus tard

`30 75` vaut `0x7530` = **30000** en petit-boutiste : la réponse UDP annonce le
port de session. Le `2a` de l'inscription vaut **42**, c'est-à-dire l'`addrSuffix`
d'enlil : la borne s'identifie par son numéro d'hôte sur le LAN virtualisé, et le
serveur le lui confirme.

Les 29 secondes entre acceptation et abandon correspondent à la fenêtre
d'appariement configurée côté serveur (`grail_war_match_wait_sec: 30`).

**Le salon fonctionne donc.** Il accepte le joueur et attend ; personne d'autre
n'arrive.

## Le pare-feu, seul obstacle réellement levé

Sur NixOS, TCP 30000 était **jeté en silence** — pas refusé, jeté. La borne
satellite recevait l'annonce du port et n'ouvrait jamais la connexion, sans
message d'erreur nulle part. Mesure depuis enlil, avec deux témoins pour
calibrer ce qu'une réponse normale ressemble :

| port | avant | après |
|---|---|---|
| 7777 *(témoin)* | OUVERT 0,00 s | OUVERT 0,00 s |
| **30000** | **FILTRÉ 4,00 s** | **OUVERT 0,00 s** |
| 11111 *(témoin)* | OUVERT 0,00 s | OUVERT 0,00 s |

Les règles sont désormais déclarées dans `cishtar`, limitées à `enp4s0`.

## Le plafond : la balise d'installation LAN

La borne principale est désignée location server — ARTEMiS lui envoie
`location_ip=192.168.1.60` — mais **n'émet rien dans ce rôle**. Sur toute la
durée des captures, la seule diffusion d'ishtar est la découverte `LFSS`, une
fois. Jamais de balise.

Dans `amdaemon.exe`, la machine à états du serveur d'installation LAN est
nommée et complète (table de dispatch en `0x140843300`, entrées de 24 octets
`{handler, état, nom}`) :

    1  0x14039fc90  ALWE_LANINSTALL_SERVER_PHASE_INITIALIZED
    2  0x14039f990  ALWE_LANINSTALL_SERVER_PHASE_START_BEACON
    3  0x14039f9b0  ALWE_LANINSTALL_SERVER_PHASE_START_BEACON_RESULT
    4  0x14039fa40  ALWE_LANINSTALL_SERVER_PHASE_STOP_BEACON
    5  0x14039fb20  ALWE_LANINSTALL_SERVER_PHASE_STOP_BEACON_RESULT
    6  0x14039fbb0  ALWE_LANINSTALL_SERVER_PHASE_IDLE

L'émission est conditionnée par le prédicat `0x14039fe50`, dont le verdict final
est `0x140384520` :

    eax = [objet]        ; un état
    cmp eax,0x6
    jl  -> refus         ; il faut état >= 6
    cmp eax,0x1c
    jle -> ACCEPTE       ; 6 <= état <= 28

⚠️ **HYPOTHÈSE NON VÉRIFIÉE.** Si `[objet]` est bien la phase
`ALWE_AUTH_PHASE_*` et si l'ordre des chaînes dans le binaire suit l'ordre de
l'énumération, alors le seuil 6 correspond à `IP_ADDRESS`, soit *avoir dépassé
`DNS_LAN`* (index 5). Or `DNS_LAN` est exactement le test qui échoue — le `C` du
`NG (A, C)` affiché par le menu test des deux bornes. Cela fermerait la chaîne :
DNS de salle absent → phase bloquée sous 6 → balise jamais armée → pas de
location server → le satellite attend et abandonne.

**Se vérifie en lisant cette valeur en mémoire pendant que la borne tourne.**

## Pistes écartées, par la mesure

**Le DNS.** Aucun paquet DNS ne quitte la machine : segatools court-circuite
toute résolution et passe directement l'adresse au jeu (`DNS route: node=
192.168.1.60 result=0` dans `logs/inject-*.log`). Une réécriture `naominet.jp`
posée sur un résolveur ne sera jamais consultée.

**Le rôle SUB.** `config.json` déclare `common.max_player: 1` : la borne n'a
qu'un siège. Le SUB est le second siège d'une borne double, pas une seconde
borne. En SUB, enlil n'ouvre **aucune** socket et attend une moitié de lui-même.
La bonne configuration pour deux bornes indépendantes est **les deux en
SATELLITE MAIN**, avec une seule en `-sm server`.

**Le drapeau MAIN/SUB du menu test.** Classe `test_mode::Exec_server_flag`,
vtable `0x1414e1050`, slot `+0x28` : il inverse un octet de l'enregistrement
persistant. Il écrit `lan_install.server` et `net_delivery.enable` dans
`amdaemon_aux.json`, que `ago.exe` régénère **à chaque lancement** — donc éditer
ce fichier à la main ne sert à rien.

**`location_router_directly`.** Passé de `deny` à `allow` via
`DEVICE/runtime/amdaemon_main.json` (dernier `-c` de la ligne de commande
d'amdaemon, fusion profonde, dernier gagnant — vérifié par témoin sur la section
`credit`). Aucun effet observable.

## Le fichier de configuration que le jeu lit vraiment

⚠️ **`DEVICE/runtime/segatools.stream.ini`, en UTF-16LE avec BOM** — désigné par
`SEGATOOLS_CONFIG_PATH` et régénéré à chaque session par `preparerSession`.
`App/segatools.ini` n'est **pas** lu. Plusieurs heures ont été perdues à éditer
le mauvais fichier.

## Levier sur les crédits

`DEVICE/runtime/amdaemon_main.json` écrase la configuration fusionnée
d'amdaemon, sans toucher au serveur ni au menu test :

    "credit": { "config": { "freeplay": false,
                            "coin_chute_multiplier": [1, 1],
                            "game_cost": [1, 1, 1, 1, 1, 1, -1, -1],
                            "bonus_addr": 0 },
                "enable": true,
                "max_credit": 99 }

`game_cost` porte huit entrées, le coût de chaque mode, dont deux désactivées.
