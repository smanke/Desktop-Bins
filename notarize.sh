#!/bin/bash
# Submits the built app to Apple for notarization, then staples the ticket
# so it launches cleanly on other Macs without a Gatekeeper warning.
#
# One-time setup (run this yourself — it needs your app-specific password,
# created at https://account.apple.com under App-Specific Passwords):
#
#   xcrun notarytool store-credentials "DesktopBins" \
#     --apple-id "<your-apple-id>" \
#     --team-id "32CWL275JJ"
#
# It will prompt for the app-specific password and save everything to the
# keychain, so this script never handles the password itself.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Desktop Bins"
APP_DIR=".build/app/${APP_NAME}.app"
ZIP_PATH=".build/app/DesktopBins-notarize.zip"
PROFILE="${NOTARY_PROFILE:-DesktopBins}"

if [ ! -d "${APP_DIR}" ]; then
  echo "No app bundle at ${APP_DIR} — run ./build_app.sh first."
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
  echo "No stored notarization credentials named '${PROFILE}'."
  echo "Run the store-credentials command in the header of this script first."
  exit 1
fi

# Notarization rejects anything signed without a secure timestamp.
if ! codesign -dvv "${APP_DIR}" 2>&1 | grep -q "^Timestamp="; then
  echo "Signature has no secure timestamp. Re-run ./build_app.sh (it signs with --timestamp)."
  exit 1
fi

echo "Zipping bundle for submission..."
rm -f "${ZIP_PATH}"
# ditto preserves the bundle structure and symlinks; plain zip does not.
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "Submitting to Apple (this usually takes a few minutes)..."
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${PROFILE}" --wait

echo "Stapling the ticket to the app..."
xcrun stapler staple "${APP_DIR}"

echo "Verifying with Gatekeeper..."
spctl -a -vv "${APP_DIR}"

echo
echo "Done. Reinstall the stapled build:"
echo "  cp -R \"${APP_DIR}\" /Applications/"
echo
echo "To share it, zip the stapled bundle — the ticket travels with it:"
echo "  ditto -c -k --keepParent \"${APP_DIR}\" \"~/Desktop/${APP_NAME}.zip\""
