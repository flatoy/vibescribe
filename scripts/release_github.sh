#!/usr/bin/env bash
# Builds and verifies the direct-download release of VibeScribe.
#
#   scripts/release_github.sh   build dist/VibeScribe.app and dist/VibeScribe.dmg
#
# The app is ad-hoc signed and not notarized, so on first launch macOS asks people to allow it
# in System Settings > Privacy & Security (see the README). Publish the DMG as a GitHub release:
#   gh release create v<version> dist/VibeScribe.dmg --title "VibeScribe <version>" --notes-file <notes>
# Keep the asset name VibeScribe.dmg: the README and website link to
# https://github.com/flatoy/vibescribe/releases/latest/download/VibeScribe.dmg
#
# Overridable environment (defaults in brackets):
#   SCRATCH_PATH  [.build-dmg]  SwiftPM scratch path
#   DIST_DIR      [dist]
#
# Version and bundle ID come from version.env.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

SCRATCH_PATH=${SCRATCH_PATH:-$ROOT/.build-dmg}
DIST_DIR=${DIST_DIR:-$ROOT/dist}

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok() { printf '  %sok%s  %s\n' "$GREEN" "$RESET" "$*"; }
fail() { printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vibescribe-release.XXXXXX")
MOUNT="$WORK_DIR/mount"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
step "Preflight"

for tool in codesign hdiutil ditto lipo shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found. Install the Xcode Command Line Tools (xcode-select --install)."
done
ok "build tools present"

[[ -f "$ROOT/version.env" ]] || fail "version.env is missing."
# shellcheck source=/dev/null
source "$ROOT/version.env"
APP_NAME=${APP_NAME:-VibeScribe}
[[ -n "${MARKETING_VERSION:-}" && -n "${BUILD_NUMBER:-}" ]] || fail "MARKETING_VERSION and BUILD_NUMBER must be set in version.env."
ok "version.env: $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER), ${BUNDLE_ID:-}"

# ---------------------------------------------------------------------------
step "Build $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER)"

APP="$DIST_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME.dmg"
mkdir -p "$DIST_DIR"
rm -rf "$APP" "$DMG"

env DISTRIBUTION= SIGNING_MODE= APP_IDENTITY= APP_ENTITLEMENTS= \
  ARCHES=arm64 \
  SCRATCH_PATH="$SCRATCH_PATH" \
  OUTPUT_DIR="$DIST_DIR" \
  bash "$ROOT/package_app.sh" release
[[ -d "$APP" ]] || fail "package_app.sh did not produce $APP."

# ---------------------------------------------------------------------------
step "Verify the app"

codesign --verify --deep --strict "$APP" 2>/dev/null || fail "Signature verification failed for $APP."
codesign -dv "$APP" 2>&1 | grep -qx "Signature=adhoc" || fail "$APP is not ad-hoc signed."
ok "ad-hoc signed"

ARCHS=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
[[ "$ARCHS" == "arm64" ]] || fail "Expected an arm64 executable, got: $ARCHS"
ok "executable: $ARCHS"

# ---------------------------------------------------------------------------
step "Create $(basename "$DMG")"

STAGING="$WORK_DIR/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -format UDZO -ov "$DMG"

mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
[[ -L "$MOUNT/Applications" ]] || fail "$DMG has no Applications shortcut."
codesign --verify --deep --strict "$MOUNT/$APP_NAME.app" 2>/dev/null || fail "The app inside $DMG fails signature verification."
hdiutil detach -quiet "$MOUNT"
ok "$DMG: $APP_NAME.app verifies, Applications shortcut present"

step "Done"
echo "  $DMG"
echo "  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
