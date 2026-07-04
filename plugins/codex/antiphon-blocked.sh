#!/bin/sh
# Codex PermissionRequest hook: the agent is waiting on an approval — surface
# it in the room as a blocked question. Fail-open, non-blocking.
STATE="${ANTIPHON_STATE:-$HOME/.antiphon}"
[ -f "$STATE/antiphond.json" ] || exit 0
. "$(dirname "$0")/antiphon-lib.sh"
[ -n "$BIN" ] || exit 0

PAYLOAD=$(cat 2>/dev/null)
SID=$(printf '%s' "$PAYLOAD" | json_get session_id)
DESC=$(printf '%s' "$PAYLOAD" | json_get tool_input.description | tr '\n' ' ' | head -c 200)
[ -n "$DESC" ] || DESC=$(printf '%s' "$PAYLOAD" | json_get description | tr '\n' ' ' | head -c 200)
[ -n "$DESC" ] && Q="May I go ahead? $DESC" || Q="Codex needs your approval to continue."

emit -type blocked -text "$Q" ${SID:+-session "$SID"} -kind codex &
exit 0
