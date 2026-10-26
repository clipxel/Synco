#!/bin/sh
# Self-update, end to end, in a temp folder: a 1.0.0 copy of Synco finds a newer local release
# (update.json + .dmg), downloads it, checks its SHA-256, swaps itself and ends up as the new version.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d)
CUR=$(cat engine/VERSION)
NEW=$(echo "$CUR" | awk -F. '{print $1"."$2"."$3+1}')
echo "versión actual $CUR → nueva $NEW"
# The newer release, built exactly like the real one.
(cd engine && VERSION=$NEW APP="$T/new/Synco.app" ./make_app.sh >/dev/null 2>&1)
mkdir -p "$T/stage" && cp -R "$T/new/Synco.app" "$T/stage/" && ln -s /Applications "$T/stage/Aplicaciones"
hdiutil create -volname "Synco $NEW" -srcfolder "$T/stage" -fs HFS+ -format UDZO -ov "$T/Synco-$NEW.dmg" >/dev/null
SHA=$(shasum -a 256 "$T/Synco-$NEW.dmg" | cut -d' ' -f1)
SIZE=$(stat -f %z "$T/Synco-$NEW.dmg")
cat > "$T/update.json" <<JSON
{"version": "$NEW", "notes": "prueba", "assets": {"mac": {"file": "Synco-$NEW.dmg", "size": $SIZE, "sha256": "$SHA", "url": "file://$T/Synco-$NEW.dmg"}}}
JSON
# The installed copy that should update itself.
mkdir -p "$T/target" && cp -R Synco.app "$T/target/"
SYNCO_UPDATE_MANIFEST="file://$T/update.json" SYNCO_UPDATE_AUTO=1 SYNCO_UPDATE_TARGET="$T/target/Synco.app" \
  "$T/target/Synco.app/Contents/MacOS/Synco" >/dev/null 2>&1 &
PID=$!
i=0; while kill -0 $PID 2>/dev/null && [ $i -lt 120 ]; do sleep 1; i=$((i+1)); done
kill -0 $PID 2>/dev/null && { kill $PID; echo "FALLA: la app no se cerró para actualizarse"; exit 1; }
sleep 3
GOT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$T/target/Synco.app/Contents/Info.plist")
[ ! -e "$T/target/Synco.app.old" ] || { echo "FALLA: quedó la versión vieja al lado"; exit 1; }
codesign --verify "$T/target/Synco.app" || { echo "FALLA: firma inválida tras actualizar"; exit 1; }
[ "$GOT" = "$NEW" ] && echo "PASA  se actualizó sola de $CUR a $GOT" || { echo "FALLA: quedó en $GOT"; exit 1; }
# A tampered download must be refused and leave the app as it was.
mkdir -p "$T/target2" && cp -R Synco.app "$T/target2/"
sed "s/$SHA/$(echo $SHA | tr 'abcdef0123456789' '0123456789abcdef')/" "$T/update.json" > "$T/bad.json"
SYNCO_UPDATE_MANIFEST="file://$T/bad.json" SYNCO_UPDATE_AUTO=1 SYNCO_UPDATE_TARGET="$T/target2/Synco.app" \
  "$T/target2/Synco.app/Contents/MacOS/Synco" >/dev/null 2>&1 &
PID=$!
sleep 12
GOT2=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$T/target2/Synco.app/Contents/Info.plist")
kill $PID 2>/dev/null || true
[ "$GOT2" = "$CUR" ] && echo "PASA  una descarga alterada se rechaza y la app queda igual" || { echo "FALLA: se instaló algo alterado"; exit 1; }
rm -rf "$T"
