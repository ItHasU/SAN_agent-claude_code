#!/usr/bin/env bash
# Hook UserPromptSubmit : prompt soumis -> working (début du prompt tronqué).
# Si SAN_NUDGE_START=1 : nudge « start » en plus, une seule fois par tour de travail
# (pas si un état working date de moins de NUDGE_START_WINDOW_S secondes).
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
prompt="$(jget '.prompt' prompt)"
detail="$(sanitize "$prompt")"
[ -n "$detail" ] || detail="Prompt reçu"
start=0
if [ "$SAN_NUDGE_START" = 1 ] && [ $(($(now) - $(last_mark))) -ge "$NUDGE_START_WINDOW_S" ]; then
  start=1
fi
mark_throttle
# shellcheck disable=SC2329  # appelée via bg
prompt_flow() {
  san_call state working "$detail" --ttl "$TTL_WORKING"
  [ "$start" = 1 ] && san_call nudge "Début du travail" --type start
  return 0
}
bg prompt_flow
exit 0
