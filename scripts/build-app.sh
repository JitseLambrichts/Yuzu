#!/bin/zsh
# Builds build/Yuzu.app (release, ad-hoc signed).
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/Yuzu.app"
VERSION="0.1.0"

cd "$ROOT"
swift build -c release --product Yuzu
BIN="$(swift build -c release --product Yuzu --show-bin-path)/Yuzu"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools"
cp "$BIN" "$APP/Contents/MacOS/Yuzu"

# App icon: every size of the iconset from the 1024 px source.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET:h}"

# Optional: bundle self-built, static ffmpeg/cwebp binaries from vendor/Tools.
if [[ -d "$ROOT/vendor/Tools" ]]; then
  cp -R "$ROOT/vendor/Tools/." "$APP/Contents/Resources/Tools/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Yuzu</string>
  <key>CFBundleExecutable</key><string>Yuzu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>app.yuzu.Yuzu</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Yuzu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Yuzu — offline file converter</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Yuzu 2>/dev/null || true
  rm -rf /Applications/Yuzu.app
  cp -R "$APP" /Applications/Yuzu.app
  echo "Installed: /Applications/Yuzu.app"
fi
