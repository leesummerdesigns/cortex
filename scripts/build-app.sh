#!/bin/zsh
# Builds Cortex.app into ./build (release, universal, ad-hoc signed) and zips it for a GitHub release.
# Usage: scripts/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-0.3.0}

(cd web && { [[ -d node_modules ]] || npm ci --silent; } && npm run build --silent)
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS --product CortexApp
swift build -c release $ARCHS --product cortex
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=build/Cortex.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/web/dist"
cp "$BIN/CortexApp" "$APP/Contents/MacOS/Cortex"
cp "$BIN/cortex" "$APP/Contents/Helpers/cortex"
cp web/index.html "$APP/Contents/Resources/web/"
cp web/dist/graph.js "$APP/Contents/Resources/web/dist/"
cp -R Packs "$APP/Contents/Resources/Packs"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 512px PNG icon for the Claude Desktop extension (.mcpb)
[[ -f Resources/AppIcon-1024.png ]] && sips -z 512 512 Resources/AppIcon-1024.png --out "$APP/Contents/Resources/AppIcon.png" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Cortex</string>
  <key>CFBundleDisplayName</key><string>Cortex</string>
  <key>CFBundleIdentifier</key><string>com.louishenrich.cortex</string>
  <key>CFBundleExecutable</key><string>Cortex</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.louishenrich.cortex</string>
    <key>CFBundleURLSchemes</key><array><string>cortex</string></array>
  </dict></array>
</dict></plist>
PLIST

codesign --force --deep -s - "$APP"
ditto -c -k --keepParent "$APP" build/Cortex.zip
echo "Built $APP and build/Cortex.zip ($VERSION)"
