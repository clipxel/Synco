#!/bin/sh
# Builds Synco.app and packs it into dist/Synco-<version>.dmg with an Applications shortcut,
# so installing is dragging the app onto it.
set -e
cd "$(dirname "$0")"
./make_app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" ../Synco.app/Contents/Info.plist)
STAGE=$(mktemp -d)
cp -R ../Synco.app "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
mkdir -p ../dist
OUT="../dist/Synco-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Synco $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "$STAGE"
echo "dmg: $(cd ../dist && pwd)/Synco-$VERSION.dmg"
