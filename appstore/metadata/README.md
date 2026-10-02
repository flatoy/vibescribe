# App Store metadata

These files were created by `asc metadata init` and hold the en-US listing. `app-info/en-US.json` holds the name, subtitle and privacy policy URL. `version/1.0.0/en-US.json` holds the description, keywords, promotional text, marketing URL and support URL. The empty template keys (`whatsNew`, `privacyChoicesUrl` and `privacyPolicyText`) are left out, because `asc metadata validate` rejects empty strings, and a key that is missing leaves the App Store Connect value unchanged. A first version can't have `whatsNew`, so add it back starting with 1.0.1. To publish, run `asc metadata validate --dir appstore/metadata`, preview with `asc metadata apply --app "$ASC_APP_ID" --version 1.0.0 --platform MAC_OS --dir appstore/metadata --dry-run`, then run the same command without `--dry-run`. Don't add any other keys, because the schema rejects unknown ones. App Review notes are in `../review-notes.md` and are entered separately. The screenshots in `../screenshots/en-US` are rendered from the app's real SwiftUI views by `swift run --scratch-path .build-shots VibeScribeScreenshots --appstore appstore/screenshots/en-US` (see `Tools/VibeScribeScreenshots/AppStoreShots.swift`). Their headlines, in order:

1. Hold a key. Speak. Done.
2. Works in any app.
3. Private. On-device. No account.
4. Dictate in 100 languages.
5. Every word, saved.
6. Names, spelled your way.
