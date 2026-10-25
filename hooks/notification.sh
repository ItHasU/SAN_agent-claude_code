#!/usr/bin/env bash
# Hook Notification : demande de permission / question -> nudge question (high) SEUL.
# Pas de `state` : le serveur déduit l'état « question » du nudge ; un state avant/après ferait
# flasher une icône intermédiaire ou écraserait « question ». idle_prompt est ignoré (rappel
# d'inactivité après Stop : doublon sonore, et il écraserait la coche « prêt »).
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
ntype="$(jget '.notification_type' notification_type)"
case "$ntype" in
  ''|permission_prompt|elicitation_dialog) ;;
  *) exit 0 ;;   # idle_prompt, auth_success, etc. : sans intérêt
esac
msg="$(sanitize "$(jget '.message' message)" 80)"
[ -n "$msg" ] || msg="Claude Code attend votre réponse"
reset_throttle
# shellcheck disable=SC2329  # appelée via bg
notif_flow() {
  san_call nudge "$msg" --type question --high
}
bg notif_flow
exit 0
