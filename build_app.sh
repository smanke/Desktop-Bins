#!/bin/bash
# Builds a proper "Desktop Bins.app" bundle from the Swift package.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Desktop Bins"
BUNDLE_ID="com.smanke.DesktopBins"
APP_DIR=".build/app/${APP_NAME}.app"

echo "Building universal release binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

UNIVERSAL_BIN=".build/apple/Products/Release/DesktopBins"
if [ ! -f "${UNIVERSAL_BIN}" ]; then
  UNIVERSAL_BIN=$(find .build -path "*release/DesktopBins" -not -path "*.dSYM*" | head -n 1)
fi

echo "Verifying architectures..."
lipo -info "${UNIVERSAL_BIN}"

echo "Assembling app bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${UNIVERSAL_BIN}" "${APP_DIR}/Contents/MacOS/DesktopBins"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

echo "Ad-hoc code signing (stable identifier: ${BUNDLE_ID})..."
# The apple-events entitlement is required under the hardened runtime, or
# Finder automation is blocked before macOS can even ask the user for consent.
codesign --force --deep --options runtime \
  --entitlements "Resources/DesktopBins.entitlements" \
  --identifier "${BUNDLE_ID}" --sign - "${APP_DIR}"

echo "Embedded entitlements:"
codesign -d --entitlements - --xml "${APP_DIR}" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | grep -A1 apple-events || true

echo "Done: ${APP_DIR}"
echo "Move it to /Applications, then launch it, e.g.:"
echo "  cp -R \"${APP_DIR}\" /Applications/"
echo "  open \"/Applications/${APP_NAME}.app\""
