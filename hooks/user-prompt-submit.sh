#!/usr/bin/env bash
# Hook UserPromptSubmit : prompt soumis -> working (début du prompt tronqué).
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
prompt="$(jget '.prompt' prompt)"
detail="$(sanitize "$prompt")"
[ -n "$detail" ] || detail="Prompt reçu"
mark_throttle
bg san_call state working "$detail" --ttl "$TTL_WORKING"
exit 0
