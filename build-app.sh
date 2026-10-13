#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
cd "$ROOT"

# Signing identity: override with TABBY_SIGN_IDENTITY, else default to the
# pinned Developer ID cert. A STABLE, pinned identity is required: macOS TCC
# stores a code requirement at grant time and only matches a binary whose
# Designated Requirement satisfies it. Switching certs (e.g. Developer ID ->
# Apple Development) changes the DR (leaf CN), so existing Input Monitoring /
# Accessibility / Screen Recording grants stop matching and must be re-granted.
# Ad-hoc signing is worst of all: grants key off the binary cdhash, which
# changes on every build, so every rebuild silently loses every grant.
PINNED_IDENTITY="Developer ID Application: NeoX ASIA K.K (L9UU4DV575)"

# Notarization requires a secure timestamp; local builds skip it so codesign
# never blocks on OCSP/CRL. Set TABBY_TIMESTAMP=1 in CI.
TIMESTAMP_ARG="--timestamp=none"
if [[ "${TABBY_TIMESTAMP:-}" == "1" ]]; then
  TIMESTAMP_ARG="--timestamp"
fi

IDENTITY="${TABBY_SIGN_IDENTITY:-$PINNED_IDENTITY}"
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  # Fall back to any Developer ID Application cert first (distributable and
  # TCC-stable), then any Apple Development cert.
  FALLBACK="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -n 1)"
  if [[ -z "$FALLBACK" ]]; then
    FALLBACK="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -n 1)"
  fi
  if [[ -n "$FALLBACK" && "$FALLBACK" != "$IDENTITY" ]]; then
    echo "WARNING: '$IDENTITY' not found, falling back to '$FALLBACK'." >&2
    IDENTITY="$FALLBACK"
  fi
fi

# macOS ships no `timeout`; codesign can hang on network OCSP/CRL checks.
sign_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs )); then
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    (( waited++ ))
  done
  wait "$pid"
}

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Tabby.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Tabby" "$APP/Contents/MacOS/Tabby"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  # --options runtime (hardened runtime) is required for notarization.
  if ! sign_with_timeout 120 codesign --force --options runtime --sign "$IDENTITY" "$TIMESTAMP_ARG" "$APP"; then
    echo "ERROR: codesign failed or timed out for: $IDENTITY" >&2
    echo "       Try another identity, e.g." >&2
    echo "       TABBY_SIGN_IDENTITY=\"Apple Development: ...\" ./build-app.sh" >&2
    exit 1
  fi
else
  echo "WARNING: no signing identity found — falling back to ad-hoc."
  echo "         TCC permissions will NOT persist across rebuilds."
  codesign --force --options runtime --sign - "$APP"
fi

codesign --verify --verbose=2 "$APP"
echo "Team: $(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -z "${TABBY_NO_OPEN:-}" ]]; then
  open "$APP"
fi
