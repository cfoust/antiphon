#!/bin/sh
# Locate and exec `chamberd channel` (the per-session MCP subprocess).
# Fail-open: if the binary can't be found, exit quietly — the session must
# work exactly as if the plugin weren't installed.
BIN="${CHAMBERD:-}"
[ -z "$BIN" ] && BIN="$(command -v chamberd 2>/dev/null)"
[ -z "$BIN" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/../chamberd/bin/chamberd" ] && BIN="${CLAUDE_PLUGIN_ROOT}/../chamberd/bin/chamberd"
[ -z "$BIN" ] && [ -x "$HOME/go/bin/chamberd" ] && BIN="$HOME/go/bin/chamberd"
if [ -z "$BIN" ]; then
  echo "chamber: chamberd binary not found (set CHAMBERD or add it to PATH); narration disabled" >&2
  exit 0
fi
exec "$BIN" channel
