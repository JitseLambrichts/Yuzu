#!/bin/zsh
# Builds build/Yuzu.zip for a GitHub release and optionally publishes it.
# Usage: scripts/release.sh [--publish]   (--publish creates release v<VERSION> with gh)
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/build-app.sh")"
ZIP="$ROOT/build/Yuzu.zip"
NOTES="$ROOT/scripts/release-notes.md"

"$ROOT/scripts/build-app.sh"

# ditto keeps the bundle's signature and extended attributes intact, unlike zip.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Yuzu.app" "$ZIP"
echo "Packaged: $ZIP ($(du -h "$ZIP" | cut -f1))"

if [[ "${1:-}" == "--publish" ]]; then
  # The asset keeps the same name in every release, so
  # https://github.com/JitseLambrichts/Yuzu/releases/latest/download/Yuzu.zip always points at the newest one.
  gh release create "v$VERSION" "$ZIP" --title "Yuzu $VERSION" --notes-file "$NOTES"
fi
