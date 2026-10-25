#!/usr/bin/env bash
# Hook SubagentStop : un sous-agent a fini -> retiré du compteur de la session.
# Ne publie rien : si l'agent principal est déjà arrêté, aucun « done » n'est inventé.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
sa_stop "$(jget '.agent_id' agent_id)"
exit 0
