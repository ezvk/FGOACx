# Entrée « FGO Arcade » pour Moonshine (hgaiser/moonshine), à insérer dans la
# liste `application` de services.moonshine.settings.
#
# ⚠️ launch_timeout_secs NE MESURE PAS LE DÉMARRAGE DU JEU. Il est passé à
# start_transient_service comme délai d'attente que l'UNITÉ SYSTEMD passe en
# état actif (application.rs:169), ce qui arrive dès que le processus démarre.
# Les ~90 s que met la borne à dérouler ses contrôles matériels se déroulent
# après, hors de ce compteur.
#
# ⚠️ ET LE WEBSERVER A UN PLAFOND DE 60 s, EN DUR (webserver/mod.rs:837,
# « Timed out waiting for application launch result »). Une valeur supérieure à
# 60 garantit donc l'échec : testé avec 120, le jeu démarrait normalement mais
# la session était démontée pendant qu'il montait. 30 fonctionne.
#
# ⚠️ LE SCRIPT NE DOIT FIXER NI WAYLAND_DISPLAY NI DISPLAY : Moonshine crée son
# propre compositeur et les pose lui-même. Les écraser renverrait la fenêtre sur
# l'écran physique au lieu du flux.
{ pkgs, lancerFgo, scopesAvant, scopesApres }:

{
  title = "FGO Arcade";
  pre_command = [ [ "${scopesAvant}" ] ];
  post_command = [ [ "${scopesApres}" ] ];

  # Sous un bus D-Bus dédié : sans lui, les dialogues s'ouvrent sur l'écran
  # physique au lieu de la session distante.
  command = [ "${pkgs.dbus}/bin/dbus-run-session" "--" "${lancerFgo}" ];

  launch_timeout_secs = 30;

  # ⚠️ PAS de PROTON_ENABLE_WAYLAND. Le jeu est en OpenGL et passe par
  # winex11.drv ; c'est la chaîne mesurée fonctionnelle. Ne pas la changer à
  # l'aveugle — l'unité Moonshine doit fournir Xwayland dans son PATH.
}
