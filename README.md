# Tabby — a window-level ⌘-Tab switcher for macOS

Tabby replaces the macOS app switcher with a **window-level** switcher. Instead of
one tile per *app*, it shows one tile per *window*, each with a live preview, so
you can jump straight to the exact window you want — including several windows of
the same app.

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

## Features

- **Window-level switching** — every window of every app is its own tile, not just
  the frontmost window of each app.
- **Live previews** via ScreenCaptureKit, with three modes:
  *Window preview*, *Blurred preview*, and *Icon only*.
- **Stable grid layout** — windows keep their slot and the highlight moves, so the
  grid never reflows under your cursor.
- **Per-window actions** on each tile's header: **Quit**, **Close**, **Minimize**
  and **Maximize (Zoom)**.
- **Click a tile** to switch straight to that window.
- **Stays open while ⌘ is held** after you run an action, so you can act on several
  windows in one session. Releasing ⌘ then just dismisses the grid.
- **Exact same-app disambiguation** — two maximized windows of the same app (which
  share a frame and often a title) are told apart via the Accessibility
  `AXUIElement ↔ CGWindowID` mapping, so the second window is reachable too.

## Requirements

- macOS 13 (Ventura) or later.
- Three permissions, granted on first launch (see below).

## Install

1. Download `Tabby-<version>.dmg` from the [Releases](../../releases) page.
2. Open the DMG and drag **Tabby** into **Applications**.
3. Launch Tabby and grant the three permissions it asks for, then relaunch.

> If you built the DMG yourself without notarization, Gatekeeper may warn on first
> launch. Right-click the app → **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/Tabby.app`.

## Permissions

Tabby needs all three; the in-app **Permissions…** window links to each pane.

| Permission | Why |
|---|---|
| **Input Monitoring** | To observe ⌘-Tab / Esc without taking over the keyboard. |
| **Accessibility** | To raise, minimize, close, zoom or quit the window you pick. |
| **Screen Recording** | To capture the window previews shown in the grid. |

Grants are tied to the app's signing identity. Tabby is signed with a pinned
Developer ID, so grants persist across upgrades.

## Usage

| Action | Key / gesture |
|---|---|
| Open the switcher | hold **⌘** and press **Tab** |
| Move the highlight | **Tab** / **⇧-Tab** while holding ⌘ |
| Switch to a window | click its tile, or release **⌘** |
| Quit / Close / Minimize / Maximize a window | click the buttons in a tile's header |
| Cancel | **Esc** |

The menu-bar icon lets you pick the preview mode and open the permissions window.

## Build from source

```sh
git clone https://github.com/<you>/cmd-tabby.git
cd cmd-tabby
./build-app.sh          # builds, signs, and opens dist/Tabby.app
```

`build-app.sh` signs with a pinned Developer ID certificate so that TCC grants
survive rebuilds. Override the identity with:

```sh
TABBY_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" ./build-app.sh
```

Set `TABBY_NO_OPEN=1` to skip launching the app after building (useful in CI).

## Packaging a DMG

```sh
./scripts/package-dmg.sh          # -> dist/Tabby.dmg
```

The DMG contains `Tabby.app` and an `/Applications` symlink for drag-to-install.

## Releasing (CI)

Releases are produced by GitHub Actions (`.github/workflows/release.yml`). Push a
tag and the workflow builds, signs, notarizes, staples, and attaches a DMG to the
GitHub Release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

### Required repository secrets

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | Base64 of your **Developer ID Application** certificate exported as `.p12`. |
| `MACOS_CERT_PASSWORD` | Password you set when exporting the `.p12`. |
| `MACOS_CERT_IDENTITY` | (Optional) Exact identity name, e.g. `Developer ID Application: Your Name (TEAMID)`. If omitted, the workflow auto-detects any Developer ID cert. |
| `KEYCHAIN_PASSWORD` | Any random string; used for the temporary CI keychain. |
| `APPLE_TEAM_ID` | Your 10-character Team ID (here `L9UU4DV575`). |
| `APPSTORE_API_KEY_ID` | App Store Connect API **Key ID**. |
| `APPSTORE_API_ISSUER_ID` | App Store Connect API **Issuer ID**. |
| `APPSTORE_API_PRIVATE_KEY` | Contents of the App Store Connect API **`.p8`** key file. |

#### Creating the App Store Connect API key (for notarization)

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com).
2. Go to **Users and Access → Integrations → App Store Connect API** (or the
   **Keys** tab, depending on your account).
3. Click **+** to create a key. Name it e.g. `Tabby Notarization`, and give it the
   **Developer** role (a "team key").
4. Copy the **Key ID** (10 characters) and the **Issuer ID** (a UUID shown above
   the key list).
5. Click **Download API Key** — you get a file named `AuthKey_<KEYID>.p8`. You can
   only download it once; store it safely.
6. Add the secrets:

   ```sh
   gh secret set APPSTORE_API_KEY_ID      --body "<Key ID>"
   gh secret set APPSTORE_API_ISSUER_ID   --body "<Issuer ID>"
   gh secret set APPSTORE_API_PRIVATE_KEY < AuthKey_<KEYID>.p8
   ```

#### Exporting the signing certificate as `.p12`

```sh
# In Keychain Access: My Certificates → "Developer ID Application: …" →
# right-click → Export… → save as DeveloperID.p12 with a password.

base64 -i DeveloperID.p12 | pbcopy
gh secret set MACOS_CERT_P12      --body "$(base64 -i DeveloperID.p12)"
gh secret set MACOS_CERT_PASSWORD --body "<p12 password>"
gh secret set MACOS_CERT_IDENTITY --body "Developer ID Application: Your Name (TEAMID)"
gh secret set KEYCHAIN_PASSWORD   --body "$(openssl rand -hex 16)"
gh secret set APPLE_TEAM_ID       --body "L9UU4DV575"
```

If the notarization secrets are absent, the workflow still builds a DMG and
attaches it to the release, but the app will not be notarized.

## License

MIT — see [LICENSE](LICENSE).
