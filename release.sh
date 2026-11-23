#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, staple and package Magic Rec Flag
# for distribution with NO Gatekeeper warning (no `xattr` step for users).
#
# ---------------------------------------------------------------------------
# ONE-TIME SETUP (needs a paid Apple Developer Program membership):
#
#   1. In Xcode → Settings → Accounts → Manage Certificates, create a
#      "Developer ID Application" certificate (lands in your login keychain).
#
#   2. Create an app-specific password at https://appleid.apple.com
#      (Sign-In & Security → App-Specific Passwords), then store notary creds:
#
#        xcrun notarytool store-credentials "magicrecflag-notary" \
#          --apple-id "you@example.com" --team-id "YOURTEAMID"
#
#   3. Fill in TEAM_ID and SIGN_IDENTITY below (find the exact identity with:
#        security find-identity -v -p codesigning        ).
#
# Then just run:  ./release.sh
# ---------------------------------------------------------------------------

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
TEAM_ID="${TEAM_ID:-XXXXXXXXXX}"                                   # your 10-char Apple Team ID
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Luca Ungaro ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-magicrecflag-notary}"           # name used in store-credentials

PROJECT="MagicRecFlag.xcodeproj"
SCHEME="Magic Rec Flag"
APP_NAME="Magic Rec Flag.app"
ENTITLEMENTS="MagicRecFlag/MagicRecFlag.entitlements"
ARCHS="arm64 x86_64"                                             # universal

# ── Derived paths ───────────────────────────────────────────────────────────
cd "$(dirname "$0")"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/$APP_NAME"
VERSION="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$PROJECT/project.pbxproj" | head -1)"
VERSION="${VERSION:-1.0}"
OUT_ZIP="build/Magic-Rec-Flag-v${VERSION}-macOS.zip"
NOTARIZE_ZIP="build/notarize-upload.zip"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

# ── Preflight ───────────────────────────────────────────────────────────────
step "Preflight"
if [[ "$TEAM_ID" == "XXXXXXXXXX" ]]; then
  echo "ERROR: edit release.sh and set TEAM_ID (and SIGN_IDENTITY if needed)." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "ERROR: signing identity not found in keychain:" >&2
  echo "       $SIGN_IDENTITY" >&2
  echo "       Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi
echo "Version   : $VERSION"
echo "Identity  : $SIGN_IDENTITY"
echo "Notary    : $NOTARY_PROFILE"

# ── 1. Build (Release, universal, Hardened Runtime on) ──────────────────────
step "Building $SCHEME (Release, $ARCHS)"
rm -rf "$DERIVED"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  build | grep -E "(error:|warning: .*\.swift|BUILD SUCCEEDED|BUILD FAILED)" || true
[[ -d "$APP" ]] || { echo "ERROR: build did not produce $APP" >&2; exit 1; }

# ── 2. Sign with Developer ID + Hardened Runtime + entitlements ─────────────
# The app bundles no nested frameworks or helpers (DeckLink/NDI are loaded at
# run time from the system), so a single signature on the .app is enough.
step "Code signing (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Signature OK"

# ── 3. Notarize ─────────────────────────────────────────────────────────────
step "Notarizing (uploads to Apple, waits for result)"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# ── 4. Staple the ticket onto the app ───────────────────────────────────────
step "Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# Gatekeeper's own verdict (should say: accepted, source=Notarized Developer ID)
spctl --assess --type execute --verbose=4 "$APP" || true

# ── 5. Package the stapled app for distribution ─────────────────────────────
step "Packaging $OUT_ZIP"
rm -f "$OUT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT_ZIP"
rm -f "$NOTARIZE_ZIP"

printf '\n\033[1;32m✓ Release ready:\033[0m %s\n' "$(pwd)/$OUT_ZIP"
echo "  Universal, signed with Developer ID, notarized and stapled —"
echo "  downloaders can open it directly, no xattr / right-click needed."
