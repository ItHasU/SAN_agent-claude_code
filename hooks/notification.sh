#!/usr/bin/env bash
# Hook Notification : permission / attente d'input -> waiting + nudge high.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
ntype="$(jget '.notification_type' notification_type)"
case "$ntype" in
  ''|permission_prompt|idle_prompt|elicitation_dialog) ;;
  *) exit 0 ;;   # auth_success, etc. : sans intérêt
esac
msg="$(sanitize "$(jget '.message' message)" 80)"
[ -n "$msg" ] || msg="Claude Code attend votre réponse"
reset_throttle
# shellcheck disable=SC2329  # appelée via bg
notif_flow() {
  san_call state waiting "$msg" --ttl "$TTL_WAITING"
  san_call nudge "$msg" --high
}
bg notif_flow
exit 0
