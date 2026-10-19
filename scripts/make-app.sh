#!/bin/bash
# Wraps the SwiftPM-built LockedInApp binary into LockedIn.app and ad-hoc signs it.
# Usage: scripts/make-app.sh <path to LockedInApp binary> <output .app path>
set -euo pipefail

BIN="${1:?usage: make-app.sh <LockedInApp binary> <out.app>}"
OUT="${2:?usage: make-app.sh <LockedInApp binary> <out.app>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/../Resources/Info.plist.template"
BUNDLE_ID="${BUNDLE_ID:-com.tgreco.lockedin}"
VERSION="${VERSION:-$("$(dirname "$BIN")/lockedin" version --short 2>/dev/null || echo 0.1.0)}"
BUILD="${BUILD:-1}"

[ -x "$BIN" ] || { echo "make-app.sh: $BIN is not an executable (run: swift build -c release)" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    "$TEMPLATE" > "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"
cp "$BIN" "$OUT/Contents/MacOS/LockedIn"
chmod 755 "$OUT/Contents/MacOS/LockedIn"
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"
codesign --verify --strict "$OUT"
echo "built $OUT (ad-hoc signed, bundle id $BUNDLE_ID, version $VERSION)"
