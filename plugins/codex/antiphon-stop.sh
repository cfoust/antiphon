#!/bin/sh
# Codex Stop hook: speak the turn's outcome. The stdin payload carries
# last_assistant_message, so the room hears a real summary even when the model
# forgot to call antiphon_done. Fail-open, non-blocking.
STATE="${ANTIPHON_STATE:-$HOME/.antiphon}"
[ -f "$STATE/antiphond.json" ] || exit 0
. "$(dirname "$0")/antiphon-lib.sh"
[ -n "$BIN" ] || exit 0

PAYLOAD=$(cat 2>/dev/null)
SID=$(printf '%s' "$PAYLOAD" | json_get session_id)
MSG=$(printf '%s' "$PAYLOAD" | json_get last_assistant_message | tr '\n' ' ' | head -c 400)
[ -n "$MSG" ] || exit 0

emit -type done -text "$MSG" ${SID:+-session "$SID"} -kind codex &
exit 0
