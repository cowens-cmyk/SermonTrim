#!/bin/zsh
# Signs the app with the Hope Church JC Developer ID, notarizes it with Apple, staples the ticket,
# and builds a signed + notarized + stapled DMG.
#   Scripts/sign_notarize.sh "<path to Sermon Trim.app>"        -> dist/SermonTrim.dmg
# One-time setup (stores an Apple credential in your Keychain; Claude never sees it):
#   xcrun notarytool store-credentials "sermontrim-notary" --apple-id <you@...> --team-id TCAQTA64TB
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: sign_notarize.sh <path to Sermon Trim.app>}"
ID="Developer ID Application: Hope Church JC (TCAQTA64TB)"
PROFILE="${NOTARY_PROFILE:-sermontrim-notary}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK:?}"' EXIT

echo "• Signing app (hardened runtime, secure timestamp)…"
codesign --force --options runtime --timestamp --sign "$ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "• Notarizing app (Apple usually takes 1–5 minutes)…"
ditto -c -k --keepParent "$APP" "$WORK/app.zip"
xcrun notarytool submit "$WORK/app.zip" --keychain-profile "$PROFILE" --wait | tee "$WORK/app.log"
grep -q "status: Accepted" "$WORK/app.log" || { echo "Notarization of the app was not accepted."; exit 1; }
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "• Building DMG…"
./Scripts/make_dmg.sh "$APP"
codesign --force --timestamp --sign "$ID" dist/SermonTrim.dmg

echo "• Notarizing DMG…"
xcrun notarytool submit dist/SermonTrim.dmg --keychain-profile "$PROFILE" --wait | tee "$WORK/dmg.log"
grep -q "status: Accepted" "$WORK/dmg.log" || { echo "Notarization of the DMG was not accepted."; exit 1; }
xcrun stapler staple dist/SermonTrim.dmg
xcrun stapler validate dist/SermonTrim.dmg
spctl -a -vv -t install dist/SermonTrim.dmg
spctl -a -vv "$APP"
echo "Signed, notarized and stapled: dist/SermonTrim.dmg"
