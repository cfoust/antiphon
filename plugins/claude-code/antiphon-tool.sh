#!/bin/sh
# PostToolUse hook: tell the antiphon a tool call just happened, so it can tick
# this agent's chord. Fail-open AND non-blocking — this runs on EVERY tool
# call, so the emit is backgrounded and the hook returns immediately.
[ -f "$HOME/.antiphon/antiphond.json" ] || exit 0

# session_id comes in the hook's stdin JSON (hooks don't get the session env)
SID=$(cat 2>/dev/null | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

# same binary ladder as antiphon-channel.sh
BIN="${ANTIPHOND:-}"
if [ -z "$BIN" ]; then
  EXE=$(sed -n 's/.*"exe":"\([^"]*\)".*/\1/p' "$HOME/.antiphon/antiphond.json" 2>/dev/null)
  [ -n "$EXE" ] && [ -x "$EXE" ] && BIN="$EXE"
fi
[ -z "$BIN" ] && BIN="$(command -v antiphond 2>/dev/null)"
for CAND in \
  "/Applications/Antiphon.app/Contents/MacOS/antiphond" \
  "$HOME/Applications/Antiphon.app/Contents/MacOS/antiphond" \
  "${CLAUDE_PLUGIN_ROOT}/../antiphond/bin/antiphond" \
  "$HOME/go/bin/antiphond"; do
  [ -z "$BIN" ] && [ -x "$CAND" ] && BIN="$CAND"
done
[ -n "$BIN" ] || exit 0

"$BIN" emit -type tool ${SID:+-session "$SID"} -kind claude-code >/dev/null 2>&1 &
exit 0
