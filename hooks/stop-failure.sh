#!/usr/bin/env bash
# Hook StopFailure : tour terminé sur erreur d'API -> error + nudge error (high).
# Champs reçus : error (rate_limit, overloaded…), error_details, last_assistant_message.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
etype="$(sanitize "$(jget '.error' error)" 40)"
if [ -n "$etype" ]; then msg="Erreur : $etype"; else msg="Erreur"; fi
reset_throttle
sa_reset
# shellcheck disable=SC2329  # appelée via bg
failure_flow() {
  san_call state error "$msg" --ttl "$TTL_ERROR"
  san_call nudge "$msg" --type error --high
}
bg failure_flow
exit 0
