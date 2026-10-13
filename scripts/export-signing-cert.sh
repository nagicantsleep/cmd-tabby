#!/bin/zsh
set -euo pipefail

# Exports the Developer ID signing identity (certificate + private key) to a
# .p12, then uploads it to the GitHub repo as the secrets the release workflow
# needs: MACOS_CERT_P12, MACOS_CERT_PASSWORD, MACOS_CERT_IDENTITY,
# KEYCHAIN_PASSWORD.
#
# The .p12 password is read interactively (never echoed, never logged) and is
# used only for the local export plus the MACOS_CERT_PASSWORD secret.
#
# Usage:
#   ./scripts/export-signing-cert.sh
#   IDENTITY="Developer ID Application: Other Name (TEAMID)" ./scripts/export-signing-cert.sh

ROOT="${0:A:h:h}"
cd "$ROOT"

DEFAULT_IDENTITY="Developer ID Application: NeoX ASIA K.K (L9UU4DV575)"
IDENTITY="${IDENTITY:-$DEFAULT_IDENTITY}"
OUT="${OUT:-$HOME/Downloads/Tabby-DeveloperID.p12}"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "ERROR: identity not found in the keychain:" >&2
  echo "       $IDENTITY" >&2
  echo "Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

echo "Exporting: $IDENTITY"
echo "Output:    $OUT"
echo
echo "You will be asked for TWO passwords:"
echo "  1. macOS may ask to allow access to the key (click Always Allow)."
echo "  2. A NEW password to protect the .p12 — remember it, it becomes MACOS_CERT_PASSWORD."
echo

read -r -s "P12PASS?Enter a new password for the .p12: "; echo
read -r -s "P12PASS2?Confirm the password: "; echo
if [[ -z "$P12PASS" ]]; then
  echo "ERROR: the .p12 password must not be empty — an empty MACOS_CERT_PASSWORD" >&2
  echo "       breaks the CI keychain import. Run the script again." >&2
  exit 1
fi
if [[ "$P12PASS" != "$P12PASS2" ]]; then
  echo "ERROR: passwords do not match." >&2
  exit 1
fi

# Write the public cert to a temp PEM so `security export` can filter to exactly
# this identity (otherwise it exports every identity in the keychain).
TMPCERT="$(mktemp -t tabby-cert)"
trap 'rm -f "$TMPCERT"' EXIT
security find-certificate -c "$IDENTITY" -p > "$TMPCERT"

# Resolve the login keychain robustly: take only the first line and strip the
# surrounding whitespace/quotes `security` prints.
KEYCHAIN="$(security default-keychain | head -1 | tr -d ' "' )"
[[ -n "$KEYCHAIN" ]] || { echo "ERROR: could not determine the default keychain." >&2; exit 1; }

rm -f "$OUT"
security export -k "$KEYCHAIN" \
  -t identities -f pkcs12 -P "$P12PASS" -o "$OUT" "$TMPCERT"

if [[ ! -s "$OUT" ]]; then
  echo "ERROR: export produced no file. The key may have been denied access." >&2
  exit 1
fi

echo "Exported: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"

# Upload secrets. Pipe via stdin so no secret appears in the process list.
base64 -i "$OUT" | gh secret set MACOS_CERT_P12
printf '%s' "$P12PASS" | gh secret set MACOS_CERT_PASSWORD
printf '%s' "$IDENTITY" | gh secret set MACOS_CERT_IDENTITY
openssl rand -hex 16 | tr -d '\n' | gh secret set KEYCHAIN_PASSWORD

echo
echo "Secrets uploaded. Current repo secrets:"
gh secret list

echo
echo "Done. You can delete the .p12 file if you no longer need it:"
echo "  rm '$OUT'"
