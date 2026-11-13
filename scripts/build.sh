#!/bin/sh
# Build TWP Portal with swiftc directly (no SwiftPM, no Xcode needed).
#   sh scripts/build.sh            -> build/twp and build/TWPPortal
#   sh scripts/build.sh app        -> also dist/TWP Portal.app (+ a zip)
# `swift build` works too on a healthy toolchain; this script exists because
# it has no dependency on SwiftPM's manifest loader.
set -eu
cd "$(dirname "$0")/.."
OUT=build
mkdir -p "$OUT"
FLAGS="-O -swift-version 5 -target arm64-apple-macos27.0 -suppress-warnings"

echo "== PortalCore"
swiftc $FLAGS -parse-as-library -module-name PortalCore -emit-module -emit-module-path "$OUT/PortalCore.swiftmodule" \
  -emit-library -static -o "$OUT/libPortalCore.a" Sources/PortalCore/*.swift
echo "== twp (CLI)"
swiftc $FLAGS -I "$OUT" -L "$OUT" -lPortalCore -module-name twp -o "$OUT/twp" Sources/twp/*.swift
echo "== TWPPortal (app)"
swiftc $FLAGS -parse-as-library -I "$OUT" -L "$OUT" -lPortalCore -module-name TWPPortal -o "$OUT/TWPPortal" Sources/TWPPortal/*.swift

[ "${1:-}" = "app" ] || { echo "built $OUT/twp and $OUT/TWPPortal"; exit 0; }

APP="dist/TWP Portal.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/TWPPortal" "$APP/Contents/MacOS/TWPPortal"
cp "$OUT/twp" "$APP/Contents/MacOS/twp"
cp packaging/Info.plist "$APP/Contents/Info.plist"
[ -f packaging/AppIcon.icns ] && cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough to run locally. Distribution to other Macs needs a
# Developer ID signature + notarization (see README).
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" ${CODESIGN_IDENTITY:+--options runtime} "$APP"
( cd dist && ditto -c -k --keepParent "TWP Portal.app" "TWP-Portal-mac.zip" )
echo "built $APP and dist/TWP-Portal-mac.zip"
