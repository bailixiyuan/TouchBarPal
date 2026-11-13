#!/bin/bash
#
# Builds TouchBarPal.app into .build/TouchBarPal.app
#
#   ./build.sh              native architecture (fast, for local development)
#   ./build.sh --universal  arm64 + x86_64 (for release artefacts)
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TouchBarPal"
BUILD_DIR=".build"
APP="$BUILD_DIR/$APP_NAME.app"

ARCHS=("$(uname -m)")
if [ "${1:-}" = "--universal" ]; then
  ARCHS=(arm64 x86_64)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon (generated once, cached).
if [ ! -f "Resources/AppIcon.icns" ]; then
  echo "Generating app icon…"
  /usr/bin/swift tools/make-icon.swift "Resources/AppIcon.icns"
fi
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/spritesheet.webp" "$APP/Contents/Resources/spritesheet.webp"

# The private Touch Bar headers are imported through a bridging header.
# Ad-hoc signing and no hardened runtime are required for the private
# NSTouchBar system-modal API to work.
SLICES=()
for ARCH in "${ARCHS[@]}"; do
  OUT="$BUILD_DIR/$APP_NAME-$ARCH"
  /usr/bin/swiftc \
    -O -whole-module-optimization \
    -swift-version 5 \
    -target "${ARCH}-apple-macos13.0" \
    -import-objc-header Sources/PrivateTouchBar.h \
    -framework AppKit \
    -framework CoreGraphics \
    -o "$OUT" \
    Sources/*.swift
  SLICES+=("$OUT")
done

if [ "${#SLICES[@]}" -eq 1 ]; then
  mv "${SLICES[0]}" "$APP/Contents/MacOS/$APP_NAME"
else
  /usr/bin/lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
  rm -f "${SLICES[@]}"
fi

# Prefer the stable local identity: an ad-hoc signature changes its cdhash on
# every build, which silently invalidates the Accessibility (TCC) grant.
SIGN_ID="TouchBarPal Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  # `securityd` occasionally answers errSecInternalComponent on the first try.
  for _ in 1 2 3 4 5; do
    if /usr/bin/codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then break; fi
    sleep 1
  done
else
  /usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built: $APP (${ARCHS[*]})"
echo "Run:   $APP/Contents/MacOS/$APP_NAME --selftest"
