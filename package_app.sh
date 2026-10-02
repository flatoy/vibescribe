#!/usr/bin/env bash
set -euo pipefail

# Builds VibeScribe.app with SwiftPM.
#
# Default: Developer ID (APP_IDENTITY set) or ad-hoc signed app in the repo root.
#
# DISTRIBUTION=appstore builds the Mac App Store variant (see appstore/RELEASING.md):
#   release, arm64 only, sandbox entitlements, App Store Info.plist keys, a full ICNS,
#   the embedded provisioning profile, and an Apple Distribution signature.
#   Usually run through scripts/release_appstore.sh. Relevant environment:
#     APP_IDENTITY          signing identity (required unless SIGNING_MODE=adhoc)
#     PROVISIONING_PROFILE  Mac App Store profile, embedded as Contents/embedded.provisionprofile
#     APP_ENTITLEMENTS      default appstore/VibeScribe.entitlements; the application and team
#                           identifiers are merged in from the profile at sign time
#     SWIFT_BIN             default: Apple's swift from xcrun --find swift; swift.org toolchains
#                           are refused
#     SCRATCH_PATH          SwiftPM scratch path (default .build)
#     OUTPUT_DIR            where VibeScribe.app is written (default: repo root)
#     HARDENED_RUNTIME      1 (default) signs with --options runtime; 0 omits it
#     SIGNING_MODE=adhoc    ad-hoc sandbox smoke test (no profile, no app identifier), built as
#                           ADHOC_BUNDLE_ID (default <BUNDLE_ID>.sandboxtest) so it never
#                           shares the real app's container or privacy permissions
#     DT_XCODE, DT_XCODE_BUILD, DT_SDK_NAME, DT_SDK_BUILD, DT_PLATFORM_VERSION,
#     DT_PLATFORM_BUILD, DT_COMPILER, BUILD_MACHINE_OS_BUILD  override build-environment keys
#     APP_CATEGORY, COPYRIGHT  override LSApplicationCategoryType / NSHumanReadableCopyright
#     APPSTORE_ICON_BODY    size of the icon shape on the 1024 px canvas (default 824, Apple's grid)

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

DISTRIBUTION=${DISTRIBUTION:-}
case "$DISTRIBUTION" in
  ""|developer-id) DISTRIBUTION="" ;;
  appstore) ;;
  *)
    echo "ERROR: Unknown DISTRIBUTION '$DISTRIBUTION' (use appstore, or leave it unset)." >&2
    exit 1
    ;;
esac
SCRATCH_PATH=${SCRATCH_PATH:-.build}
OUTPUT_DIR=${OUTPUT_DIR:-$ROOT}
SWIFT_BUILD_ARGS=()
if [[ "$SCRATCH_PATH" != ".build" ]]; then
  SWIFT_BUILD_ARGS+=(--scratch-path "$SCRATCH_PATH")
fi

# The App Store build uses Apple's Swift from the selected developer directory (Xcode or the
# Command Line Tools, see xcode-select -p), never a swift.org toolchain earlier on PATH, so the
# binary matches the Apple toolchain that the DT* Info.plist keys describe.
if [[ "$DISTRIBUTION" == "appstore" ]]; then
  SWIFT_BIN=${SWIFT_BIN:-$(xcrun --find swift 2>/dev/null || echo swift)}
else
  SWIFT_BIN=${SWIFT_BIN:-swift}
fi

