# VibeScribe

![VibeScribe header](assets/readme-header.png)

A blazing fast transcription app with smart formatting, powered by Deepgram.

## What this gives you
- Menu bar status item (Settings + Quit)
- Minimal settings window (API key + language)
- Push-to-talk hotkey (hold to record)
- Listening overlay
- WebSocket streaming to Deepgram
- Live in-place transcription while you speak
- Cross-app-safe live typing using finalized transcript chunks
- Logs tab for connection/debugging
- Auto-paste transcript on release (requires Accessibility permission)

## Requirements
- macOS 13+
- Xcode or the Swift toolchain that ships with your current macOS

## Install
Package a `.app` bundle for permanent install:
```bash
bash package_app.sh
```
This creates `VibeScribe.app` in the repo root. Move it to `/Applications`, launch it once, then add it to Login Items to run at login (System Settings > General > Login Items).

To customize the bundle name, id, or version, edit `version.env`.

## Deepgram API Key
Sign up for a free Deepgram API key at https://console.deepgram.com (new accounts typically include ~$200 in free credit).

## Run
From source (development):
```bash
swift run
```

## Build
```bash
swift build
```

## Test
```bash
bash scripts/test.sh
```
Requires `xcbeautify`:
```bash
brew install xcbeautify
```

## Usage
1. Launch the app (it appears in the menu bar).
2. Open the main window and paste your Deepgram API key.
3. Hold the Option hotkey to listen while pressed (push-to-talk).
4. Tap the Option hotkey to toggle listening on/off.
5. While recording, finalized transcript chunks are typed into the focused app.
6. If focus switches to another app during dictation, live typing pauses and transcription still finalizes safely.
7. The app restores your previous clipboard contents after pasting any fallback text.

## Permissions
- Microphone access is required.
- For global hotkeys, macOS may prompt for Input Monitoring or Accessibility permissions.

## Customization
- Hotkey: `Sources/VibeScribeCore/HotkeyListener.swift`
- Overlay UI: `Sources/VibeScribeCore/UI/OverlayView.swift`
- Deepgram model/language options: `Sources/VibeScribeCore/DeepgramClient.swift` and `Sources/VibeScribeCore/DeepgramLanguage.swift`

## Contributing
Issues and PRs are welcome.
1. Open an issue describing the change or bug.
2. Keep changes focused and avoid adding backward-compatibility logic unless needed.
3. If you add tests, include updates in the same PR and run `bash scripts/test.sh`.

## License
MIT license. In short, you can use, modify, and distribute the code (including commercially) as long as you keep the copyright notice and license text, and there is no warranty. See `LICENSE`.

## Notes
This is intentionally minimal to keep the architecture easy to extend. The API key is stored in `UserDefaults` in plaintext for convenience.
