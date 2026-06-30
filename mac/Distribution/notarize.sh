#!/usr/bin/env bash
# Build, sign, notarize and package "nudisco Broadcaster" as a DMG for download
# from a website. Run on a Mac with Xcode + xcodegen and a Developer ID.
#
# One-time setup:
#   1) Have a "Developer ID Application" certificate in your login keychain.
#   2) Create a notarytool credential profile:
#        xcrun notarytool store-credentials nudisco-notary \
#          --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-pw>
#   3) export TEAM_ID, DEV_ID_APP, NOTARY_PROFILE (or edit the defaults below).
#
# Then:  ./Distribution/notarize.sh
set -euo pipefail

TEAM_ID="${TEAM_ID:-ABCDE12345}"
DEV_ID_APP="${DEV_ID_APP:-Developer ID Application: Your Name ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nudisco-notary}"
SCHEME="NudiscoBroadcaster"
VOL_NAME="nudisco Broadcaster"

cd "$(dirname "$0")/.."          # -> mac/

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building universal (arm64 + x86_64), Developer ID signed, hardened runtime"
DERIVED="build"
xcodebuild \
  -project NudiscoBroadcaster.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEV_ID_APP" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build
# Xcode signs the .app AND the embedded WebRTC.framework with the hardened runtime
# (ENABLE_HARDENED_RUNTIME=YES + Nudisco.entitlements come from project.yml).

APP="$DERIVED/Build/Products/Release/$SCHEME.app"
[ -d "$APP" ] || { echo "build product not found at $APP"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Packaging DMG"
DIST="dist"; mkdir -p "$DIST"
DMG="$DIST/nudisco-broadcaster.dmg"
rm -f "$DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$DEV_ID_APP" "$DMG"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP" || true

echo "==> Done: $DMG"
echo "    Upload this DMG to your site. Gatekeeper will accept it on any Mac."
