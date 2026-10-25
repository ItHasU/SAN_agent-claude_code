#!/usr/bin/env bash
# Fonctions communes des hooks SAN. À sourcer ; ne produit JAMAIS de sortie
# (stdout de SessionStart/UserPromptSubmit est injecté dans le contexte de Claude)
# et ne fait jamais échouer le hook (code de sortie 0).
# shellcheck disable=SC2034

export LC_ALL=C.UTF-8 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAN_BIN="${SAN_BIN:-$HOOK_DIR/../bin/san}"
[ -x "$SAN_BIN" ] || SAN_BIN="$(command -v san 2>/dev/null || true)"

# TTL (secondes) des états publiés : l'état devient "stale" si la session meurt.
TTL_WORKING="${SAN_TTL_WORKING:-900}"
TTL_IDLE="${SAN_TTL_IDLE:-1800}"
TTL_DONE="${SAN_TTL_DONE:-3600}"
TTL_ENDED="${SAN_TTL_ENDED:-300}"
TOOL_THROTTLE_S="${SAN_TOOL_THROTTLE_S:-10}"
TTL_ERROR="${SAN_TTL_ERROR:-1800}"
DETAIL_MAX="${SAN_DETAIL_MAX:-60}"
# Fenêtre (s) pendant laquelle un état « working » récent supprime un nouveau nudge start.
NUDGE_START_WINDOW_S="${SAN_NUDGE_START_WINDOW_S:-300}"

# Variables SAN_* facultatives : l'environnement prime, sinon fichier d'env de bin/san
# (lu sans être exécuté). SAN_NUDGE_START : 0 (défaut) = pas de nudge start, 1 = activé.
if [ -z "${SAN_NUDGE_START:-}" ]; then
  _envf="${SAN_ENV_FILE:-}"
  if [ -z "$_envf" ]; then
    # Même ordre que bin/san : <.claude>/san.env (agent par projet), sinon fichier global.
    _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _here=""
    if [ -n "$_here" ] && [ -f "$_here/../../san.env" ]; then _envf="$_here/../../san.env"
    else _envf="$HOME/.config/san/agent.env"; fi
  fi
  if [ -f "$_envf" ] && [ -r "$_envf" ]; then
    SAN_NUDGE_START="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}SAN_NUDGE_START=//p' "$_envf" 2>/dev/null \
      | tail -n1 | tr -d "\"' \r")"
  fi
fi
SAN_NUDGE_START="${SAN_NUDGE_START:-0}"

HOOK_INPUT=""
if [ ! -t 0 ]; then HOOK_INPUT="$(cat 2>/dev/null || true)"; fi

# jget <expression jq> <clé de repli> : valeur textuelle d'un champ du JSON d'entrée.
jget() {
  local v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(printf '%s' "$HOOK_INPUT" | jq -r "$1 // empty" 2>/dev/null || true)"
  else
    # Repli sans jq : première occurrence de "clé":"valeur" (chaînes simples).
    v="$(printf '%s' "$HOOK_INPUT" | tr '\n' ' ' \
      | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\(\\([^\"\\\\]\\|\\\\.\\)*\\)\".*/\\1/p" | head -n1)"
    v="${v//\\\"/\"}"; v="${v//\\n/ }"; v="${v//\\\\/\\}"
  fi
  printf '%s' "$v"
}

