#!/bin/sh
# PostToolUse hook: tell the chamber a tool call just happened, so it can tick
# this agent's chord. Fail-open AND non-blocking — this runs on EVERY tool
# call, so the emit is backgrounded and the hook returns immediately.
[ -f "$HOME/.chamber/chamberd.json" ] || exit 0

# session_id comes in the hook's stdin JSON (hooks don't get the session env)
SID=$(cat 2>/dev/null | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

# same binary ladder as chamber-channel.sh
BIN="${CHAMBERD:-}"
if [ -z "$BIN" ]; then
  EXE=$(sed -n 's/.*"exe":"\([^"]*\)".*/\1/p' "$HOME/.chamber/chamberd.json" 2>/dev/null)
  [ -n "$EXE" ] && [ -x "$EXE" ] && BIN="$EXE"
fi
[ -z "$BIN" ] && BIN="$(command -v chamberd 2>/dev/null)"
for CAND in \
  "/Applications/Chamber.app/Contents/MacOS/chamberd" \
  "$HOME/Applications/Chamber.app/Contents/MacOS/chamberd" \
  "${CLAUDE_PLUGIN_ROOT}/../chamberd/bin/chamberd" \
  "$HOME/go/bin/chamberd"; do
  [ -z "$BIN" ] && [ -x "$CAND" ] && BIN="$CAND"
done
[ -n "$BIN" ] || exit 0

"$BIN" emit -type tool ${SID:+-session "$SID"} -kind claude-code >/dev/null 2>&1 &
exit 0
