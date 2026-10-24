#!/usr/bin/env bash
# Faux agent de démonstration : simule un agent SAN (états, progression, nudges, say, inbox).
#
#   tools/fake-agent.sh [--once] [--interval S] [--san CHEMIN]
#
# Configuration via SAN_URL / SAN_TOKEN (ou ~/.config/san/agent.env), comme bin/san.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAN="$here/../bin/san"
once=0 interval=5

while [ $# -gt 0 ]; do
  case "$1" in
    --once) once=1; shift ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --san) SAN="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "option inconnue : $1" >&2; exit 2 ;;
  esac
done
case "$interval" in ''|*[!0-9.]*) echo "--interval invalide" >&2; exit 2 ;; esac

export SAN_STRICT=0
ack=""
log() { printf '[fake-agent] %s\n' "$*"; }
san() { "$SAN" "$@" >/dev/null; }

check_inbox() {
  local out ids n
  if [ -n "$ack" ]; then out="$("$SAN" inbox --wait 0 --ack "$ack")"; else out="$("$SAN" inbox --wait 0)"; fi
  [ -n "$out" ] || { log "inbox : (vide ou injoignable)"; return; }
  if command -v jq >/dev/null 2>&1; then
    ids="$(printf '%s' "$out" | jq -r '.events[]?.id' 2>/dev/null)"
  else
    ids="$(printf '%s' "$out" | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
  fi
  n=0
  for i in $ids; do n=$((n + 1)); ack="$i"; done
  log "inbox : $n événement(s)"
}

scenario() {
  log "idle + nudge start"; san state idle "En attente de travail" --ttl 120
  san nudge "Session démarrée" --type start; sleep "$interval"
  log "working + progression"
  for p in 10 40 70; do
    san state working "Analyse du dépôt" --progress "$p" --ttl 120; sleep "$interval"
  done
  log "waiting + nudge high + say"
  san state waiting "Validation requise" --ttl 120
  san nudge "Validation requise" --type question --high
  san say "J'ai besoin de ta validation."
  sleep "$interval"
  check_inbox
  log "error"; san state error "Tests en échec" --ttl 120; san nudge "Tests en échec" --type error; sleep "$interval"
  san nudge "Mise à jour intermédiaire"   # type par défaut (notification)
  log "working puis done"
  san state working "Correction" --progress 90 --ttl 120; sleep "$interval"
  san state "done" "Tâche terminée" --ttl 300; san nudge "Tâche terminée" --type "done"
  san say "Tâche terminée."
  sleep "$interval"
}

trap 'log "arrêt"; san state idle "Faux agent arrêté" --ttl 60; exit 0' INT TERM
while :; do
  scenario
  [ "$once" = 1 ] && break
done
san state idle "Faux agent terminé" --ttl 60
