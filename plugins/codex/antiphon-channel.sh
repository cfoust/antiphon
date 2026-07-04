#!/bin/sh
# Locate and exec `antiphond channel` (the per-session MCP subprocess) for
# Codex. Identical to the Claude Code launcher except the session is labeled
# kind=codex. Fail-open: if no binary can be found, exit quietly — the session
# must work exactly as if the adapter weren't installed.
. "$(dirname "$0")/antiphon-lib.sh"

if [ -z "$BIN" ]; then
  echo "antiphon: antiphond binary not found (set ANTIPHOND or install Antiphon.app); narration disabled" >&2
  exit 0
fi
ANTIPHON_KIND=codex
export ANTIPHON_KIND
exec "$BIN" channel
