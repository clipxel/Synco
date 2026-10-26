#!/bin/sh
# Builds Synco.app next to this folder: swift build plus an Info.plist, no Xcode needed.
set -e
cd "$(dirname "$0")"
# The macOS 27 SDK needs a SwiftUI macro plugin that only ships with Xcode; with the
# Command Line Tools alone, build against the newest older SDK that is installed.
CLT=/Library/Developer/CommandLineTools/SDKs
if [ -z "$SDKROOT" ] && [ ! -d /Applications/Xcode.app ]; then
  for sdk in $(ls -d $CLT/MacOSX2[0-6].*.sdk 2>/dev/null | sort -V -r); do export SDKROOT=$sdk; break; done
fi
[ -n "$SDKROOT" ] && echo "SDK: $SDKROOT"
VERSION=${VERSION:-$(cat VERSION)}
./set_version.sh
# UNIVERSAL=1: Apple silicon and Intel in one app (needs Xcode, as on the release runner).
if [ -n "$UNIVERSAL" ]; then
  swift build -c release --product SyncApp --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/SyncApp
else
  swift build -c release --product SyncApp
  BIN=.build/release/SyncApp
fi
APP=${APP:-../Synco.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Synco"
cp brand/AppIcon.icns "$APP/Contents/Resources/"
cp brand/mark-white.png "$APP/Contents/Resources/mark.png"           # white versions: the app is dark
cp brand/wordmark-white.png "$APP/Contents/Resources/wordmark.png"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Synco</string>
  <key>CFBundleDisplayName</key><string>Synco</string>
  <key>CFBundleIdentifier</key><string>local.mariano.synco</string>
  <key>CFBundleExecutable</key><string>Synco</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>XML de línea de tiempo</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.xml</string></array>
    <key>LSHandlerRank</key><string>Alternate</string>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "listo: $(cd "$APP" && pwd)"
