# Releasing VibeScribe to the Mac App Store

The Mac App Store build is produced with SwiftPM and Apple's Swift from the Command Line
Tools (or Xcode). It does not need Xcode, `xcodebuild`, `altool` or `actool`.

```sh
scripts/release_appstore.sh            # build, sign, package and verify
scripts/release_appstore.sh --upload   # the same, then upload with asc
```

Output in `dist/` (gitignored):

| File | What it is |
| --- | --- |
| `dist/VibeScribe.app` | sandboxed app, signed with Apple Distribution |
| `dist/VibeScribe-<version>-<build>.pkg` | installer package signed with 3rd Party Mac Developer Installer; this is what you upload |
| `dist/VibeScribe-<version>-<build>.dSYM` | debug symbols; keep them to symbolicate crash reports |

## Prerequisites

- **Command Line Tools with the macOS 26 SDK or later.** App Store Connect rejects builds
  made with older SDKs, and the script checks the SDK recorded in the binary.
- **Apple's Swift, 6.2 or later.** The App Store build uses the `swift` that
  `xcrun --find swift` returns (the developer directory selected with `xcode-select`), even
  when a swift.org toolchain such as swiftly comes first on `PATH`. The scripts refuse a
  toolchain whose `swift --version` has no `swiftlang-` build, so the binary is built by the
  Apple toolchain that the `DT*` keys describe. See
  [Stale files in the Command Line Tools](#stale-files-in-the-command-line-tools) if the build
  fails with `redefinition of module 'SwiftBridging'` or `Undefined symbols … PackageDescription`.
- **Signing identities in the login keychain** for team 8S36PA5867:
  - `Apple Distribution: Hello World AS (8S36PA5867)` signs the app.
  - `3rd Party Mac Developer Installer: Hello World AS (8S36PA5867)` signs the package.
- **Provisioning profile** `.signing/VibeScribe_Mac_App_Store.provisionprofile`. This is a
  Mac App Store profile for `8S36PA5867.io.m10s.vibescribe` that includes the Apple
  Distribution certificate. The current profile expires on 2027-10-02. The script warns 30
  days before expiry and fails once it has expired.
- **`asc`, the App Store Connect CLI,** with App Store Connect API credentials (kept in the
  gitignored `.asc/`), for `--upload` and the metadata commands below. The `asc web …`
  commands (App Privacy, declarations) also need a web session:
  `asc web auth login --apple-id <your Apple ID> --provider-id 128506857`. The provider ID
  is Hello World AS's App Store Connect provider, not the team ID.
- **The App Store Connect app record**, "VibeScribe: Voice to Text", Apple ID 6818493506.
  It already exists, and `ASC_APP_ID` in `appstore/app.env` points to it.

`.signing/`, `.asc/` and `dist/` are gitignored. Never commit certificates, keys,
profiles or API credentials.

## Cutting a release

1. Set the version in `version.env`:
   - `MARKETING_VERSION` is the user-visible version (`CFBundleShortVersionString`).
     Raise it for each new App Store version.
   - `BUILD_NUMBER` is `CFBundleVersion`. Every upload needs a build number higher than
     any build already uploaded for that version, even a failed one.

   The values in `version.env` take precedence over environment variables with the same
   names.
2. Run `scripts/release_appstore.sh`. It stops at the first failed check.
3. Commit everything, and publish the website (see
   [Publishing the website](#publishing-the-website)). `--upload` refuses to run from a
   dirty tree or while the privacy policy, support or marketing URL does not load.
4. Upload. Either run `scripts/release_appstore.sh --upload`, which rebuilds, re-verifies
   and then runs the command below, or run it yourself:

   ```sh
   asc builds upload --app "$ASC_APP_ID" --pkg dist/VibeScribe-1.0.0-6.pkg \
     --version 1.0.0 --build-number 6 --wait
   ```

5. In App Store Connect, wait for processing to finish. Then:
   - Attach the build to the version.
   - Fill in the metadata (`appstore/metadata/`), screenshots (`appstore/screenshots/`),
     App Privacy answers and review notes (`appstore/review-notes.md`).
   - Submit for review. The version is set to release automatically once approved.

   Steps 4 and 5 from the command line, with `VERSION_ID` from
   `asc versions list --app "$ASC_APP_ID"` (create the version first with
   `asc versions create` for a new release, and copy
   `appstore/metadata/version/<old>/` to the new version number):

   ```sh
   asc metadata apply --app "$ASC_APP_ID" --version 1.0.0 --platform MAC_OS --dir appstore/metadata
   asc screenshots upload --app "$ASC_APP_ID" --version-id "$VERSION_ID" --locale en-US \
     --path appstore/screenshots/en-US --device-type APP_DESKTOP --replace --confirm
   asc review details-create --version-id "$VERSION_ID" --notes "$(cat appstore/review-notes.md)" --if-exists update
   # Only if the App Privacy answers changed:
   asc web privacy apply --app "$ASC_APP_ID" --file appstore/privacy.json
   asc web privacy publish --app "$ASC_APP_ID"
   asc review doctor --app "$ASC_APP_ID" --version-id "$VERSION_ID"
   ```

   Export compliance is already answered: `ITSAppUsesNonExemptEncryption` is `NO`, because
   the app only uses HTTPS.

## What the scripts do

`scripts/release_appstore.sh` runs four stages: preflight, build, package and verify.

**Preflight** fails fast on any of the following:
- missing tools
- a malformed `version.env`
- missing signing identities
- a provisioning profile that is expired, for the wrong app ID or team, not a macOS
  profile, or a development profile (it has devices)
- a profile that does not contain the Apple Distribution certificate found in the keychain
- an entitlements file without the sandbox, or one that hardcodes identifiers
- a `swift` that is not Apple's (swift.org toolchains are refused)

It also checks, and warns about, the following. With `--upload` they are errors:
- uncommitted changes in the git tree. The build records them as `GitCommit` `<hash>-dirty`.
  Set `ALLOW_DIRTY=1` to upload anyway.
- the privacy policy URL (`appstore/metadata/app-info/en-US.json`) and the support and
  marketing URLs (`appstore/metadata/version/<version>/en-US.json`) must answer HTTP 2xx, and
  the app's Privacy Policy link (`AppInfo.privacyPolicyURL`) must be the same URL. Set
  `SKIP_URL_CHECK=1` to upload anyway.

With `--upload` it also runs the read-only `asc builds list --app <ASC_APP_ID> --platform
MAC_OS --version <version> --processing-state all --paginate` and stops if a build with the
same or a higher build number already exists for that version.

**Build** runs `DISTRIBUTION=appstore bash package_app.sh release`, with SwiftPM scratch
path `.build-mas` and output to `dist/`. In App Store mode, `package_app.sh` does the
following:
- builds release, arm64 only, with a minimum of macOS 14 (`version.env`)
- writes the App Store Info.plist keys:
  - `LSApplicationCategoryType` (productivity)
  - `ITSAppUsesNonExemptEncryption`
  - `NSHumanReadableCopyright`
  - `CFBundleSupportedPlatforms`
  - the build-environment keys `DTSDKName`, `DTSDKBuild`, `DTPlatformVersion`,
    `DTPlatformBuild`, `DTXcode`, `DTXcodeBuild`, `DTCompiler` and `BuildMachineOSBuild`
    (see the [build-environment keys](#build-environment-keys-dt) section)
- generates a full `Icon.icns` from `Icon.png` (16 pt to 512 pt @2x, converted to 8-bit
  Display P3). App Store Connect rejects apps without a 512 pt @2x icon (ITMS-90236).
  `Icon.png` fills its whole canvas, so the shape is scaled to 824 px and centred on the
  1024 px canvas with a transparent margin, as in Apple's macOS icon grid. Without the margin
  the icon looks oversized next to other apps. Set `APPSTORE_ICON_BODY=1024` if `Icon.png`
  ever gets its own margin.
- records `GitCommit` as the short commit hash, with `-dirty` if the tree has uncommitted
  changes
- sets `SDKROOT` to `xcrun --sdk macosx --show-sdk-path` and always relinks the app. When
  Apple's `swift` runs without `xcrun` and without `SDKROOT`, the linker records the
  deployment target as the SDK version (`sdk 14.0`), and App Store Connect rejects the
  binary. The verify stage checks the recorded SDK.
- removes any absolute `LC_RPATH` that points into a local toolchain. It fails if the binary
  links any library outside the OS or the bundle.
- embeds the provisioning profile as `Contents/embedded.provisionprofile`
- strips extended attributes, `._*` files and `.DS_Store`
- signs nested code first, deepest first, then the app (never `--deep`). It signs with the
  Apple Distribution identity and passes `--timestamp` and `--options runtime`.
  - The app's entitlements are `appstore/VibeScribe.entitlements`, plus
    `com.apple.application-identifier` and `com.apple.developer.team-identifier` taken
    from the profile.

**Package** runs `productbuild --component dist/VibeScribe.app /Applications --sign
"3rd Party Mac Developer Installer: …"`.

**Verify** checks the following:
- the app:
  - `codesign --verify --strict` succeeds
  - the signing authority, team, timestamp and hardened runtime are correct
  - the signed entitlements exactly equal the expected set
  - the embedded profile is identical to the source and contains the signing certificate
  - `plutil -lint` passes, and every required Info.plist key has the expected value
  - all icon sizes are present
  - `lipo` reports arm64 only
  - the binary's minimum macOS and SDK versions are correct, and it has no foreign rpaths
  - there are no `.DS_Store` files or extended attributes
- the package:
  - `pkgutil --check-signature` passes
  - the payload contains only `VibeScribe.app`, installed into `/Applications`
  - the Distribution file has the right product ID, version and `hostArchitectures="arm64"`
  - the app extracted from the package passes `codesign --verify`

The script does not run `spctl`. Gatekeeper only accepts Developer ID apps outside the
store, so `spctl --assess` always reports an Apple Distribution-signed app as "rejected".

### Overrides

`scripts/release_appstore.sh` accepts these environment variables:

| Variable | Default |
| --- | --- |
| `APP_IDENTITY` | `Apple Distribution: Hello World AS (8S36PA5867)` |
| `INSTALLER_IDENTITY` | `3rd Party Mac Developer Installer: Hello World AS (8S36PA5867)` |
| `PROVISIONING_PROFILE` | `.signing/VibeScribe_Mac_App_Store.provisionprofile` |
| `APP_ENTITLEMENTS` | `appstore/VibeScribe.entitlements` |
| `SCRATCH_PATH` | `.build-mas` |
| `DIST_DIR` | `dist` |
| `ASC_APP_ID` | the value in `appstore/app.env` |
| `SWIFT_BIN` | `xcrun --find swift`; must be Apple's Swift |
| `ALLOW_DIRTY=1` | unset; lets `--upload` run with uncommitted changes |
| `SKIP_URL_CHECK=1` | unset; lets `--upload` run while the App Store URLs do not load |

`package_app.sh` also accepts the following (see its header comment):
- `HARDENED_RUNTIME=0` omits `--options runtime`
- `APP_CATEGORY` and `COPYRIGHT` override `LSApplicationCategoryType` and
  `NSHumanReadableCopyright`
- the `DT_*` and `BUILD_MACHINE_OS_BUILD` variables override the build-environment keys
- `SWIFT_BIN` overrides the Apple `swift` it builds with
- `APPSTORE_ICON_BODY` sets the size of the icon shape on the 1024 px canvas (default 824)

Without `DISTRIBUTION=appstore`, `package_app.sh` behaves exactly as before. It builds the
Developer ID or ad-hoc app in the repo root.

## Build-environment keys (DT\*)

Xcode writes these keys into every app, and App Store Connect uses them to tell which SDK
and Xcode built the app. `package_app.sh` computes them:

| Key | Source |
| --- | --- |
| `DTSDKName` | `CanonicalName` in the SDK's `SDKSettings.plist`, e.g. `macosx26.0` |
| `DTSDKBuild` and `DTPlatformBuild` | `xcrun --show-sdk-build-version`, e.g. `25A352` |
| `DTPlatformVersion` | `xcrun --show-sdk-version` |
| `BuildMachineOSBuild` | `sw_vers -buildVersion` |
| `DTXcode` and `DTXcodeBuild` | the first GA Xcode release that ships the SDK build. Command Line Tools have no Xcode version of their own. |

`xcode_for_sdk_build` in `package_app.sh` maps SDK `25A352` to Xcode 26.0 (`2600`,
`17A324`).

When the Command Line Tools update to a new SDK build, the script handles it as follows:
1. It looks up the SDK build on xcodereleases.com.
2. If that lookup fails, it stops and asks you to set `DT_XCODE` and `DT_XCODE_BUILD`.

Add the new mapping to `xcode_for_sdk_build` so releases stay reproducible offline.

## Stale files in the Command Line Tools

Command Line Tools that were updated in place can keep files from older releases that no
installer package owns any more (`pkgutil --file-info <file>` lists no package). Apple's
SwiftPM then fails in one of two ways:

| File | Error |
| --- | --- |
| `usr/include/swift/module.modulemap` (Swift 5.9, 2023) | `redefinition of module 'SwiftBridging'`, often followed by a misleading `this SDK is not supported by the compiler` |
| `usr/lib/swift/pm/*/*.swiftmodule/*.private.swiftinterface` (Swift 5.10), next to newer public interfaces | `Undefined symbols … PackageDescription.Package` when SwiftPM links `Package.swift` |

In App Store mode, `package_app.sh` detects both and works around them without changing the
toolchain:
- It maps the old module map to an empty file with a VFS overlay (`-vfsoverlay`, passed
  through `-Xswiftc` and `-Xbuild-tools-swiftc`).
- It copies `ManifestAPI` and `PluginAPI` into `.build-mas/appstore/toolchain/pm`, without
  the stale private interfaces, and points `SWIFTPM_CUSTOM_LIBS_DIR` at the copy.

It prints a `NOTE` with the files it found. To fix the machine for good, delete those files
with `sudo rm`, or reinstall the Command Line Tools
(`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`).

## Publishing the website

App Review opens the privacy policy and support URLs, and a page that does not load is a
rejection. The site lives in `docs/`, and GitHub Pages serves it from `main`, folder `/docs`,
at https://flatoy.github.io/vibescribe/:

| URL | Page |
| --- | --- |
| https://flatoy.github.io/vibescribe/ | `docs/index.html` (marketing URL) |
| https://flatoy.github.io/vibescribe/privacy/ | `docs/privacy/index.html` (privacy policy URL, and the app's Settings > About > Privacy Policy link) |
| https://flatoy.github.io/vibescribe/support/ | `docs/support/index.html` (support URL) |

1. Commit `docs/` and push `main`.
2. Wait for the Pages build (repository Settings > Pages, or
   `gh api repos/flatoy/vibescribe/pages --jq .status` reports `built`).
3. Run `scripts/release_appstore.sh`. Its preflight prints each URL with its HTTP status.

## Sandbox smoke test

To check that the sandboxed build launches and works without touching the real app, build
an ad-hoc signed copy under a separate bundle ID:

```sh
DISTRIBUTION=appstore SIGNING_MODE=adhoc SCRATCH_PATH=.build-mas \
  OUTPUT_DIR="$PWD/dist/sandbox-smoke" bash package_app.sh release
open -n dist/sandbox-smoke/VibeScribe.app
```

To skip the setup window and go straight to the model download, launch it with
`open -n dist/sandbox-smoke/VibeScribe.app --args -VibeScribe.CompletedOnboarding YES`. The
argument only lasts for that launch and is not saved.

- **Bundle ID.** The test app is built as `io.m10s.vibescribe.sandboxtest`, or
  `ADHOC_BUNDLE_ID` if set. The build refuses to use `io.m10s.vibescribe`. The test app
  therefore gets its own container
  (`~/Library/Containers/io.m10s.vibescribe.sandboxtest`) and its own privacy permissions.
- **Signing.** It is signed with the same entitlements as the release build, but has no
  profile and no application identifier.
- **Checking for sandbox denials.** Run:

  ```sh
  /usr/bin/log show --last 10m --style compact --predicate \
    '(subsystem == "com.apple.sandbox.reporting" OR sender == "Sandbox") AND eventMessage CONTAINS "VibeScribe"'
  ```

  Most denials are reported by `sandboxd` under the `com.apple.sandbox.reporting`
  subsystem, not by the kernel's `Sandbox` sender, so keep both. In zsh, `log` without a
  path is a shell builtin, so use `/usr/bin/log`. One denial is expected at every launch:
  `deny(1) mach-lookup com.apple.universalaccessAuthWarn`. AppKit asks for it when the
  shortcut's global key monitor is installed. It is the Accessibility prompt service, which
  the sandbox blocks, so the app never uses it (see
  [Accessibility in the sandbox](#accessibility-in-the-sandbox)).
- **Cleaning up.** Quit the test app. Reset its privacy permissions while the app is still on
  disk, then delete the container:

  ```sh
  tccutil reset All io.m10s.vibescribe.sandboxtest
  rm -rf ~/Library/Containers/io.m10s.vibescribe.sandboxtest \
    "$HOME/Library/Application Scripts/io.m10s.vibescribe.sandboxtest"
  ```

  `tccutil` finds the bundle ID through Launch Services. Once the test app has been deleted,
  it fails with `No such bundle identifier … (OSStatus error -10814)`, and the permissions
  stay in the privacy lists. Rebuild the test app to reset them.

The test app also shows up as "VibeScribe" in the menu bar and in the privacy lists. Quit
it, or kill it by its PID rather than its name, so the installed app keeps running.

### Transcription in the sandbox without the UI

`VibeScribeTests --model-smoke <model folder> <audio> [language] [terms]` loads the model and
transcribes a file. To run it sandboxed, wrap the binary in a bundle and sign it with only the
sandbox entitlement:

1. Build the tests with Apple's Swift in a separate scratch path. Add the workaround flags
   from [Stale files in the Command Line Tools](#stale-files-in-the-command-line-tools) if
   your tools need them.

   ```sh
   xcrun swift build --product VibeScribeTests --scratch-path .build-mas/sbx-tests
   ```

2. Put the binary in `VibeScribeTests.app/Contents/MacOS/`, add an `Info.plist` with
   `CFBundleIdentifier` `io.m10s.vibescribe.sandboxtest.tests`, and sign it with
   `codesign --force --sign - --entitlements <file with com.apple.security.app-sandbox>`.
   A sandboxed binary without a bundle identifier stops with SIGTRAP.
3. Run it once with no arguments to create its container.
4. Copy the model there, for example
   `cp -Rc ~/Library/Containers/io.m10s.vibescribe.sandboxtest/Data/Library/Application\ Support/io.m10s.vibescribe.sandboxtest/WhisperModel-* <tests container>/Data/tmp/model`.
   Then make an audio file with
   `say -o <tests container>/Data/tmp/speech.wav --data-format=LEI16@16000 "…"`.
5. Run `VibeScribeTests.app/Contents/MacOS/VibeScribeTests --model-smoke <model> <audio> en "<terms>"`.

The two `model manifest pins a complete remote download` checks always fail in the sandbox,
because they read `scripts/` from the repository.

### End-to-end checklist

Run this on the sandboxed test app before every submission. Use the
[sandbox smoke test](#sandbox-smoke-test) build, so the real app's permissions and data are
untouched.

1. Setup window: the Microphone card's button and the footer say **Continue**. There is no
   **Skip for now** until macOS has asked for the microphone, and **Continue** shows the
   microphone prompt.
2. Input Monitoring: the prompt appears, and the shortcut works in another app once it is
   turned on.
3. Accessibility: the prompt ("would like to control this computer using accessibility
   features") appears, and VibeScribe is listed under Privacy & Security > Accessibility.
   Once it is turned on, dictating into TextEdit pastes the text. Without it, the text is
   copied and the overlay says Copied.
4. The model downloads into the container, prepares, and the first dictation transcribes.
5. Menu bar during setup: the header says "Speech model not downloaded" before a download
   has started, the menu offers Settings, and a pause shows "Download paused" and
   **Resume download**.
6. Settings > About > Privacy Policy opens https://flatoy.github.io/vibescribe/privacy/.
7. No sandbox denials other than the expected `com.apple.universalaccessAuthWarn` one.

Last results (build 6, 2026-10-02, macOS 15.6, ad-hoc test build from Apple Swift 6.2):
- The test app linked against the macOS 26 SDK launches in the sandbox. The only denial is
  the expected `com.apple.universalaccessAuthWarn` one.
- Passed without the UI, on a test build of the same code that was still linked with
  `sdk 14.0`:
  - The model (629.5 MB) downloaded into the container in about 35 seconds.
  - CoreML compiled the model in the container's cache. The only sandbox denial was
    `com.apple.universalaccessAuthWarn`.
  - The sandboxed `--model-smoke` loaded the model in 54 seconds and transcribed the
    sentence exactly, with English, automatic detection and vocabulary (4 of 4 model checks).
- Not run: steps 1 to 3, 5 and 6. They need someone at the Mac to answer the permission
  prompts.

## Notes for App Review and future changes

- **Entitlements.** The entitlements are deliberately minimal: `app-sandbox`,
  `network.client` (model download from huggingface.co) and `device.audio-input`.
  - Global hotkeys need Input Monitoring, and pasting needs Accessibility (`CGEventPost`).
    Both are privacy permissions that the user grants, and neither needs an entitlement.
  - Explain both in the review notes.
- <a id="accessibility-in-the-sandbox"></a>**Accessibility in the sandbox.** The sandbox
  blocks `com.apple.universalaccessAuthWarn`, so `AXIsProcessTrustedWithOptions` cannot show
  its prompt there. When `APP_SANDBOX_CONTAINER_ID` is set, `PasteAccess` (in
  `Permissions.swift`) uses `CGPreflightPostEventAccess` and `CGRequestPostEventAccess`
  instead. They go through `tccd`, which the sandbox allows, and they ask for exactly what
  pasting needs: permission to post the ⌘V keystroke. It is listed under Accessibility in
  System Settings. The Developer ID build still uses the AX calls.
- **Permission screen (guideline 5.1.1(iv)).** The setup window explains each permission
  before macOS asks for it. Its buttons say **Continue**, not "Allow", and there is no way
  past the screen until macOS has asked for the microphone.
- **Sandbox container.** The sandboxed app keeps its data in its container, separate from
  the Developer ID build. A user who installs the App Store version therefore downloads the
  Whisper model again.
- **Hardened runtime.** The hardened runtime is optional for the Mac App Store. It is kept
  on so the App Store build is signed the same way as the Developer ID build. If CoreML
  ever fails to load models under it, try `HARDENED_RUNTIME=0`.
- **Architecture.** The build is arm64 only (Apple silicon), because on-device Whisper
  through WhisperKit is built for Apple silicon. The package declares
  `hostArchitectures="arm64"`, so the App Store only offers it on Apple silicon Macs.
- **New nested code.** If you add frameworks, helpers or XPC services, the signing step
  already signs nested Mach-O files and bundles inside-out. Sandboxed helper executables
  get `com.apple.security.app-sandbox` and `com.apple.security.inherit`.
