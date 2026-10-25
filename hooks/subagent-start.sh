#!/usr/bin/env bash
# Hook SubagentStart : un sous-agent démarre -> enregistré dans le compteur de la session.
# Ne publie rien (le hook Stop en tient compte pour ne pas annoncer « terminé »).
# Champs reçus : agent_id, agent_type.
# shellcheck source=hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null || exit 0
sa_start "$(jget '.agent_id' agent_id)"
exit 0
