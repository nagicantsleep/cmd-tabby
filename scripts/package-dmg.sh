#!/bin/zsh
set -euo pipefail

# Packages dist/Tabby.app into a distributable DMG at dist/Tabby-<version>.dmg.
# The DMG holds Tabby.app plus an /Applications symlink for drag-to-install.
#
# Notarization (optional) runs when APPSTORE_API_KEY_ID / APPSTORE_API_ISSUER_ID
# / APPSTORE_API_PRIVATE_KEY (path to the .p8) are set. It notarizes and staples
# both the app and the DMG so it opens cleanly on other Macs.

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

# Notarize a file (.zip or .dmg) and, when given a bundle to staple, attach the
# ticket to that bundle; otherwise staple the notarized file itself.
submit_for_notarization() {
  local artifact="$1" staple_target="$2"
  xcrun notarytool submit "$artifact" \
    --key "$APPSTORE_API_PRIVATE_KEY" \
    --key-id "$APPSTORE_API_KEY_ID" \
    --issuer "$APPSTORE_API_ISSUER_ID" \
    --wait
  xcrun stapler staple "$staple_target"
}

if [[ -n "${APPSTORE_API_KEY_ID:-}" && -n "${APPSTORE_API_ISSUER_ID:-}" && -n "${APPSTORE_API_PRIVATE_KEY:-}" ]]; then
  echo "Notarizing Tabby.app…"
  # notarytool needs a zip archive for a bundle target; staple the app itself.
  ZIP="$ROOT/dist/Tabby-notarize.zip"
  ditto -c -k --keepParent "$STAGE/Tabby.app" "$ZIP"
  submit_for_notarization "$ZIP" "$STAGE/Tabby.app"
  rm -f "$ZIP"
  NOTARIZED=1
else
  echo "Skipping notarization (APPSTORE_API_* not set)."
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
