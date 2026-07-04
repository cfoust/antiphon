#!/bin/sh
# Locate and exec `antiphond channel` (the per-session MCP subprocess).
# Fail-open: if no binary can be found, exit quietly — the session must work
# exactly as if the plugin weren't installed.
#
# Search ladder (first hit wins):
#   1. $ANTIPHOND                        explicit override
#   2. ~/.antiphon/antiphond.json "exe"   whatever binary is serving right now
#   3. PATH
#   4. Antiphon.app bundles              /Applications + ~/Applications
#   5. repo dev build                   ../../antiphond/bin/antiphond
#   6. ~/go/bin                         `go install ./cmd/antiphond`
BIN="${ANTIPHOND:-}"

if [ -z "$BIN" ] && [ -f "$HOME/.antiphon/antiphond.json" ]; then
  EXE=$(sed -n 's/.*"exe":"\([^"]*\)".*/\1/p' "$HOME/.antiphon/antiphond.json" 2>/dev/null)
  [ -n "$EXE" ] && [ -x "$EXE" ] && BIN="$EXE"
fi
[ -z "$BIN" ] && BIN="$(command -v antiphond 2>/dev/null)"
for CAND in \
  "/Applications/Antiphon.app/Contents/MacOS/antiphond" \
  "$HOME/Applications/Antiphon.app/Contents/MacOS/antiphond" \
  "${CLAUDE_PLUGIN_ROOT}/../../antiphond/bin/antiphond" \
  "$HOME/go/bin/antiphond"; do
  [ -z "$BIN" ] && [ -x "$CAND" ] && BIN="$CAND"
done

if [ -z "$BIN" ]; then
  echo "antiphon: antiphond binary not found (set ANTIPHOND or install Antiphon.app); narration disabled" >&2
  exit 0
fi
exec "$BIN" channel
