#!/bin/sh
# Locate and exec `chamberd channel` (the per-session MCP subprocess).
# Fail-open: if no binary can be found, exit quietly — the session must work
# exactly as if the plugin weren't installed.
#
# Search ladder (first hit wins):
#   1. $CHAMBERD                        explicit override
#   2. ~/.chamber/chamberd.json "exe"   whatever binary is serving right now
#   3. PATH
#   4. Chamber.app bundles              /Applications + ~/Applications
#   5. repo dev build                   ../chamberd/bin/chamberd
#   6. ~/go/bin                         `go install ./cmd/chamberd`
BIN="${CHAMBERD:-}"

if [ -z "$BIN" ] && [ -f "$HOME/.chamber/chamberd.json" ]; then
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

if [ -z "$BIN" ]; then
  echo "chamber: chamberd binary not found (set CHAMBERD or install Chamber.app); narration disabled" >&2
  exit 0
fi
exec "$BIN" channel
