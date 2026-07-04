#!/bin/sh
# Codex PostToolUse hook: tell the antiphon a tool call just happened, so it
# can tick this agent's chord. Fail-open AND non-blocking — this runs on EVERY
# tool call, so the emit is backgrounded and the hook returns immediately.
STATE="${ANTIPHON_STATE:-$HOME/.antiphon}"
[ -f "$STATE/antiphond.json" ] || exit 0
. "$(dirname "$0")/antiphon-lib.sh"
[ -n "$BIN" ] || exit 0

SID=$(cat 2>/dev/null | json_get session_id)
emit -type tool ${SID:+-session "$SID"} -kind codex &
exit 0
