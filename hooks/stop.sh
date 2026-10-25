#!/usr/bin/env bash
# Hook Stop : Claude a fini de répondre -> done puis nudge done (même état « prêt » : pas de flash).
# Si des sous-agents sont encore actifs (background_tasks, sinon registre SubagentStart/Stop) : pas de done ni de nudge, on republie `working`.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
# background_tasks (entrée de Stop) fait autorité s'il est présent ; sinon repli sur le registre.
subs="$(sa_bg_count)"
case "$subs" in
  ''|*[!0-9]*) subs="$(sa_count)" ;;
  0) sa_reset ;;   # plus aucun sous-agent : purge d'éventuels fantômes
esac
if [ "$subs" -gt 0 ] 2>/dev/null; then
  mark_throttle
  if [ "$subs" = 1 ]; then detail="1 sous-agent en cours"; else detail="$subs sous-agents en cours"; fi
  # shellcheck disable=SC2329  # appelée via bg
  working_flow() { san_call state working "$detail" --ttl "$TTL_WORKING"; }
  bg working_flow
  exit 0
fi
reset_throttle
# shellcheck disable=SC2329  # appelée via bg
stop_flow() {
  san_call state "done" "Tâche terminée" --ttl "$TTL_DONE"
  san_call nudge "Tâche terminée" --type "done"
}
bg stop_flow
exit 0