read -r TOOLS_HEADER < "$ROOT/Package.swift"
if [[ ! "$TOOLS_HEADER" =~ ^//[[:space:]]swift-tools-version:[[:space:]]*([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
  echo "ERROR: Could not read the Swift tools version from Package.swift." >&2
  exit 1
fi
REQUIRED_SWIFT_MAJOR=${BASH_REMATCH[1]}
REQUIRED_SWIFT_MINOR=${BASH_REMATCH[2]}
REQUIRED_SWIFT_PATCH=${BASH_REMATCH[4]:-0}
REQUIRED_SWIFT_VERSION="$REQUIRED_SWIFT_MAJOR.$REQUIRED_SWIFT_MINOR.$REQUIRED_SWIFT_PATCH"

if ! command -v "$SWIFT_BIN" >/dev/null 2>&1; then
  echo "ERROR: Swift $REQUIRED_SWIFT_VERSION or newer is required to build VibeScribe." >&2
  echo "Install it from https://www.swift.org/install/macos/" >&2
  exit 1
fi
if ! SWIFT_VERSION_OUTPUT=$("$SWIFT_BIN" --version 2>&1); then
  echo "ERROR: Could not run swift --version: $SWIFT_VERSION_OUTPUT" >&2
  exit 1
fi
if [[ ! "$SWIFT_VERSION_OUTPUT" =~ Swift[[:space:]]version[[:space:]]([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
  echo "ERROR: Could not determine the installed Swift version: $SWIFT_VERSION_OUTPUT" >&2
  exit 1
fi
SWIFT_MAJOR=${BASH_REMATCH[1]}
SWIFT_MINOR=${BASH_REMATCH[2]}
SWIFT_PATCH=${BASH_REMATCH[4]:-0}
if (( SWIFT_MAJOR < REQUIRED_SWIFT_MAJOR ||
      (SWIFT_MAJOR == REQUIRED_SWIFT_MAJOR && SWIFT_MINOR < REQUIRED_SWIFT_MINOR) ||
      (SWIFT_MAJOR == REQUIRED_SWIFT_MAJOR && SWIFT_MINOR == REQUIRED_SWIFT_MINOR && SWIFT_PATCH < REQUIRED_SWIFT_PATCH) )); then
  echo "ERROR: VibeScribe requires Swift $REQUIRED_SWIFT_VERSION or newer; the active toolchain is Swift $SWIFT_MAJOR.$SWIFT_MINOR.$SWIFT_PATCH." >&2
  echo "Install Xcode 26 or newer, or update the Swift command line tools: https://www.swift.org/install/macos/" >&2
  echo "Check the active toolchain with swift --version and xcode-select -p, then retry." >&2
  exit 1
fi
if [[ "$DISTRIBUTION" == "appstore" && "$SWIFT_VERSION_OUTPUT" != *"(swiftlang-"* ]]; then
  # Apple's builds report "(swiftlang-<version> clang-<version>)"; swift.org builds report
  # "(swift-<version>-RELEASE)".
  echo "ERROR: The App Store build needs Apple's Swift from Xcode or the Command Line Tools." >&2
  echo "       $SWIFT_BIN is not an Apple toolchain:" >&2
  echo "       $(head -n 1 <<<"$SWIFT_VERSION_OUTPUT")" >&2
  echo "       Select Apple's developer tools with xcode-select, or set SWIFT_BIN." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1 || ! SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null); then
  echo "ERROR: Could not find a macOS SDK. Install Xcode 26 or newer and select its developer tools." >&2
  exit 1
fi
if [[ ! "$SDK_VERSION" =~ ^([0-9]+)\.([0-9]+) ]] || (( ${BASH_REMATCH[1]:-0} < 26 )); then
  echo "ERROR: VibeScribe's pinned WhisperKit dependency requires the macOS 26 SDK; the active SDK is ${SDK_VERSION}." >&2
  echo "Install Xcode 26 or newer, or its matching Command Line Tools, then check xcrun --sdk macosx --show-sdk-version." >&2
  exit 1
fi
if [[ "$DISTRIBUTION" == "appstore" ]]; then
  # Apple's swift run directly (not through xcrun) links without SDKROOT, and the linker then
  # records the deployment target as the SDK version (LC_BUILD_VERSION sdk 14.0), which App
  # Store Connect rejects. Set it the way xcrun does.
  export SDKROOT
  SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
fi

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
fi

APP_NAME=${APP_NAME:-VibeScribe}
BUNDLE_ID=${BUNDLE_ID:-io.m10s.vibescribe}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-14.0}
MENU_BAR_APP=${MENU_BAR_APP:-1}
SIGNING_MODE=${SIGNING_MODE:-}
APP_IDENTITY=${APP_IDENTITY:-}

MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
MIC_USAGE=${MIC_USAGE:-"VibeScribe uses the microphone while you dictate with your shortcut, and turns your speech into text on this Mac. Audio is never saved or sent anywhere."}
INPUT_MONITORING_USAGE=${INPUT_MONITORING_USAGE:-"VibeScribe needs input monitoring to capture the push-to-talk hotkey."}
ACCESSIBILITY_USAGE=${ACCESSIBILITY_USAGE:-"VibeScribe needs accessibility access to paste transcripts into other apps."}

ARCH_LIST=( ${ARCHES:-} )
if [[ "$DISTRIBUTION" == "appstore" ]]; then
  # The Mac App Store build is Apple silicon only.
  if [[ ${#ARCH_LIST[@]} -gt 0 && "${ARCH_LIST[*]}" != "arm64" ]]; then
    echo "ERROR: DISTRIBUTION=appstore builds arm64 only (ARCHES='${ARCHES}')." >&2
    exit 1
  fi
  ARCH_LIST=(arm64)
  if [[ "$CONF" != "release" ]]; then
    echo "ERROR: DISTRIBUTION=appstore requires the release configuration (got '$CONF')." >&2
    exit 1
  fi
fi
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  ARCH_LIST=("$HOST_ARCH")
fi

if [[ "$DISTRIBUTION" == "appstore" ]]; then
  APPSTORE_WORK_DIR="$SCRATCH_PATH/appstore"
  APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$ROOT/appstore/VibeScribe.entitlements}
  PROVISIONING_PROFILE=${PROVISIONING_PROFILE:-}
  HARDENED_RUNTIME=${HARDENED_RUNTIME:-1}
  APP_CATEGORY=${APP_CATEGORY:-public.app-category.productivity}
  COPYRIGHT=${COPYRIGHT:-"© 2026 Hello World AS"}
  APPSTORE_ADHOC=0
  mkdir -p "$APPSTORE_WORK_DIR"
  if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    APPSTORE_ADHOC=1
    # A sandboxed test build must never share the real app's container or privacy permissions.
    BUNDLE_ID=${ADHOC_BUNDLE_ID:-$BUNDLE_ID.sandboxtest}
    if [[ "$BUNDLE_ID" == "io.m10s.vibescribe" ]]; then
      echo "ERROR: Ad-hoc App Store test builds need a bundle ID other than io.m10s.vibescribe." >&2
      exit 1
    fi
  elif [[ -z "$APP_IDENTITY" ]]; then
    echo "ERROR: DISTRIBUTION=appstore needs APP_IDENTITY (e.g. \"Apple Distribution: …\")," >&2
    echo "       or SIGNING_MODE=adhoc for a local sandbox smoke test." >&2
    exit 1
  fi
  if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
    echo "ERROR: Entitlements file not found: $APP_ENTITLEMENTS" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$APP_ENTITLEMENTS" 2>/dev/null)" != "true" ]]; then
    echo "ERROR: $APP_ENTITLEMENTS must enable com.apple.security.app-sandbox." >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$APP_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "ERROR: $APP_ENTITLEMENTS must not contain com.apple.security.get-task-allow." >&2
    exit 1
  fi

  if [[ "$APPSTORE_ADHOC" == "0" ]]; then
    if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
      echo "ERROR: DISTRIBUTION=appstore needs PROVISIONING_PROFILE pointing at the Mac App Store profile." >&2
      exit 1
    fi
    PROFILE_PLIST="$APPSTORE_WORK_DIR/profile.plist"
    if ! security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST" 2>/dev/null; then
      echo "ERROR: Could not decode $PROVISIONING_PROFILE." >&2
      exit 1
    fi
    PROFILE_TEAM_ID=$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST")
    TEAM_ID=${TEAM_ID:-$PROFILE_TEAM_ID}
    if [[ "$TEAM_ID" != "$PROFILE_TEAM_ID" ]]; then
      echo "ERROR: TEAM_ID=$TEAM_ID does not match the profile's team ($PROFILE_TEAM_ID)." >&2
      exit 1
    fi
    PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")
    if [[ "$PROFILE_APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]]; then
      echo "ERROR: Profile application identifier $PROFILE_APP_ID does not match $TEAM_ID.$BUNDLE_ID." >&2
      exit 1
    fi
    PROFILE_EXPIRY=$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")
    if [[ "$PROFILE_EXPIRY" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
      echo "ERROR: Provisioning profile expired on $PROFILE_EXPIRY." >&2
      exit 1
    fi
  fi

  # Command Line Tools updated in place can keep files from older releases that no installer
  # package owns any more (pkgutil --file-info shows none), and Apple's SwiftPM then fails:
  #   - include/swift/module.modulemap (Swift 5.9) defines SwiftBridging a second time, next to
  #     bridging.modulemap: "redefinition of module 'SwiftBridging'".
  #   - Swift 5.10 *.private.swiftinterface files next to newer public interfaces in lib/swift/pm
  #     break the manifest link: "Undefined symbols ... PackageDescription.Package".
  # Work around both without touching the toolchain, and print how to remove them for good.
  TOOLCHAIN_USR=$(cd "$(dirname "$(command -v "$SWIFT_BIN")")/.." && pwd)
  TOOLCHAIN_WORK_DIR="$(cd "$APPSTORE_WORK_DIR" && pwd)/toolchain"
  STALE_TOOLCHAIN_FILES=()
  STALE_MODULEMAP="$TOOLCHAIN_USR/include/swift/module.modulemap"
  if [[ -f "$STALE_MODULEMAP" && -f "$TOOLCHAIN_USR/include/swift/bridging.modulemap" ]] &&
     grep -q 'module SwiftBridging' "$STALE_MODULEMAP" &&
     grep -q 'module SwiftBridging' "$TOOLCHAIN_USR/include/swift/bridging.modulemap"; then
    STALE_TOOLCHAIN_FILES+=("$STALE_MODULEMAP")
    mkdir -p "$TOOLCHAIN_WORK_DIR"
    : > "$TOOLCHAIN_WORK_DIR/empty.modulemap"
    cat > "$TOOLCHAIN_WORK_DIR/overlay.yaml" <<YAML
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "name": "$TOOLCHAIN_USR/include/swift",
      "type": "directory",
      "contents": [
        { "name": "module.modulemap", "type": "file", "external-contents": "$TOOLCHAIN_WORK_DIR/empty.modulemap" }
      ]
    }
  ]
}
YAML
    SWIFT_BUILD_ARGS+=(-Xswiftc -vfsoverlay -Xswiftc "$TOOLCHAIN_WORK_DIR/overlay.yaml"
                       -Xbuild-tools-swiftc -vfsoverlay -Xbuild-tools-swiftc "$TOOLCHAIN_WORK_DIR/overlay.yaml")
  fi
  STALE_INTERFACES=()
  while IFS= read -r private; do
    public="${private%.private.swiftinterface}.swiftinterface"
    if [[ -f "$public" && "$(grep -m 1 '^// swift-compiler-version:' "$private")" != "$(grep -m 1 '^// swift-compiler-version:' "$public")" ]]; then
      STALE_INTERFACES+=("$private")
    fi
  done < <(find "$TOOLCHAIN_USR/lib/swift/pm" -name '*.private.swiftinterface' 2>/dev/null)
  if [[ ${#STALE_INTERFACES[@]} -gt 0 ]]; then
    STALE_TOOLCHAIN_FILES+=("${STALE_INTERFACES[@]}")
    PM_LIBS="$TOOLCHAIN_WORK_DIR/pm"
    rm -rf "$PM_LIBS"
    mkdir -p "$PM_LIBS"
    cp -Rc "$TOOLCHAIN_USR/lib/swift/pm/ManifestAPI" "$TOOLCHAIN_USR/lib/swift/pm/PluginAPI" "$PM_LIBS/"
    for private in "${STALE_INTERFACES[@]}"; do
      rm -f "$PM_LIBS/${private#"$TOOLCHAIN_USR/lib/swift/pm/"}"
    done
    export SWIFTPM_CUSTOM_LIBS_DIR="$PM_LIBS"
  fi
  if [[ ${#STALE_TOOLCHAIN_FILES[@]} -gt 0 ]]; then
    echo "NOTE: Working around stale files left in the Swift toolchain by an older install:" >&2
    printf '        %s\n' "${STALE_TOOLCHAIN_FILES[@]}" >&2
    echo "      To fix this for good, delete them (sudo rm <files>), or reinstall the Command Line Tools." >&2
  fi
fi

for ARCH in "${ARCH_LIST[@]}"; do
  if [[ "$DISTRIBUTION" == "appstore" ]]; then
    # SwiftPM does not relink when only the environment (SDKROOT) changed.
    rm -f "$SCRATCH_PATH/${ARCH}-apple-macosx/$CONF/$APP_NAME"
  fi
  "$SWIFT_BIN" build -c "$CONF" --arch "$ARCH" --product "$APP_NAME" ${SWIFT_BUILD_ARGS[@]+"${SWIFT_BUILD_ARGS[@]}"}
done

APP="$OUTPUT_DIR/${APP_NAME}.app"
mkdir -p "$OUTPUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Frameworks"

# Convert the image exported from Icon Composer to Icon.icns (requires iconutil).
ICON_PNG_SOURCE="$ROOT/Icon.png"
ICON_TARGET="$ROOT/Icon.icns"
if [[ "$DISTRIBUTION" == "appstore" ]]; then
  # App Store Connect requires a real ICNS with every size up to 512x512@2x (ITMS-90236).
  # Build it in the scratch path from the 1024 px source, normalised to 8 bits per channel
  # (sips matching to the source's Display P3 profile drops the 16-bit depth Icon.png uses).
  if [[ ! -f "$ICON_PNG_SOURCE" ]]; then
    echo "ERROR: $ICON_PNG_SOURCE (1024x1024) is required for the App Store icon." >&2
    exit 1
  fi
  ICON_WIDTH=$(sips -g pixelWidth "$ICON_PNG_SOURCE" | awk '/pixelWidth/ {print $2}')
  ICON_HEIGHT=$(sips -g pixelHeight "$ICON_PNG_SOURCE" | awk '/pixelHeight/ {print $2}')
  if [[ "$ICON_WIDTH" != "1024" || "$ICON_HEIGHT" != "1024" ]]; then
    echo "ERROR: $ICON_PNG_SOURCE must be 1024x1024 (is ${ICON_WIDTH}x${ICON_HEIGHT})." >&2
    exit 1
  fi
  ICONSET_DIR="$APPSTORE_WORK_DIR/Icon.iconset"
  ICON_TARGET="$APPSTORE_WORK_DIR/Icon.icns"
  ICON_MASTER="$APPSTORE_WORK_DIR/Icon-1024.png"
  rm -rf "$ICONSET_DIR" "$ICON_TARGET"
  mkdir -p "$ICONSET_DIR"
  sips -m "/System/Library/ColorSync/Profiles/Display P3.icc" "$ICON_PNG_SOURCE" --out "$ICON_MASTER" >/dev/null
  # Icon.png fills the whole canvas. macOS icons keep their shape inside an 824 px body centred
  # on the 1024 px canvas (Apple's icon grid), so shrink it and pad with transparency, or it looks
  # oversized next to other apps in the Dock and Finder. Set APPSTORE_ICON_BODY=1024 for a source
  # that already has the margin.
  APPSTORE_ICON_BODY=${APPSTORE_ICON_BODY:-824}
  if [[ ! "$APPSTORE_ICON_BODY" =~ ^[0-9]+$ ]] || (( APPSTORE_ICON_BODY < 512 || APPSTORE_ICON_BODY > 1024 )); then
    echo "ERROR: APPSTORE_ICON_BODY must be between 512 and 1024 (got '$APPSTORE_ICON_BODY')." >&2
    exit 1
  fi
  if (( APPSTORE_ICON_BODY < 1024 )); then
    sips -z "$APPSTORE_ICON_BODY" "$APPSTORE_ICON_BODY" "$ICON_MASTER" >/dev/null
    sips -p 1024 1024 "$ICON_MASTER" >/dev/null
  fi
  for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
              256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$ICON_MASTER" --out "$ICONSET_DIR/${spec#*:}.png" >/dev/null
  done
  cp "$ICON_MASTER" "$ICONSET_DIR/icon_512x512@2x.png"
  iconutil --convert icns --output "$ICON_TARGET" "$ICONSET_DIR"

  # Round-trip the ICNS and check every representation is present at the right size.
  ICON_CHECK_DIR="$APPSTORE_WORK_DIR/Icon-check.iconset"
  rm -rf "$ICON_CHECK_DIR"
  iconutil --convert iconset --output "$ICON_CHECK_DIR" "$ICON_TARGET"
  for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
              256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    image="$ICON_CHECK_DIR/${spec#*:}.png"
    size=$(sips -g pixelWidth "$image" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    if [[ "$size" != "${spec%%:*}" ]]; then
      echo "ERROR: $ICON_TARGET is missing ${spec#*:} (${spec%%:*} px)." >&2
      exit 1
    fi
  done
  rm -rf "$ICON_CHECK_DIR"
elif [[ -f "$ICON_PNG_SOURCE" ]]; then
  ICONSET_DIR="$ROOT/.build/icon.iconset"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_PNG_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil --convert icns --output "$ICON_TARGET" "$ICONSET_DIR"
fi

LSUI_VALUE="false"
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE="true"
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
# Mark builds made from uncommitted changes, so the commit is not mistaken for their source.
if [[ "$GIT_COMMIT" != "unknown" && -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_COMMIT+="-dirty"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>NSMicrophoneUsageDescription</key><string>${MIC_USAGE}</string>
    <key>NSInputMonitoringUsageDescription</key><string>${INPUT_MONITORING_USAGE}</string>
    <key>NSAccessibilityUsageDescription</key><string>${ACCESSIBILITY_USAGE}</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

# Xcode version that shipped a given macOS SDK build, as "DTXcode DTXcodeBuild".
# Uses the first final Xcode release containing that SDK (source: https://xcodereleases.com/data.json).
xcode_for_sdk_build() {
  case "$1" in
    25A352) echo "2600 17A324" ;; # Xcode 26.0 (the SDK also ships in 26.0.1 / 17A400)
    *)
      command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 1
      curl -fsSL --max-time 30 https://xcodereleases.com/data.json 2>/dev/null | python3 -c '
import json, sys
sdk = sys.argv[1]
def key(x):
    d = x.get("date", {})
    return (d.get("year", 0), d.get("month", 0), d.get("day", 0))
matches = [x for x in json.load(sys.stdin)
           if x.get("version", {}).get("release", {}).get("release")
           and any(s.get("build", "").upper() == sdk.upper() for s in x.get("sdks", {}).get("macOS", []))]
if not matches:
    sys.exit(1)
x = min(matches, key=key)["version"]
parts = [int(p) for p in x["number"].split(".")] + [0, 0]
print("%d%d%d %s" % (parts[0], parts[1], parts[2], x["build"]))
' "$1"
      ;;
  esac
}

if [[ "$DISTRIBUTION" == "appstore" ]]; then
  # Keys App Store processing expects in an Xcode-built Mac app.
  SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
  SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
  DT_SDK_BUILD=${DT_SDK_BUILD:-$SDK_BUILD}
  DT_SDK_NAME=${DT_SDK_NAME:-$(plutil -extract CanonicalName raw -o - "$SDK_PATH/SDKSettings.plist" 2>/dev/null || echo "macosx${SDK_VERSION}")}
  DT_PLATFORM_VERSION=${DT_PLATFORM_VERSION:-$SDK_VERSION}
  DT_PLATFORM_BUILD=${DT_PLATFORM_BUILD:-$SDK_BUILD}
  DT_COMPILER=${DT_COMPILER:-com.apple.compilers.llvm.clang.1_0}
  BUILD_MACHINE_OS_BUILD=${BUILD_MACHINE_OS_BUILD:-$(sw_vers -buildVersion)}
  if [[ -z "${DT_XCODE:-}" || -z "${DT_XCODE_BUILD:-}" ]]; then
    if ! XCODE_INFO=$(xcode_for_sdk_build "$SDK_BUILD"); then
      echo "ERROR: Unknown Xcode release for macOS SDK build $SDK_BUILD." >&2
      echo "       Look it up at https://xcodereleases.com and set DT_XCODE (e.g. 2600) and DT_XCODE_BUILD (e.g. 17A324)," >&2
      echo "       or add it to xcode_for_sdk_build in package_app.sh." >&2
      exit 1
    fi
    DT_XCODE=${DT_XCODE:-${XCODE_INFO%% *}}
    DT_XCODE_BUILD=${DT_XCODE_BUILD:-${XCODE_INFO##* }}
  fi

  INFO_PLIST="$APP/Contents/Info.plist"
  plutil -replace CFBundleInfoDictionaryVersion -string "6.0" "$INFO_PLIST"
  plutil -replace CFBundleDevelopmentRegion -string "en" "$INFO_PLIST"
  plutil -replace CFBundlePackageType -string "APPL" "$INFO_PLIST"
  plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "$INFO_PLIST"
  plutil -replace LSApplicationCategoryType -string "$APP_CATEGORY" "$INFO_PLIST"
  plutil -replace ITSAppUsesNonExemptEncryption -bool NO "$INFO_PLIST"
  plutil -replace NSHumanReadableCopyright -string "$COPYRIGHT" "$INFO_PLIST"
  plutil -replace BuildMachineOSBuild -string "$BUILD_MACHINE_OS_BUILD" "$INFO_PLIST"
  plutil -replace DTCompiler -string "$DT_COMPILER" "$INFO_PLIST"
  plutil -replace DTPlatformBuild -string "$DT_PLATFORM_BUILD" "$INFO_PLIST"
  plutil -replace DTPlatformName -string "macosx" "$INFO_PLIST"
  plutil -replace DTPlatformVersion -string "$DT_PLATFORM_VERSION" "$INFO_PLIST"
  plutil -replace DTSDKBuild -string "$DT_SDK_BUILD" "$INFO_PLIST"
  plutil -replace DTSDKName -string "$DT_SDK_NAME" "$INFO_PLIST"
  plutil -replace DTXcode -string "$DT_XCODE" "$INFO_PLIST"
  plutil -replace DTXcodeBuild -string "$DT_XCODE_BUILD" "$INFO_PLIST"
  plutil -convert xml1 "$INFO_PLIST"
  plutil -lint "$INFO_PLIST" >/dev/null
fi

build_product_path() {
  local name="$1"
  local arch="$2"
  case "$arch" in
    arm64|x86_64) echo "$SCRATCH_PATH/${arch}-apple-macosx/$CONF/$name" ;;
    *) echo "$SCRATCH_PATH/$CONF/$name" ;;
  esac
}

verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  local actual_count expected_count
  actual_count=$(wc -w <<<"$actual" | tr -d ' ')
  expected_count=${#expected[@]}
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    echo "ERROR: $binary arch mismatch (expected: ${expected[*]}, actual: ${actual})" >&2
    exit 1
  fi
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

install_binary "$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Bundle app resources (if any).
APP_RESOURCES_DIR="$ROOT/Sources/$APP_NAME/Resources"
if [[ -d "$APP_RESOURCES_DIR" ]]; then
  cp -R "$APP_RESOURCES_DIR/." "$APP/Contents/Resources/"
fi
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/VibeScribe-LICENSE.txt"
cp "$ROOT/scripts/whisper_model_manifest.json" "$APP/Contents/Resources/whisper_model_manifest.json"
cp "$ROOT/scripts/whisper_model_manifest_turbo.json" "$APP/Contents/Resources/whisper_model_manifest_turbo.json"

# SwiftPM resource bundles are emitted next to the built binary.
PREFERRED_BUILD_DIR="$(dirname "$(build_product_path "$APP_NAME" "${ARCH_LIST[0]}")")"
shopt -s nullglob
SWIFTPM_BUNDLES=("${PREFERRED_BUILD_DIR}/"*.bundle)
shopt -u nullglob
if [[ ${#SWIFTPM_BUNDLES[@]} -gt 0 ]]; then
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    cp -R "$bundle" "$APP/Contents/Resources/"
  done
fi

# Embed frameworks if any exist in the build folder.
FRAMEWORK_DIRS=("$SCRATCH_PATH/$CONF" "$SCRATCH_PATH/${ARCH_LIST[0]}-apple-macosx/$CONF")
for dir in "${FRAMEWORK_DIRS[@]}"; do
  if compgen -G "${dir}/*.framework" >/dev/null; then
    cp -R "${dir}/"*.framework "$APP/Contents/Frameworks/"
    chmod -R a+rX "$APP/Contents/Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"
    break
  fi
done

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

if [[ "$DISTRIBUTION" == "appstore" ]]; then
  MAIN_EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"
  # A SwiftPM toolchain adds an absolute LC_RPATH into the local toolchain (e.g. ~/.swiftly or
  # ~/Library/Developer/Toolchains). Nothing in the app may depend on paths outside the bundle or
  # the OS, so drop absolute rpaths that point anywhere else.
  while IFS= read -r rpath; do
    case "$rpath" in
      /usr/lib/*|/System/*|@*) ;;
      *)
        # install_name_tool warns that the signature becomes invalid; the app is re-signed below.
        if ! RPATH_OUTPUT=$(install_name_tool -delete_rpath "$rpath" "$MAIN_EXECUTABLE" 2>&1); then
          echo "ERROR: Could not remove LC_RPATH $rpath: $RPATH_OUTPUT" >&2
          exit 1
        fi
        ;;
    esac
  done < <(otool -l "$MAIN_EXECUTABLE" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
  # Every dylib must come from the OS or the app's Frameworks folder.
  LINKED_LIBRARIES=$(otool -L "$MAIN_EXECUTABLE")
  FOREIGN_LIBRARIES=$(tail -n +2 <<<"$LINKED_LIBRARIES" | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/Library/|@executable_path/\.\./Frameworks/|@rpath/)' || true)
  if [[ -n "$FOREIGN_LIBRARIES" ]]; then
    echo "ERROR: $MAIN_EXECUTABLE links libraries outside the OS and the app bundle:" >&2
    echo "$FOREIGN_LIBRARIES" >&2
    exit 1
  fi
  if [[ "$LINKED_LIBRARIES" == *"@rpath/"* ]] && ! compgen -G "$APP/Contents/Frameworks/*" >/dev/null; then
    echo "ERROR: $MAIN_EXECUTABLE links @rpath libraries but the app embeds no frameworks:" >&2
    otool -L "$MAIN_EXECUTABLE" | grep '@rpath/' >&2
    exit 1
  fi

  rmdir "$APP/Contents/Frameworks" 2>/dev/null || true
  if [[ "$APPSTORE_ADHOC" == "0" ]]; then
    # The profile must be inside the bundle before it is signed.
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  fi
  find "$APP" -name '.DS_Store' -delete
  # App Store packages must be world-readable and only writable by the owner.
  chmod -R u+rwX,go+rX,go-w "$APP"
fi

# Ensure contents are writable before stripping attributes and signing.
chmod -R u+w "$APP"

# Strip extended attributes to prevent AppleDouble files that break code sealing.
xattr -cr "$APP"
find "$APP" -name '._*' -delete

if [[ "$DISTRIBUTION" == "appstore" ]]; then
  # Entitlements = appstore/VibeScribe.entitlements + the identifiers the profile grants.
  SIGNING_ENTITLEMENTS="$APPSTORE_WORK_DIR/${APP_NAME}.signing.entitlements"
  cp "$APP_ENTITLEMENTS" "$SIGNING_ENTITLEMENTS"
  plutil -convert xml1 "$SIGNING_ENTITLEMENTS"
  if [[ "$APPSTORE_ADHOC" == "0" ]]; then
    for key in com.apple.application-identifier com.apple.developer.team-identifier; do
      /usr/libexec/PlistBuddy -c "Delete :$key" "$SIGNING_ENTITLEMENTS" >/dev/null 2>&1 || true
    done
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$SIGNING_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$SIGNING_ENTITLEMENTS"
  fi
  plutil -lint "$SIGNING_ENTITLEMENTS" >/dev/null

  if [[ "$APPSTORE_ADHOC" == "1" ]]; then
    CODESIGN_ARGS=(--force --sign "-")
  else
    CODESIGN_ARGS=(--force --timestamp --sign "$APP_IDENTITY")
  fi
  if [[ "$HARDENED_RUNTIME" == "1" ]]; then
    CODESIGN_ARGS+=(--options runtime)
  fi

  # Sign nested code inside-out (never --deep): loose Mach-O files deepest first, then the
  # code bundles that contain them, then the app. Helper executables must inherit the sandbox.
  INHERIT_ENTITLEMENTS="$APPSTORE_WORK_DIR/inherit.entitlements"
  cat > "$INHERIT_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.inherit</key><true/>
</dict>
</plist>
PLIST
  NESTED_CODE=()
  while IFS= read -r file; do
    [[ "$file" == "$MAIN_EXECUTABLE" ]] && continue
    if [[ "$(file -b "$file")" == Mach-O* ]]; then
      NESTED_CODE+=("$file")
    fi
  done < <(find "$APP/Contents" -type f | awk -F/ '{print NF "\t" $0}' | sort -rn | cut -f2-)
  for file in ${NESTED_CODE[@]+"${NESTED_CODE[@]}"}; do
    if [[ "$(file -b "$file")" == *executable* ]]; then
      echo "Signing nested executable ${file#"$APP"/}"
      codesign "${CODESIGN_ARGS[@]}" --entitlements "$INHERIT_ENTITLEMENTS" "$file"
    else
      echo "Signing nested code ${file#"$APP"/}"
      codesign "${CODESIGN_ARGS[@]}" "$file"
    fi
  done
  while IFS= read -r bundle; do
    for file in ${NESTED_CODE[@]+"${NESTED_CODE[@]}"}; do
      if [[ "$file" == "$bundle/"* ]]; then
        echo "Signing nested bundle ${bundle#"$APP"/}"
        codesign "${CODESIGN_ARGS[@]}" "$bundle"
        break
      fi
    done
  done < <(find "$APP/Contents" -type d \( -name '*.framework' -o -name '*.bundle' -o -name '*.app' \
             -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' \) | awk -F/ '{print NF "\t" $0}' | sort -rn | cut -f2-)

  codesign "${CODESIGN_ARGS[@]}" --entitlements "$SIGNING_ENTITLEMENTS" "$APP"
  codesign --verify --strict "$APP"
  echo "Created $APP"
  exit 0
fi

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
DEFAULT_ENTITLEMENTS="$ENTITLEMENTS_DIR/${APP_NAME}.entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  cat > "$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Add entitlements here if needed. -->
</dict>
</plist>
PLIST
fi

if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
else
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
fi

# Sign embedded frameworks and their nested binaries before the app bundle.
sign_frameworks() {
  local fw
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    if [[ ! -d "$fw" ]]; then
      continue
    fi
    while IFS= read -r -d '' bin; do
      codesign "${CODESIGN_ARGS[@]}" "$bin"
    done < <(find "$fw" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$fw"
  done
}
sign_frameworks

codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"