# sanitize <texte> [max] : une ligne, secrets masqués, tronqué avec « … ».
sanitize() {
  local s="$1" max="${2:-$DETAIL_MAX}"
  s="$(printf '%s' "$s" | tr '\n\r\t' '   ' | tr -d '\000-\037' \
    | sed -E 's/(Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+\/=-]+/\1 ***/g;
              s/(password|passwd|secret|token|api[_-]?key|authorization)([[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1\2***/Ig;
              s/\b(sk|pk|agt|dev|web|ghp|gho|ghs|xox[a-z]|AKIA)[A-Za-z0-9_-]{8,}/***/g;
              s/[A-Za-z0-9_+\/=-]{24,}/***/g;
              s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [ "${#s}" -gt "$max" ]; then s="${s:0:$((max - 1))}…"; fi
  printf '%s' "$s"
}

# Dossier d'état par session (horodatage de throttling).
STATE_DIR="${SAN_STATE_DIR:-${TMPDIR:-/tmp}/san-claude-$(id -u 2>/dev/null || echo 0)}"
SESSION_ID="$(jget '.session_id' session_id)"
SESSION_KEY="$(printf '%s' "${SESSION_ID:-nosession}" | tr -c 'A-Za-z0-9_-' '_' | head -c 64)"
THROTTLE_FILE="$STATE_DIR/$SESSION_KEY.last"
mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null || true

# san_call <args...> : appelle bin/san, silencieux, toujours code 0.
san_call() {
  [ -n "$SAN_BIN" ] || return 0
  "$SAN_BIN" "$@" >/dev/null 2>&1 </dev/null || true
  return 0
}

# bg <fonction> [args] : exécute en arrière-plan (ne ralentit pas Claude Code),
# ou en synchrone si SAN_HOOK_SYNC=1 (tests).
bg() {
  if [ "${SAN_HOOK_SYNC:-0}" = 1 ]; then
    "$@"
  else
    ( "$@" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
  fi
  return 0
}

now() { date +%s; }
reset_throttle() { echo 0 >"$THROTTLE_FILE" 2>/dev/null || true; }
mark_throttle() { now >"$THROTTLE_FILE" 2>/dev/null || true; }

# last_mark : horodatage du dernier état working publié (0 si absent/réinitialisé).
last_mark() {
  local v=0
  [ -f "$THROTTLE_FILE" ] && v="$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# --- Sous-agents actifs (SubagentStart / SubagentStop) ------------------------
# Registre par session : une ligne « <agent_id> <epoch de démarrage> » dans
# $STATE_DIR/<session>.subagents. Écriture atomique (fichier temporaire + mv) sous verrou
# mkdir. Un SubagentStop pour un id inconnu (agents internes de Claude Code : suggestions
# de prompt, /btw…) est ignoré, donc le décompte ne descend jamais sous 0. Une entrée plus
# vieille que SUBAGENT_MAX_AGE_S est considérée « fantôme » (SubagentStop perdu) et ignorée.
SUBAGENT_MAX_AGE_S="${SAN_SUBAGENT_MAX_AGE_S:-7200}"
SUBAGENT_FILE="$STATE_DIR/$SESSION_KEY.subagents"
SUBAGENT_LOCK="$STATE_DIR/$SESSION_KEY.subagents.lock"

sa_lock() {
  local i=0
  while ! mkdir "$SUBAGENT_LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then rmdir "$SUBAGENT_LOCK" 2>/dev/null || true; break; fi  # verrou orphelin
    sleep 0.1
  done
}
sa_unlock() { rmdir "$SUBAGENT_LOCK" 2>/dev/null || true; }

# sa_rewrite <op> <id> : réécrit le registre sans les entrées expirées.
#   add : (ré)enregistre <id> ; del : retire <id> (ou la plus ancienne si <id> vide).
sa_rewrite() {
  local op="$1" id="$2" t aid ts tmp="$SUBAGENT_FILE.$$.tmp" removed=0
  t="$(now)"
  : >"$tmp" 2>/dev/null || return 0
  if [ -f "$SUBAGENT_FILE" ]; then
    while read -r aid ts _; do
      case "$ts" in ''|*[!0-9]*) continue ;; esac
      [ -n "$aid" ] || continue
      [ $((t - ts)) -lt "$SUBAGENT_MAX_AGE_S" ] || continue
      if [ "$op" = add ] && [ "$aid" = "$id" ]; then continue; fi
      if [ "$op" = del ] && [ "$removed" = 0 ] && { [ -z "$id" ] || [ "$aid" = "$id" ]; }; then
        removed=1; continue
      fi
      printf '%s %s\n' "$aid" "$ts" >>"$tmp"
    done <"$SUBAGENT_FILE"
  fi
  [ "$op" = add ] && printf '%s %s\n' "$id" "$t" >>"$tmp"
  mv -f "$tmp" "$SUBAGENT_FILE" 2>/dev/null || rm -f "$tmp"
}

sa_start() { # id (vide -> identifiant synthétique)
  local id="${1:-anon-$$-$RANDOM}"
  id="$(printf '%s' "$id" | tr -c 'A-Za-z0-9_.:-' '_' | head -c 64)"
  sa_lock; sa_rewrite add "$id"; sa_unlock
}
sa_stop() { # id
  local id="$1"
  [ -z "$id" ] || id="$(printf '%s' "$id" | tr -c 'A-Za-z0-9_.:-' '_' | head -c 64)"
  sa_lock; sa_rewrite del "$id"; sa_unlock
}
sa_reset() { rm -f "$SUBAGENT_FILE" 2>/dev/null || true; }

# sa_count : nombre de sous-agents actifs non expirés (lecture seule, sans verrou).
sa_count() {
  local n=0 t aid ts
  t="$(now)"
  if [ -f "$SUBAGENT_FILE" ]; then
    while read -r aid ts _; do
      case "$ts" in ''|*[!0-9]*) continue ;; esac
      [ -n "$aid" ] && [ $((t - ts)) -lt "$SUBAGENT_MAX_AGE_S" ] && n=$((n + 1))
    done <"$SUBAGENT_FILE"
  fi
  printf '%s' "$n"
}

# sa_bg_count : sous-agents en cours d'après `background_tasks` de l'entrée de Stop
# (autorité quand la clé est présente, même vide). N'affiche RIEN si la clé est absente ou
# si jq manque / l'entrée est illisible : l'appelant se rabat alors sur le registre.
# La doc ne liste pas les valeurs de `status` (exemple : "running", entrées « en cours ») :
# on exclut les statuts terminaux connus plutôt que de n'accepter que « running ».
sa_bg_count() {
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$HOOK_INPUT" | jq -r '
    if (.background_tasks | type) == "array" then
      [.background_tasks[]
        | select(type == "object" and .type == "subagent"
            and (((.status // "running") | tostring | ascii_downcase) as $s
                 | ["completed","complete","done","finished","failed","error","errored","killed","cancelled","canceled","stopped","terminated","aborted"]
                 | index($s) | not))
      ] | length
    else empty end' 2>/dev/null || true
}
