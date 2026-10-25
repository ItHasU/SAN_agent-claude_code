#!/usr/bin/env bash
# Hook SessionStart : session démarrée -> idle.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
reset_throttle
sa_reset
bg san_call state idle "Session démarrée" --ttl "$TTL_IDLE"
exit 0
