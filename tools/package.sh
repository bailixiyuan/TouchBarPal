#!/bin/bash
#
# Builds the 1.0 release artefacts into dist/:
#   TouchBarPal-1.0-universal.zip
#   TouchBarPal-1.0-universal.dmg
#   SHA256SUMS.txt
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="TouchBarPal"
VERSION="1.0"
DIST="dist"
APP=".build/$APP_NAME.app"
BASENAME="$APP_NAME-$VERSION-universal"

rm -rf "$DIST"
mkdir -p "$DIST"

./build.sh --universal

ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
if [ "$ARCHS" != "x86_64 arm64" ] && [ "$ARCHS" != "arm64 x86_64" ]; then
  echo "error: unexpected architectures: $ARCHS" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP"
echo "Signed binary: $ARCHS"

# Zip keeps the bundle structure, signature and resource forks intact.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$BASENAME.zip"

# DMG with the usual drag-to-Applications layout.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DIST/$BASENAME.dmg" >/dev/null

cd "$DIST"
/usr/bin/shasum -a 256 "$BASENAME.zip" "$BASENAME.dmg" > SHA256SUMS.txt
cat SHA256SUMS.txt
echo
echo "Artefacts in $DIST/"
