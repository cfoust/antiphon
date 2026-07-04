#!/bin/sh
# Install the Antiphon adapter into ~/.codex — idempotent, originals backed up.
#
#   sh plugins/codex/install.sh
#
# Copies the hook scripts + narration mandate into ~/.codex/antiphon/, merges
# our hooks into ~/.codex/hooks.json (prior Antiphon entries are replaced, all
# other hooks preserved), and appends the MCP server block to
# ~/.codex/config.toml if it isn't there yet. Uses jq when available, else
# python3. Codex requires one-time trust for non-managed hooks: run /hooks
# inside Codex after installing.
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
CODEX="${CODEX_HOME:-$HOME/.codex}"
DEST="$CODEX/antiphon"
STAMP=$(date +%Y%m%d%H%M%S)

mkdir -p "$DEST"
for f in antiphon-lib.sh antiphon-channel.sh antiphon-tool.sh antiphon-stop.sh antiphon-blocked.sh; do
  cp "$SRC/$f" "$DEST/$f"
  chmod +x "$DEST/$f"
done
cp "$SRC/hooks/narration.md" "$DEST/narration.md"

# ---- hooks.json: replace any prior antiphon entries, keep everything else ----
HOOKS="$CODEX/hooks.json"
if [ ! -f "$HOOKS" ]; then
  cp "$SRC/hooks/hooks.json" "$HOOKS"
else
  cp "$HOOKS" "$HOOKS.bak.$STAMP"
  if command -v jq >/dev/null 2>&1; then
    jq -s '
      .[1] as $ours
      | .[0]
      | .hooks = ((.hooks // {}) | with_entries(
          .value = (.value | map(select(tostring | test("antiphon"; "i") | not)))))
      | reduce (($ours.hooks // {}) | to_entries[]) as $e
          (.; .hooks[$e.key] = (((.hooks[$e.key] // []) | map(select(. != null))) + $e.value))
      | .hooks = (.hooks | with_entries(select(.value | length > 0)))
    ' "$HOOKS.bak.$STAMP" "$SRC/hooks/hooks.json" > "$HOOKS.tmp"
  else
    python3 - "$HOOKS.bak.$STAMP" "$SRC/hooks/hooks.json" > "$HOOKS.tmp" <<'PY'
import json, re, sys
cur = json.load(open(sys.argv[1]))
ours = json.load(open(sys.argv[2]))
hooks = cur.setdefault("hooks", {}) or {}
for key, entries in list(hooks.items()):
    hooks[key] = [e for e in entries if not re.search("antiphon", json.dumps(e), re.I)]
for key, entries in (ours.get("hooks") or {}).items():
    hooks.setdefault(key, []).extend(entries)
cur["hooks"] = {k: v for k, v in hooks.items() if v}
print(json.dumps(cur, indent=2))
PY
  fi
  mv "$HOOKS.tmp" "$HOOKS"
fi

# ---- config.toml: append the MCP server block once ---------------------------
CFG="$CODEX/config.toml"
if [ -f "$CFG" ] && grep -q '^\[mcp_servers\.antiphon\]' "$CFG"; then
  echo "config.toml: [mcp_servers.antiphon] already present, left as-is"
else
  [ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$STAMP"
  { [ -f "$CFG" ] && [ -s "$CFG" ] && echo ""; cat "$SRC/config.toml"; } >> "$CFG"
fi

echo "installed: $DEST, $HOOKS, $CFG"
echo "next: run /hooks inside Codex once to trust the Antiphon hooks."
