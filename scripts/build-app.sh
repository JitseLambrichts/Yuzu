#!/bin/zsh
# Bouwt build/Yuzu.app (release, ad-hoc gesigneerd).
# Gebruik: scripts/build-app.sh [--install]   (--install kopieert naar /Applications)
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

# Optioneel: zelf gecompileerde, statische ffmpeg/cwebp meeleveren via vendor/Tools.
if [[ -d "$ROOT/vendor/Tools" ]]; then
  cp -R "$ROOT/vendor/Tools/." "$APP/Contents/Resources/Tools/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>CFBundleDisplayName</key><string>Yuzu</string>
  <key>CFBundleExecutable</key><string>Yuzu</string>
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
  <key>NSHumanReadableCopyright</key><string>Yuzu — offline bestandsconverter</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Gebouwd: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Yuzu 2>/dev/null || true
  rm -rf /Applications/Yuzu.app
  cp -R "$APP" /Applications/Yuzu.app
  echo "Geïnstalleerd: /Applications/Yuzu.app"
fi
