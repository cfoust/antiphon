#!/usr/bin/env bash
# Ship a CalVer release tag: stamp the version into everything user-visible,
# commit, tag, and push. Invoked as `just tag`.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree not clean — commit or stash first" >&2
  exit 1
fi

# CalVer: YYYY.M.D, with a .N suffix if today already shipped.
v="$(date +%Y).$((10#$(date +%m))).$((10#$(date +%d)))"
if git rev-parse -q --verify "refs/tags/v$v" >/dev/null; then
  n=2
  while git rev-parse -q --verify "refs/tags/v$v.$n" >/dev/null; do n=$((n + 1)); done
  v="$v.$n"
fi

echo "tagging v$v"

# Stamp: native app, daemon, web footer, Claude Code plugin.
sed -i '' -E "s|(<key>CFBundleShortVersionString</key> *<string>)[^<]*(</string>)|\\1$v\\2|" native/AntiphonApp/Info.plist
sed -i '' -E "s|(<key>CFBundleVersion</key> *<string>)[^<]*(</string>)|\\1$v\\2|" native/AntiphonApp/Info.plist
sed -i '' "s|^var version = \".*\"|var version = \"$v\"|" antiphond/cmd/antiphond/main.go
sed -i '' "s|^export const VERSION: string = \".*\"|export const VERSION: string = \"$v\"|" web/src/version.ts
sed -i '' "s|\"version\": \".*\"|\"version\": \"$v\"|" plugins/claude-code/.claude-plugin/plugin.json

git add -A
git commit -m "release: v$v"
git tag -a "v$v" -m "Antiphon v$v"
git push origin HEAD "v$v"
echo "shipped v$v"
