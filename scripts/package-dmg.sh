#!/bin/zsh
set -euo pipefail

# Packages dist/Tabby.app into a distributable DMG at dist/Tabby-<version>.dmg.
# The DMG holds Tabby.app plus an /Applications symlink for drag-to-install.
#
# Notarization (optional) runs when credentials are present. Either credential
# style works:
#   * App Store Connect API key:
#       APPSTORE_API_KEY_ID, APPSTORE_API_ISSUER_ID, APPSTORE_API_PRIVATE_KEY
#   * Apple ID + app-specific password:
#       APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
# It notarizes and staples both the app and the DMG so it opens cleanly on
# other Macs.

ROOT="${0:A:h:h}"
cd "$ROOT"

APP="$ROOT/dist/Tabby.app"
[[ -d "$APP" ]] || { echo "ERROR: $APP not found — run ./build-app.sh first." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
VOLNAME="Tabby"
DMG="$ROOT/dist/Tabby-${VERSION}.dmg"
STAGE="$ROOT/dist/dmg-stage"

echo "Packaging Tabby ${VERSION} -> ${DMG}"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Tabby.app"
ln -s /Applications "$STAGE/Applications"

# Decide which credential style to use. Returns the notarytool auth args on
# stdout (one per line) and 0 when credentials are available.
notary_auth_args() {
  if [[ -n "${APPSTORE_API_KEY_ID:-}" && -n "${APPSTORE_API_ISSUER_ID:-}" && -n "${APPSTORE_API_PRIVATE_KEY:-}" ]]; then
    printf '%s\n' "--key" "$APPSTORE_API_PRIVATE_KEY" "--key-id" "$APPSTORE_API_KEY_ID" "--issuer" "$APPSTORE_API_ISSUER_ID"
    return 0
  fi
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    printf '%s\n' "--apple-id" "$APPLE_ID" "--team-id" "$APPLE_TEAM_ID" "--password" "$APPLE_APP_PASSWORD"
    return 0
  fi
  return 1
}

# Notarize a file (.zip or .dmg) and, when given a bundle to staple, attach the
# ticket to that bundle; otherwise staple the notarized file itself.
submit_for_notarization() {
  local artifact="$1" staple_target="$2"
  local -a auth
  auth=("${(@f)$(notary_auth_args)}")
  xcrun notarytool submit "$artifact" "${auth[@]}" --wait
  xcrun stapler staple "$staple_target"
}

if notary_auth_args >/dev/null; then
  echo "Notarizing Tabby.app…"
  # notarytool needs a zip archive for a bundle target; staple the app itself.
  ZIP="$ROOT/dist/Tabby-notarize.zip"
  ditto -c -k --keepParent "$STAGE/Tabby.app" "$ZIP"
  submit_for_notarization "$ZIP" "$STAGE/Tabby.app"
  rm -f "$ZIP"
  NOTARIZED=1
else
  echo "Skipping notarization (no notary credentials set)."
  NOTARIZED=0
fi

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ "${NOTARIZED:-0}" == "1" ]]; then
  echo "Notarizing DMG…"
  submit_for_notarization "$DMG" "$DMG"
fi

echo "Verifying…"
codesign --verify --verbose=2 "$APP"
if [[ "${NOTARIZED:-0}" == "1" ]]; then
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  xcrun stapler validate "$APP"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "Done: $DMG"
