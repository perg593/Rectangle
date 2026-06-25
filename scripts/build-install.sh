#!/bin/bash
# build-install.sh — build Chiva, sign it with the STABLE "Divvy2 Dev" identity,
# and install it to ~/Applications/Divvy2 so the Accessibility grant survives rebuilds.
#
# Run scripts/dev-signing-setup.sh once first to create the identity.
# Env overrides: IDENTITY (default "Divvy2 Dev"), CONFIG (default Release), DEST.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-Divvy2 Dev}"
CONFIG="${CONFIG:-Release}"
DEST="${DEST:-$HOME/Applications/Divvy2}"
DD="/tmp/divvy2-dd"
PW_FILE="$HOME/.config/divvy2/signing-kc.pw"
KC="$HOME/Library/Keychains/divvy2-signing.keychain-db"

# If the identity lives in the dedicated dev keychain, unlock it (no-op for login keychain).
[[ -f "$PW_FILE" && -f "$KC" ]] && security unlock-keychain -p "$(cat "$PW_FILE")" "$KC" 2>/dev/null || true

if ! security find-identity 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✗ signing identity '$IDENTITY' not found — run scripts/dev-signing-setup.sh first." >&2
  exit 1
fi

echo "→ building ($CONFIG)…"
xcodebuild -project Rectangle.xcodeproj -scheme Rectangle -configuration "$CONFIG" \
  -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES build \
  > /tmp/divvy2-build.log 2>&1 || { echo "✗ build failed — see /tmp/divvy2-build.log" >&2; tail -20 /tmp/divvy2-build.log; exit 1; }

PRODUCTS="$DD/Build/Products/$CONFIG"
APP="$PRODUCTS/Chiva.app"

# Re-sign the whole bundle deepest-first with our identity. Necessary because embedded
# Sparkle.framework ships with a vendor Team ID; a mismatch makes dyld refuse to load it.
echo "→ re-signing nested code + app with '$IDENTITY'…"
# NOTE: no --options runtime. Hardened runtime turns on Library Validation, which
# rejects the embedded Sparkle.framework (self-signed identity has no Team ID), so the
# app fails to launch with "different Team IDs". Plain signing keeps it loadable.
sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$1"; }
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for n in "$SPK"/XPCServices/*.xpc "$SPK"/Autoupdate "$SPK"/Updater.app; do [[ -e "$n" ]] && sign "$n"; done
for fw in "$APP"/Contents/Frameworks/*.framework; do [[ -e "$fw" ]] && sign "$fw"; done
sign "$APP"
codesign --verify --deep --strict "$APP" && echo "  ✓ signature valid"
codesign -dv "$APP" 2>&1 | grep -iE "Authority|Identifier=" | sed 's/^/  /'

echo "→ installing to $DEST…"
osascript -e 'quit app "Chiva"' 2>/dev/null || true
pkill -x "Chiva" 2>/dev/null || true; sleep 1
mkdir -p "$DEST"
ditto "$APP" "$DEST/Chiva.app"
[[ -e "$PRODUCTS/Divvy2SpikeHelper.app" ]] && ditto "$PRODUCTS/Divvy2SpikeHelper.app" "$DEST/Divvy2SpikeHelper.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST/Chiva.app" 2>/dev/null || true
"$LSREGISTER" -f "$DEST/Divvy2SpikeHelper.app" 2>/dev/null || true

echo "→ launching…"
open "$DEST/Chiva.app"
echo "✓ done. If this is the first build with '$IDENTITY', grant Accessibility once"
echo "  (System Settings ▸ Privacy & Security ▸ Accessibility ▸ + ▸ $DEST/Chiva.app)."
echo "  After that, the grant persists across rebuilds (stable designated requirement)."
