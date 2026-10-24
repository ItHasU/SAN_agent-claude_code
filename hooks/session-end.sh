#!/usr/bin/env bash
# Hook SessionEnd : session terminée -> idle.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
reset_throttle
bg san_call state idle "Session terminée" --ttl "$TTL_ENDED"
exit 0
