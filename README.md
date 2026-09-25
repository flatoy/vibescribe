# VibeScribe

![VibeScribe header](assets/readme-header.png)

A menu bar, push-to-talk transcription app for Mac. Speech is transcribed on your Mac with [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift). On first launch, VibeScribe downloads its multilingual model with visible progress; afterward transcription works offline. No account or API key is needed.

## Features

- Hold Right Option to record, then release to transcribe and paste into the active app.
- Tap Right Option to toggle recording on and off.
- Press Option+Shift to search the language list.
- Choose Automatic language detection or one of the 100 languages supported by the downloaded Whisper large-v3 model.
- View the latest transcript and local logs in the app window.
- Restore the previous clipboard contents after pasting.

Local transcription starts after recording stops, so pasting may take a moment. The overlay shows “Transcribing” until it finishes.

## Requirements

- macOS 14 or later on an Apple Silicon Mac
- An internet connection for the one-time speech model download (about 630 MB)
- Microphone permission
- Input Monitoring permission for global hotkeys and Accessibility permission for automatic pasting

Building from source requires a Swift 6.2 or newer toolchain. The optional model prefetch script uses Python 3.

## Install

Run the packaging script:

```bash
bash package_app.sh
```

This creates a small `VibeScribe.app` without model weights. Move it to `/Applications` and open it. On first launch, the app downloads and verifies the pinned [Whisper large-v3 Core ML model](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_626MB) and [tokenizer](https://huggingface.co/openai/whisper-large-v3), showing progress in its window. Files are stored in Application Support, reused on later launches, and never downloaded during transcription. If a download fails, use **Try Again**; completed files are kept. You can add the app to Login Items in System Settings if desired.

The default local build is ad-hoc signed. Distribution to other Macs requires Developer ID signing and notarization for a smooth first launch.

To customize the bundle ID or version, edit `version.env`. The script supports the existing `ARCHES`, `SIGNING_MODE`, and `APP_IDENTITY` build settings.

## Develop

Run from source with the same first-launch download flow:

```bash
swift run
```

To prefetch the model into the ignored build cache for development or offline smoke tests, run `python3 scripts/download_whisper_model.py`.

Build and run the tests with:

```bash
swift build
swift run VibeScribeTests
```

The tests use a small executable harness, so Xcode is not required.

## Languages

The language picker includes the 100 language codes in WhisperKit, all of which have tokens in the downloaded multilingual Whisper large-v3 tokenizer. The language list shows what the model can be asked to transcribe; accuracy still varies by language and recording quality. Older saved Deepgram regional selections are mapped to their base language where available, and the old API key is removed from local preferences.

## Customization

- Hotkeys: `Sources/VibeScribeCore/HotkeyListener.swift`
- Overlay: `Sources/VibeScribeCore/UI/OverlayView.swift`
- Language choices: `Sources/VibeScribeCore/WhisperLanguage.swift`
- Pinned model download: `scripts/whisper_model_manifest.json`

## Contributing

Issues and PRs are welcome. Keep changes focused and run `swift run VibeScribeTests` before submitting.

## License

VibeScribe is MIT licensed; see `LICENSE`. Licenses and notices for WhisperKit and the downloaded speech model are in `Sources/VibeScribe/Resources/Licenses`.
