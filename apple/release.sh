#!/bin/zsh
# Build the macOS app for distribution: Release configuration, Developer ID
# signature, hardened runtime, notarization, and a stapled DMG.
#
#   apple/release.sh <version> <build-number>
#
# Needs a "Developer ID Application" identity in an unlocked keychain, and for
# the notary submissions an App Store Connect API key (team-scoped, Developer
# role — no Apple ID credential involved):
#
#   APPLE_TEAM_ID     the ten-character team id on the certificate
#   NOTARY_KEY_FILE   path to the downloaded AuthKey_<id>.p8
#   NOTARY_KEY_ID     the key id
#   NOTARY_ISSUER_ID  the issuer id shown on the keys page
#
# The DMG lands at apple/build-mac/LookoutMarine-<version>-macos-arm64.dmg.
# The app is notarized and stapled before the DMG is built, and the DMG is
# notarized and stapled itself, so both the download and the copy dragged to
# /Applications open with no network — a boat may well have none.
set -euo pipefail

REPO="${0:A:h:h}"
VERSION="${1:?usage: release.sh <version> <build-number>}"
BUILD="${2:?usage: release.sh <version> <build-number>}"
: "${APPLE_TEAM_ID:?}" "${NOTARY_KEY_FILE:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"

DERIVED="$REPO/apple/build-mac"
APP="$DERIVED/Build/Products/Release/LookoutMarine.app"
DMG="$DERIVED/LookoutMarine-$VERSION-macos-arm64.dmg"
NOTARY=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

# Submit one file, wait for the verdict, and fail with Apple's own log when it
# is anything but Accepted. The status is read from the JSON output rather
# than the exit code, which does not carry the verdict.
notarize() {
  local out id verdict
  out=$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --output-format json)
  id=$(echo "$out" | plutil -extract id raw -o - -)
  verdict=$(echo "$out" | plutil -extract status raw -o - -)
  echo "notary: ${1:t} $verdict ($id)"
  if [[ "$verdict" != "Accepted" ]]; then
    xcrun notarytool log "$id" "${NOTARY[@]}" >&2
    return 1
  fi
}

# Notarization requires a Developer ID signature, the hardened runtime and a
# secure timestamp. Manual style so the build takes the imported identity
# instead of asking Xcode to manage one; the name resolves by prefix from the
# keychain search list.
echo "==> xcodebuild Release ($VERSION, build $BUILD)"
xcodebuild -project "$REPO/apple/LookoutMarine.xcodeproj" -scheme LookoutMarine \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  build

codesign --verify --strict --deep "$APP"

echo "==> notarize the app"
ZIP="$DERIVED/LookoutMarine.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"

# The usual drag-to-Applications layout: the app beside an /Applications
# symlink on a compressed read-only image.
echo "==> package the dmg"
STAGE="$DERIVED/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/LookoutMarine.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
# hdiutil on a busy machine sometimes fails to detach its temporary image;
# retry rather than lose a finished notarization to it.
for attempt in 1 2 3; do
  if hdiutil create -volname "Lookout Marine" -srcfolder "$STAGE" -format UDZO -ov "$DMG"; then
    break
  fi
  [[ "$attempt" == 3 ]] && exit 1
  sleep 5
done

# The DMG carries its own signature and ticket: Gatekeeper assesses the
# download itself, not only the app inside it.
codesign --sign "Developer ID Application" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type execute -v "$APP"
echo "==> $DMG"
