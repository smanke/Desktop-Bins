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

# Prefer a real Developer ID identity over ad-hoc signing. Ad-hoc signatures
# have no stable designated requirement, so the app's identity changes on
# every rebuild and macOS silently revokes its Automation (Finder) grant each
# time. Signing with a certificate keeps that permission across builds.
# Override by exporting CODESIGN_IDENTITY.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"(.*)".*/\1/')
fi

# The apple-events entitlement is required under the hardened runtime, or
# Finder automation is blocked before macOS can even ask the user for consent.
if [ -n "${SIGN_IDENTITY}" ]; then
  echo "Signing with: ${SIGN_IDENTITY}"
  # --timestamp gets a secure timestamp from Apple, which notarization
  # requires. It needs network access; without it the signature is still
  # valid locally but notarization will reject it.
  codesign --force --options runtime --timestamp \
    --entitlements "Resources/DesktopBins.entitlements" \
    --identifier "${BUNDLE_ID}" --sign "${SIGN_IDENTITY}" "${APP_DIR}"
else
  echo "WARNING: no Developer ID identity found — falling back to ad-hoc."
  echo "         Finder automation permission will need re-approving after each rebuild."
  codesign --force --options runtime \
    --entitlements "Resources/DesktopBins.entitlements" \
    --identifier "${BUNDLE_ID}" --sign - "${APP_DIR}"
fi

echo "Designated requirement (this is what TCC keys the permission on):"
codesign -d -r- "${APP_DIR}" 2>&1 | grep "designated" || true

echo "Embedded entitlements:"
codesign -d --entitlements - --xml "${APP_DIR}" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | grep -A1 apple-events || true

echo "Done: ${APP_DIR}"
echo "Move it to /Applications, then launch it, e.g.:"
echo "  cp -R \"${APP_DIR}\" /Applications/"
echo "  open \"/Applications/${APP_NAME}.app\""
