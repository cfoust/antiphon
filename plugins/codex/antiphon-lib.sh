# Sourced by the Codex hook scripts — never run directly.
# Resolves the antiphond binary (same ladder as the Claude Code plugin) and
# provides tiny JSON helpers. Everything here is fail-open: no binary, no JSON
# parser, no daemon — the caller just does nothing and exits 0.

STATE="${ANTIPHON_STATE:-$HOME/.antiphon}"

# Binary ladder (first hit wins): $ANTIPHOND → the "exe" recorded in the
# discovery file (whatever binary is serving right now) → PATH → Antiphon.app
# bundles → ~/go/bin.
BIN="${ANTIPHOND:-}"
if [ -z "$BIN" ] && [ -f "$STATE/antiphond.json" ]; then
  EXE=$(sed -n 's/.*"exe":"\([^"]*\)".*/\1/p' "$STATE/antiphond.json" 2>/dev/null)
  [ -n "$EXE" ] && [ -x "$EXE" ] && BIN="$EXE"
fi
[ -z "$BIN" ] && BIN="$(command -v antiphond 2>/dev/null)"
for CAND in \
  "/Applications/Antiphon.app/Contents/MacOS/antiphond" \
  "$HOME/Applications/Antiphon.app/Contents/MacOS/antiphond" \
  "$HOME/go/bin/antiphond"; do
  [ -z "$BIN" ] && [ -x "$CAND" ] && BIN="$CAND"
done

# json_get PATH — read a (possibly dotted) string field from the JSON on stdin.
# jq → python3 → crude sed on the last path component.
json_get() {
  if command -v jq >/dev/null 2>&1; then
    jq -r ".${1} // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        v = v.get(k) if isinstance(v, dict) else None
    if isinstance(v, str):
        print(v)
except Exception:
    pass' "$1" 2>/dev/null
  else
    KEY="${1##*.}"
    sed -n 's/.*"'"$KEY"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -1
  fi
}

# emit ARGS… — fail-open `antiphond emit` (adds -state when overridden for tests).
emit() {
  [ -n "$BIN" ] || return 0
  "$BIN" emit ${ANTIPHON_STATE:+-state "$ANTIPHON_STATE"} "$@" >/dev/null 2>&1
}
