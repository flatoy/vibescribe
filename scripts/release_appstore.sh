#!/usr/bin/env bash
# Builds, signs, packages and verifies the Mac App Store release of VibeScribe.
#
#   scripts/release_appstore.sh            build dist/VibeScribe.app and dist/VibeScribe-<version>-<build>.pkg
#   scripts/release_appstore.sh --upload   same, then upload the package to App Store Connect with asc
#
# Overridable environment (defaults in brackets):
#   APP_IDENTITY          [Apple Distribution: Hello World AS (8S36PA5867)]
#   INSTALLER_IDENTITY    [3rd Party Mac Developer Installer: Hello World AS (8S36PA5867)]
#   PROVISIONING_PROFILE  [.signing/VibeScribe_Mac_App_Store.provisionprofile]
#   APP_ENTITLEMENTS      [appstore/VibeScribe.entitlements]
#   SCRATCH_PATH          [.build-mas]  SwiftPM scratch path
#   DIST_DIR              [dist]
#   ASC_APP_ID            [from appstore/app.env]  App Store Connect app ID, needed for --upload
#   SWIFT_BIN             [xcrun --find swift]  must be Apple's Swift, not a swift.org toolchain
#   ALLOW_DIRTY=1         let --upload run from a working tree with uncommitted changes
#   SKIP_URL_CHECK=1      let --upload run while the privacy/support/marketing URLs do not load
#
# Version and bundle ID come from version.env. See appstore/RELEASING.md.
set -euo pipefail

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_IDENTITY=${APP_IDENTITY:-"Apple Distribution: Hello World AS (8S36PA5867)"}
INSTALLER_IDENTITY=${INSTALLER_IDENTITY:-"3rd Party Mac Developer Installer: Hello World AS (8S36PA5867)"}
PROVISIONING_PROFILE=${PROVISIONING_PROFILE:-$ROOT/.signing/VibeScribe_Mac_App_Store.provisionprofile}
APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$ROOT/appstore/VibeScribe.entitlements}
SCRATCH_PATH=${SCRATCH_PATH:-$ROOT/.build-mas}
DIST_DIR=${DIST_DIR:-$ROOT/dist}
MIN_SDK_MAJOR=26 # App Store Connect requires apps built with the macOS 26 SDK or later.

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok() { printf '  %sok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$YELLOW" "$RESET" "$*"; }
skip() { printf '  --  %s\n' "$*"; }
fail() { printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vibescribe-release.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
# Top-level keys of a plist, one per line.
plist_keys() { plutil -p "$1" | sed -nE 's/^  "([^"]+)" => .*/\1/p' | sort; }
sha1_of_profile_certs() {
  local plist="$1" i=0 cert
  while cert=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$plist" 2>/dev/null); do
    base64 -D <<<"$cert" | shasum -a 1 | awk '{print toupper($1)}'
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
step "Preflight"

for tool in xcrun codesign productbuild pkgutil security plutil lipo otool iconutil sips curl python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found. Install the Xcode Command Line Tools (xcode-select --install)."
done
ok "build tools present"

# App Store builds use Apple's Swift (package_app.sh enforces this too), not a swift.org toolchain
# that may come first on PATH.
SWIFT_BIN=${SWIFT_BIN:-$(xcrun --find swift 2>/dev/null || true)}
[[ -n "$SWIFT_BIN" && -x "$SWIFT_BIN" ]] || fail "Could not find Apple's swift (xcrun --find swift). Install the Command Line Tools or Xcode."
SWIFT_VERSION_LINE=$("$SWIFT_BIN" --version 2>&1 | grep -m 1 'Swift version' || true)
[[ "$SWIFT_VERSION_LINE" == *"(swiftlang-"* ]] \
  || fail "$SWIFT_BIN is not Apple's Swift (${SWIFT_VERSION_LINE:-no version}). Select Xcode or the Command Line Tools with xcode-select, or set SWIFT_BIN."
ok "swift: ${SWIFT_VERSION_LINE#*Apple }, $SWIFT_BIN"

[[ -f "$ROOT/version.env" ]] || fail "version.env is missing."
# shellcheck source=/dev/null
source "$ROOT/version.env"
APP_NAME=${APP_NAME:-VibeScribe}
[[ -n "${BUNDLE_ID:-}" ]] || fail "BUNDLE_ID is not set in version.env."
[[ "${MARKETING_VERSION:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
  || fail "MARKETING_VERSION='${MARKETING_VERSION:-}' must be two or three dot-separated integers (e.g. 1.0.0)."
[[ "${BUILD_NUMBER:-}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
  || fail "BUILD_NUMBER='${BUILD_NUMBER:-}' must be up to three dot-separated integers (e.g. 6)."
[[ "${MACOS_MIN_VERSION:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "MACOS_MIN_VERSION is not set in version.env."
ok "version.env: $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER), $BUNDLE_ID, macOS $MACOS_MIN_VERSION+"

if [[ "$APP_IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
  TEAM_ID=${BASH_REMATCH[1]}
else
  fail "Could not read the team ID from APP_IDENTITY='$APP_IDENTITY'."
fi
[[ "$INSTALLER_IDENTITY" == *"($TEAM_ID)" ]] || fail "INSTALLER_IDENTITY is not for team $TEAM_ID."

CODESIGN_IDENTITIES=$(security find-identity -v -p codesigning)
[[ "$CODESIGN_IDENTITIES" == *"\"$APP_IDENTITY\""* ]] \
  || fail "Signing identity not found in the keychain: $APP_IDENTITY (security find-identity -v -p codesigning)."
ok "app signing identity: $APP_IDENTITY"
ALL_IDENTITIES=$(security find-identity -v)
[[ "$ALL_IDENTITIES" == *"\"$INSTALLER_IDENTITY\""* ]] \
  || fail "Installer identity not found in the keychain: $INSTALLER_IDENTITY (security find-identity -v)."
ok "installer identity:   $INSTALLER_IDENTITY"

[[ -f "$PROVISIONING_PROFILE" ]] || fail "Provisioning profile not found: $PROVISIONING_PROFILE"
PROFILE_PLIST="$WORK_DIR/profile.plist"
security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST" 2>/dev/null || fail "Could not decode $PROVISIONING_PROFILE."
PROFILE_NAME=$(plist_value "$PROFILE_PLIST" Name)
PROFILE_EXPIRY=$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")
PROFILE_APP_ID=$(plist_value "$PROFILE_PLIST" Entitlements:com.apple.application-identifier)
PROFILE_TEAM=$(plist_value "$PROFILE_PLIST" Entitlements:com.apple.developer.team-identifier)
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[[ "$PROFILE_EXPIRY" > "$NOW_UTC" ]] || fail "Provisioning profile '$PROFILE_NAME' expired on $PROFILE_EXPIRY."
SOON_UTC=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ)
[[ "$PROFILE_EXPIRY" > "$SOON_UTC" ]] || warn "provisioning profile expires soon ($PROFILE_EXPIRY)"
[[ "$PROFILE_APP_ID" == "$TEAM_ID.$BUNDLE_ID" ]] \
  || fail "Profile application identifier '$PROFILE_APP_ID' does not match $TEAM_ID.$BUNDLE_ID."
[[ "$PROFILE_TEAM" == "$TEAM_ID" ]] || fail "Profile team '$PROFILE_TEAM' does not match $TEAM_ID."
[[ "$(plutil -extract Platform xml1 -o - "$PROFILE_PLIST")" == *"<string>OSX</string>"* ]] \
  || fail "Profile '$PROFILE_NAME' is not a macOS profile."
if plist_value "$PROFILE_PLIST" ProvisionedDevices >/dev/null || plist_value "$PROFILE_PLIST" ProvisionsAllDevices >/dev/null; then
  fail "Profile '$PROFILE_NAME' is a development/Developer ID profile, not a Mac App Store distribution profile."
fi
IDENTITY_CERT_SHA1=$(security find-certificate -a -c "$APP_IDENTITY" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print toupper($3)}')
PROFILE_CERT_SHA1S=$(sha1_of_profile_certs "$PROFILE_PLIST")
CERT_IN_PROFILE=0
for sha in $IDENTITY_CERT_SHA1; do
  grep -qx "$sha" <<<"$PROFILE_CERT_SHA1S" && CERT_IN_PROFILE=1
done
[[ "$CERT_IN_PROFILE" == "1" ]] || fail "The '$APP_IDENTITY' certificate is not included in profile '$PROFILE_NAME'."
ok "profile '$PROFILE_NAME': $PROFILE_APP_ID, Mac App Store, expires $PROFILE_EXPIRY, includes the signing certificate"

[[ -f "$APP_ENTITLEMENTS" ]] || fail "Entitlements not found: $APP_ENTITLEMENTS"
plutil -lint "$APP_ENTITLEMENTS" >/dev/null || fail "$APP_ENTITLEMENTS is not a valid plist."
[[ "$(plist_value "$APP_ENTITLEMENTS" com.apple.security.app-sandbox)" == "true" ]] \
  || fail "$APP_ENTITLEMENTS must enable com.apple.security.app-sandbox."
for key in com.apple.application-identifier com.apple.developer.team-identifier com.apple.security.get-task-allow; do
  plist_value "$APP_ENTITLEMENTS" "$key" >/dev/null && fail "$APP_ENTITLEMENTS must not contain $key (it is merged in at sign time)."
done
ok "entitlements: $(plist_keys "$APP_ENTITLEMENTS" | tr '\n' ' ')"

if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
  DIRTY_NOTE="working tree has uncommitted changes; the build records GitCommit $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)-dirty"
  if [[ "$UPLOAD" == "1" && "${ALLOW_DIRTY:-0}" != "1" ]]; then
    fail "$DIRTY_NOTE. Commit first, so the uploaded build matches a commit, or set ALLOW_DIRTY=1."
  fi
  warn "$DIRTY_NOTE"
fi

# App Review opens the privacy policy and support URLs; a 404 is a rejection.
METADATA_DIR="$ROOT/appstore/metadata"
URL_PROBLEMS=0
check_url() {
  local label="$1" url="$2" code
  if [[ -z "$url" ]]; then
    warn "$label URL is not set in $METADATA_DIR"
    URL_PROBLEMS=1
    return
  fi
  code=$(curl -sSL --max-time 20 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
  if [[ "$code" == 2* ]]; then
    ok "$label URL: $url (HTTP $code)"
  else
    warn "$label URL does not load: $url (HTTP ${code:-no response})"
    URL_PROBLEMS=1
  fi
}
json_value() { [[ -f "$1" ]] && plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
PRIVACY_URL=$(json_value "$METADATA_DIR/app-info/en-US.json" privacyPolicyUrl)
check_url "privacy policy" "$PRIVACY_URL"
check_url "support" "$(json_value "$METADATA_DIR/version/$MARKETING_VERSION/en-US.json" supportUrl)"
MARKETING_URL=$(json_value "$METADATA_DIR/version/$MARKETING_VERSION/en-US.json" marketingUrl)
[[ -z "$MARKETING_URL" ]] || check_url "marketing" "$MARKETING_URL"
if [[ -n "$PRIVACY_URL" ]] && ! grep -rqF "\"$PRIVACY_URL\"" "$ROOT/Sources"; then
  warn "the app's privacy policy link (AppInfo.privacyPolicyURL) is not $PRIVACY_URL"
  URL_PROBLEMS=1
fi
if [[ "$URL_PROBLEMS" == "1" && "$UPLOAD" == "1" && "${SKIP_URL_CHECK:-0}" != "1" ]]; then
  fail "Publish docs/ (GitHub Pages) so the App Store URLs load before uploading, or set SKIP_URL_CHECK=1."
fi

ASC_APP_ID=${ASC_APP_ID:-}
if [[ -z "$ASC_APP_ID" && -f "$ROOT/appstore/app.env" ]]; then
  ASC_APP_ID=$(sed -nE 's/^[[:space:]]*ASC_APP_ID=["'\'']?([^"'\''[:space:]#]*).*/\1/p' "$ROOT/appstore/app.env" | tail -1)
fi
if [[ "$UPLOAD" == "1" ]]; then
  [[ "$ASC_APP_ID" =~ ^[0-9]+$ ]] \
    || fail "--upload needs the numeric App Store Connect app ID in ASC_APP_ID or appstore/app.env (got '${ASC_APP_ID}')."
  command -v asc >/dev/null 2>&1 || fail "--upload needs the asc CLI on PATH."
  ok "upload target: App Store Connect app $ASC_APP_ID"
  # App Store Connect rejects a build number that is not higher than every build already
  # uploaded for this version, failed or not; catch that before building and uploading.
  ASC_BUILDS="$WORK_DIR/asc-builds.json"
  asc builds list --app "$ASC_APP_ID" --platform MAC_OS --version "$MARKETING_VERSION" \
      --processing-state all --paginate --output json > "$ASC_BUILDS" \
    || fail "Could not list the existing builds of $MARKETING_VERSION with asc builds list."
  USED_BUILD_NUMBERS=$(python3 - "$ASC_BUILDS" "$BUILD_NUMBER" <<'PY'
import json, sys
def key(v):
    return [int(p) for p in v.split(".")] + [0] * (3 - v.count(".") - 1)
mine = key(sys.argv[2])
builds = json.load(open(sys.argv[1])).get("data") or []
used = [b["attributes"]["version"] for b in builds if b.get("attributes", {}).get("version")]
print(" ".join(sorted((v for v in used if key(v) >= mine), key=key)))
PY
) || fail "Could not read the asc builds list output."
  [[ -z "$USED_BUILD_NUMBERS" ]] \
    || fail "Version $MARKETING_VERSION already has build(s) $USED_BUILD_NUMBERS in App Store Connect. Raise BUILD_NUMBER in version.env above them."
  ok "build number $BUILD_NUMBER is higher than every uploaded build of $MARKETING_VERSION"
fi

# ---------------------------------------------------------------------------
step "Build $APP_NAME.app for the Mac App Store"

APP="$DIST_DIR/$APP_NAME.app"
PKG="$DIST_DIR/$APP_NAME-$MARKETING_VERSION-$BUILD_NUMBER.pkg"
DSYM_SOURCE="$SCRATCH_PATH/arm64-apple-macosx/release/$APP_NAME.dSYM"
DSYM="$DIST_DIR/$APP_NAME-$MARKETING_VERSION-$BUILD_NUMBER.dSYM"
mkdir -p "$DIST_DIR"
rm -rf "$APP" "$PKG" "$DSYM"

env DISTRIBUTION=appstore \
  SWIFT_BIN="$SWIFT_BIN" \
  SCRATCH_PATH="$SCRATCH_PATH" \
  OUTPUT_DIR="$DIST_DIR" \
  APP_IDENTITY="$APP_IDENTITY" \
  PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  APP_ENTITLEMENTS="$APP_ENTITLEMENTS" \
  TEAM_ID="$TEAM_ID" \
  SIGNING_MODE= ARCHES= \
  bash "$ROOT/package_app.sh" release
[[ -d "$APP" ]] || fail "package_app.sh did not produce $APP."

if [[ -d "$DSYM_SOURCE" ]]; then
  cp -R "$DSYM_SOURCE" "$DSYM"
fi

# ---------------------------------------------------------------------------
step "Package $(basename "$PKG")"

productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
[[ -f "$PKG" ]] || fail "productbuild did not produce $PKG."

# ---------------------------------------------------------------------------
step "Verify the app"

MAIN_EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP/Contents/Info.plist"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "Deep signature verification failed for $APP."
ok "codesign --verify --strict (including nested code)"

SIGNATURE_INFO=$(codesign -dvv "$APP" 2>&1)
grep -qx "Authority=$APP_IDENTITY" <<<"$SIGNATURE_INFO" || fail "$APP is not signed by $APP_IDENTITY."
grep -qx "TeamIdentifier=$TEAM_ID" <<<"$SIGNATURE_INFO" || fail "$APP has the wrong team identifier."
grep -qx "Identifier=$BUNDLE_ID" <<<"$SIGNATURE_INFO" || fail "$APP has the wrong signing identifier."
grep -q '^Timestamp=' <<<"$SIGNATURE_INFO" || fail "$APP signature has no secure timestamp."
RUNTIME_NOTE="without hardened runtime"
grep -q 'flags=.*runtime' <<<"$SIGNATURE_INFO" && RUNTIME_NOTE="hardened runtime"
ok "signed by '$APP_IDENTITY', team $TEAM_ID, identifier $BUNDLE_ID, timestamped, $RUNTIME_NOTE"

SIGNED_ENTITLEMENTS="$WORK_DIR/signed.entitlements"
codesign -d --entitlements - --xml "$APP" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null || fail "Could not read the signed entitlements."
echo "  codesign -d --entitlements:"
plutil -p "$SIGNED_ENTITLEMENTS" | sed 's/^/    /'
EXPECTED_KEYS=$( { plist_keys "$APP_ENTITLEMENTS"; printf '%s\n' com.apple.application-identifier com.apple.developer.team-identifier; } | sort -u)
[[ "$(plist_keys "$SIGNED_ENTITLEMENTS")" == "$EXPECTED_KEYS" ]] \
  || fail "Signed entitlements differ from $APP_ENTITLEMENTS plus the application/team identifiers."
for key in $(plist_keys "$APP_ENTITLEMENTS"); do
  [[ "$(plist_value "$SIGNED_ENTITLEMENTS" "$key")" == "$(plist_value "$APP_ENTITLEMENTS" "$key")" ]] \
    || fail "Signed entitlement $key differs from $APP_ENTITLEMENTS."
done
[[ "$(plist_value "$SIGNED_ENTITLEMENTS" com.apple.application-identifier)" == "$TEAM_ID.$BUNDLE_ID" ]] \
  || fail "Signed com.apple.application-identifier is not $TEAM_ID.$BUNDLE_ID."
[[ "$(plist_value "$SIGNED_ENTITLEMENTS" com.apple.developer.team-identifier)" == "$TEAM_ID" ]] \
  || fail "Signed com.apple.developer.team-identifier is not $TEAM_ID."
ok "entitlements = $(basename "$APP_ENTITLEMENTS") + application/team identifiers"

EMBEDDED_PROFILE="$APP/Contents/embedded.provisionprofile"
[[ -f "$EMBEDDED_PROFILE" ]] || fail "$EMBEDDED_PROFILE is missing."
cmp -s "$EMBEDDED_PROFILE" "$PROVISIONING_PROFILE" || fail "Embedded profile differs from $PROVISIONING_PROFILE."
EMBEDDED_PLIST="$WORK_DIR/embedded.plist"
security cms -D -i "$EMBEDDED_PROFILE" > "$EMBEDDED_PLIST" 2>/dev/null || fail "Could not decode the embedded profile."
for key in com.apple.application-identifier com.apple.developer.team-identifier; do
  [[ "$(plist_value "$EMBEDDED_PLIST" "Entitlements:$key")" == "$(plist_value "$SIGNED_ENTITLEMENTS" "$key")" ]] \
    || fail "Signed $key does not match the embedded profile."
done
codesign -d --extract-certificates="$WORK_DIR/signing-cert" "$APP" 2>/dev/null
LEAF_SHA1=$(shasum -a 1 "$WORK_DIR/signing-cert0" | awk '{print toupper($1)}')
grep -qx "$LEAF_SHA1" <<<"$(sha1_of_profile_certs "$EMBEDDED_PLIST")" \
  || fail "The app's signing certificate is not in the embedded profile."
ok "embedded.provisionprofile matches the signature (app ID, team, certificate)"

plutil -lint "$INFO_PLIST" | sed 's/^/  /'
expect_info() {
  local key="$1" expected="$2" actual
  actual=$(plist_value "$INFO_PLIST" "$key") || fail "Info.plist is missing $key."
  [[ -z "$expected" || "$actual" == "$expected" ]] || fail "Info.plist $key is '$actual', expected '$expected'."
  [[ -n "$actual" ]] || fail "Info.plist $key is empty."
}
expect_info CFBundleIdentifier "$BUNDLE_ID"
expect_info CFBundleExecutable "$APP_NAME"
expect_info CFBundleName ""
expect_info CFBundleShortVersionString "$MARKETING_VERSION"
expect_info CFBundleVersion "$BUILD_NUMBER"
expect_info CFBundlePackageType APPL
expect_info CFBundleInfoDictionaryVersion "6.0"
expect_info CFBundleSupportedPlatforms:0 MacOSX
expect_info CFBundleIconFile ""
expect_info LSMinimumSystemVersion "$MACOS_MIN_VERSION"
expect_info LSApplicationCategoryType ""
expect_info ITSAppUsesNonExemptEncryption false
expect_info NSHumanReadableCopyright ""
expect_info NSMicrophoneUsageDescription ""
for key in DTPlatformName DTPlatformVersion DTPlatformBuild DTSDKName DTSDKBuild DTCompiler DTXcode DTXcodeBuild BuildMachineOSBuild; do
  expect_info "$key" ""
done
expect_info DTPlatformName macosx
[[ "$(plist_value "$INFO_PLIST" DTXcode)" =~ ^[0-9]{4}$ ]] || fail "Info.plist DTXcode must be four digits."
[[ "$(plist_value "$INFO_PLIST" DTSDKName)" == macosx* ]] || fail "Info.plist DTSDKName must start with macosx."
ok "Info.plist keys: $(for k in CFBundleShortVersionString CFBundleVersion LSApplicationCategoryType DTSDKName DTSDKBuild DTXcode DTXcodeBuild BuildMachineOSBuild; do printf '%s=%s ' "$k" "$(plist_value "$INFO_PLIST" "$k")"; done)"

ICON_FILE=$(plist_value "$INFO_PLIST" CFBundleIconFile)
ICON_PATH="$APP/Contents/Resources/${ICON_FILE%.icns}.icns"
[[ -f "$ICON_PATH" ]] || fail "CFBundleIconFile points at a missing $ICON_PATH."
ICON_KIND=$(file -b "$ICON_PATH")
[[ "$ICON_KIND" == "Mac OS X icon"* ]] || fail "$ICON_PATH is not an ICNS file ($ICON_KIND)."
iconutil --convert iconset --output "$WORK_DIR/check.iconset" "$ICON_PATH"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
            256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  size=$(sips -g pixelWidth "$WORK_DIR/check.iconset/${spec#*:}.png" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  [[ "$size" == "${spec%%:*}" ]] || fail "$ICON_PATH has no ${spec#*:} (${spec%%:*} px) image."
done
ok "icon: $ICON_FILE.icns ($ICON_KIND) with every size from 16x16 to 512x512@2x"

ARCHS=$(lipo -archs "$MAIN_EXECUTABLE")
[[ "$ARCHS" == "arm64" ]] || fail "$MAIN_EXECUTABLE architectures are '$ARCHS', expected arm64."
BUILD_VERSION=$(otool -l "$MAIN_EXECUTABLE" | awk '/cmd LC_BUILD_VERSION/ {found=1} found && /minos/ {minos=$2} found && /sdk/ {print minos, $2; exit}')
BINARY_MINOS=${BUILD_VERSION%% *}
BINARY_SDK=${BUILD_VERSION##* }
[[ "$BINARY_MINOS" == "$MACOS_MIN_VERSION" ]] || fail "Binary minimum macOS is $BINARY_MINOS, Info.plist says $MACOS_MIN_VERSION."
(( ${BINARY_SDK%%.*} >= MIN_SDK_MAJOR )) || fail "Binary was built with the macOS $BINARY_SDK SDK; App Store Connect needs $MIN_SDK_MAJOR or later."
FOREIGN_RPATHS=$(otool -l "$MAIN_EXECUTABLE" | awk '/cmd LC_RPATH/ {getline; getline; print $2}' | grep -vE '^(/usr/lib/|/System/|@)' || true)
[[ -z "$FOREIGN_RPATHS" ]] || fail "Binary has rpaths outside the bundle and OS: $FOREIGN_RPATHS"
FOREIGN_LIBS=$(otool -L "$MAIN_EXECUTABLE" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/|@executable_path/|@rpath/)' || true)
[[ -z "$FOREIGN_LIBS" ]] || fail "Binary links libraries outside the bundle and OS: $FOREIGN_LIBS"
ok "lipo -archs: $ARCHS; minos $BINARY_MINOS, sdk $BINARY_SDK; only system libraries and rpaths"

[[ -z "$(find "$APP" -name '.DS_Store' -o -name '._*')" ]] || fail "$APP contains .DS_Store or AppleDouble files."
[[ -z "$(xattr -lr "$APP" 2>/dev/null)" ]] || fail "$APP has extended attributes."
[[ -z "$(find "$APP" ! -perm -o+r)" ]] || fail "$APP has files that are not world-readable."
ok "no .DS_Store, AppleDouble files or extended attributes; all files world-readable"

skip "spctl: not applicable (outside the store, Gatekeeper rejects Mac App Store-signed builds by design)"

# ---------------------------------------------------------------------------
step "Verify the package"

PKG_SIGNATURE=$(pkgutil --check-signature "$PKG" 2>&1) || { echo "$PKG_SIGNATURE" >&2; fail "pkgutil --check-signature failed."; }
echo "$PKG_SIGNATURE" | sed 's/^/  /'
grep -q 'Status: signed' <<<"$PKG_SIGNATURE" || fail "$PKG is not signed."
grep -q "1\. $INSTALLER_IDENTITY" <<<"$PKG_SIGNATURE" || fail "$PKG is not signed by $INSTALLER_IDENTITY."
ok "package signed by '$INSTALLER_IDENTITY'"

PAYLOAD=$(pkgutil --payload-files "$PKG")
for required in "./$APP_NAME.app/Contents/Info.plist" "./$APP_NAME.app/Contents/MacOS/$APP_NAME" \
                "./$APP_NAME.app/Contents/embedded.provisionprofile" "./$APP_NAME.app/Contents/_CodeSignature/CodeResources" \
                "./$APP_NAME.app/Contents/Resources/${ICON_FILE%.icns}.icns"; do
  grep -qxF "$required" <<<"$PAYLOAD" || fail "Package payload is missing $required."
done
OUTSIDE=$(grep -vE "^\.$|^\./$APP_NAME\.app(/|$)" <<<"$PAYLOAD" || true)
[[ -z "$OUTSIDE" ]] || fail "Package payload has files outside $APP_NAME.app: $OUTSIDE"
grep -qE '(^|/)(\.DS_Store|\._[^/]*)$' <<<"$PAYLOAD" && fail "Package payload contains .DS_Store or AppleDouble files."
ok "pkgutil --payload-files: $(grep -c . <<<"$PAYLOAD") entries, all inside ./$APP_NAME.app, installs to /Applications"

pkgutil --expand-full "$PKG" "$WORK_DIR/expanded" >/dev/null
DISTRIBUTION_XML="$WORK_DIR/expanded/Distribution"
[[ -f "$DISTRIBUTION_XML" ]] || fail "Package has no Distribution file."
grep -q "<product id=\"$BUNDLE_ID\" version=\"$MARKETING_VERSION\"" "$DISTRIBUTION_XML" \
  || fail "Distribution product id/version is not $BUNDLE_ID $MARKETING_VERSION."
grep -q 'hostArchitectures="arm64"' "$DISTRIBUTION_XML" || warn "Distribution does not restrict hostArchitectures to arm64"
EXPANDED_APP=$(find "$WORK_DIR/expanded" -maxdepth 3 -type d -name "$APP_NAME.app" | head -1)
[[ -n "$EXPANDED_APP" ]] || fail "Could not find $APP_NAME.app in the expanded package."
codesign --verify --strict "$EXPANDED_APP" 2>/dev/null || fail "The app inside the package fails signature verification."
ok "Distribution: product $BUNDLE_ID $MARKETING_VERSION, arm64; app extracted from the package verifies"

# ---------------------------------------------------------------------------
if [[ "$UPLOAD" == "1" ]]; then
  step "Upload to App Store Connect (app $ASC_APP_ID)"
  asc builds upload --app "$ASC_APP_ID" --pkg "$PKG" --version "$MARKETING_VERSION" --build-number "$BUILD_NUMBER" --wait
  ok "uploaded $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER)"
fi

step "Done"
echo "  App:     $APP"
echo "  Package: $PKG ($(du -h "$PKG" | cut -f1 | tr -d ' '))"
[[ -d "$DSYM" ]] && echo "  dSYM:    $DSYM (keep it to symbolicate crash reports)"

echo
echo "${BOLD}Next steps${RESET}"
if [[ "$UPLOAD" == "1" ]]; then
  cat <<EOF
  1. In App Store Connect, attach build $BUILD_NUMBER to version $MARKETING_VERSION, fill in the
     metadata, screenshots and App Privacy answers, then submit for review.
  2. Bump BUILD_NUMBER in version.env before the next upload; each upload needs a new build number.
EOF
else
  N=1
  if [[ ! "$ASC_APP_ID" =~ ^[0-9]+$ ]]; then
    cat <<EOF
  $N. Create the app record in App Store Connect (Apps > + > New App): platform macOS,
     bundle ID $BUNDLE_ID, your SKU and name. Copy its Apple ID (App Information) into
     ASC_APP_ID in appstore/app.env.
EOF
    N=$((N + 1))
  fi
  if [[ "$URL_PROBLEMS" == "1" ]]; then
    cat <<EOF
  $N. Publish docs/ with GitHub Pages so the privacy policy, support and marketing URLs load
     (see "Publishing the website" in appstore/RELEASING.md). --upload refuses to run until they do.
EOF
    N=$((N + 1))
  fi
  cat <<EOF
  $N. Upload: scripts/release_appstore.sh --upload
     (rebuilds, re-verifies, then runs asc builds upload --app <ASC_APP_ID> --pkg <pkg>
     --version $MARKETING_VERSION --build-number $BUILD_NUMBER --wait).
  $((N + 1)). After processing, attach the build to version $MARKETING_VERSION, complete the metadata,
     screenshots and App Privacy answers, and submit for review.
  $((N + 2)). Bump BUILD_NUMBER in version.env before every further upload.
EOF
fi
