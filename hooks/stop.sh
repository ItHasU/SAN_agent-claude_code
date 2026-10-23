#!/usr/bin/env bash
# Hook Stop : Claude a fini de répondre -> done + nudge « Tâche terminée ».
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
reset_throttle
# shellcheck disable=SC2329  # appelée via bg
stop_flow() {
  san_call state "done" "Tâche terminée" --ttl "$TTL_DONE"
  san_call nudge "Tâche terminée"
}
bg stop_flow
exit 0
