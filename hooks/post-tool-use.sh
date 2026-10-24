#!/usr/bin/env bash
# Hook PostToolUse : outil utilisé -> working (« Edit foo.ts »), au plus un appel toutes les ~10 s.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
last=0
[ -f "$THROTTLE_FILE" ] && last="$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
t="$(now)"
[ $((t - last)) -ge "$TOOL_THROTTLE_S" ] || exit 0

tool="$(jget '.tool_name' tool_name)"
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit|Read)
    f="$(jget '.tool_input.file_path // .tool_input.notebook_path' file_path)"
    f="${f##*/}"
    detail="$(sanitize "$tool $f")" ;;
  Bash)
    # seulement le premier mot de la commande : pas de fuite d'arguments
    c="$(jget '.tool_input.command' command)"
    c="${c#"${c%%[![:space:]]*}"}"; c="${c%%[[:space:]]*}"; c="${c##*/}"
    detail="$(sanitize "Bash $c")" ;;
  mcp__*) detail="$(sanitize "MCP ${tool#mcp__}")" ;;
  '') detail="Outil" ;;
  *) detail="$(sanitize "$tool")" ;;
esac
mark_throttle
bg san_call state working "$detail" --ttl "$TTL_WORKING"
exit 0
