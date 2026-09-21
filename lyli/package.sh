#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
DIST="dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || {
  echo "!! release packaging only supports arm64 macOS (current: $ARCH)" >&2
  exit 1
}

PYTHON_BIN="${PYTHON_BIN:-python3}"
DMG_BACKGROUND="$STAGE/dmg-background.tiff"
APP="$STAGE/Lyli.app"

echo "==> building arm64 release"
./build.sh --dest "$APP" > "$STAGE/build.log" 2>&1 || {
  echo "!! build.sh failed; log tail:" >&2
  tail -20 "$STAGE/build.log" >&2
  exit 1
}

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[ -n "$VERSION" ] || {
  echo "!! cannot read CFBundleShortVersionString" >&2
  exit 1
}

bad=""
while IFS= read -r f; do
  archs="$(lipo -archs "$f" 2>/dev/null || true)"
  [ -z "$archs" ] && continue
  [ "$archs" = "arm64" ] || bad="$bad ${f#$APP/}($archs)"
done < <(find "$APP" -type f)
if [ -n "$bad" ]; then
  echo "!! release contains non-arm64 Mach-O files:" >&2
  for f in $bad; do echo "     $f" >&2; done
  exit 1
fi
codesign -v --deep --strict "$APP"
echo "    architecture and signature verified"

rm -rf "$DIST"
mkdir -p "$DIST"

human_size() {
  /usr/bin/python3 -c "import sys;n=int(sys.argv[1]);print(f'{n/1048576:.2f} MB' if n>=1048576 else (f'{n/1024:.1f} KB' if n>=1024 else f'{n} B'))" "$(stat -f %z "$1")"
}

BASE="Lyli-v$VERSION-macos-arm64"
echo "==> packaging $BASE"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$BASE.zip"
(cd "$DIST" && shasum -a 256 "$BASE.zip" > "$BASE.zip.sha256")

DMGSTAGE="$STAGE/dmg"
mkdir -p "$DMGSTAGE"
ditto "$APP" "$DMGSTAGE/Lyli.app"

if "$PYTHON_BIN" -c "import dmgbuild" >/dev/null 2>&1; then
  swift "$ROOT/scripts/make_dmg_background.swift" "$DMG_BACKGROUND"
  LYLI_DMG_APP="$DMGSTAGE/Lyli.app" \
  LYLI_DMG_VOLNAME="Lyli" \
  LYLI_DMG_BACKGROUND="$DMG_BACKGROUND" \
    "$PYTHON_BIN" -m dmgbuild -s "$ROOT/scripts/dmg_settings.py" \
      "Lyli" "$DIST/$BASE.dmg" >/dev/null
else
  echo "    (dmgbuild unavailable; falling back to hdiutil)"
  ln -s /Applications "$DMGSTAGE/Applications"
  hdiutil create -volname "Lyli" -srcfolder "$DMGSTAGE" \
    -fs HFS+ -format UDZO -ov -quiet "$DIST/$BASE.dmg"
fi

printf "    %-48s %s\n" "$BASE.zip" "$(human_size "$DIST/$BASE.zip")"
printf "    %-48s %s\n" "$BASE.zip.sha256" "$(human_size "$DIST/$BASE.zip.sha256")"
printf "    %-48s %s\n" "$BASE.dmg" "$(human_size "$DIST/$BASE.dmg")"
