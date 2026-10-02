VibeScribe is a menu bar app for push-to-talk dictation. Hold a key, speak, and let go: the app transcribes your speech on the Mac with Whisper (via WhisperKit) and pastes the text where the cursor is. It is free, with no account, login, subscription or in-app purchases. All speech processing happens on device.

FIRST LAUNCH
A setup window opens with four steps: Welcome, Permissions, Speech model, Try it. The Whisper large-v3 model (about 630 MB) starts downloading from huggingface.co when you click "Set up VibeScribe" on the first screen, and keeps going while you grant permissions. Depending on the connection it can take a few minutes. After that, preparing the model for the Mac takes about a minute, once. The download can be paused and resumes on its own if the connection drops, and every file is checked against a SHA-256 checksum. Network access (the network.client entitlement) is used only for this download, and for the optional turbo model. After that the app works fully offline.

After setup, VibeScribe runs from a waveform icon in the menu bar (no Dock icon). That menu has Settings, History, pinned languages and Pause shortcut.

HOW TO TEST
1. Finish setup and grant the three permissions. The "Try it" box at the end works even before Input Monitoring is granted.
2. Open TextEdit, create a document and click in it.
3. Hold Right Option, say a sentence, and let go. A pill below the menu bar shows Listening, then Transcribing, then "Pasted" with a word count. The text appears in TextEdit.
4. Hands-free: tap Right Option once, speak for as long as you like, then tap it again to finish. Press Esc during a recording to discard it.
5. Hold Right Option without speaking: the pill shows "No speech heard" and nothing is pasted.
6. Language picker: press Option+Shift anywhere, type to search 100 languages, and press Return to choose. ⌘1 to ⌘3 pick pinned languages (Automatic and English by default), and ⌘P pins the highlighted language.
7. Without Accessibility, the pill shows "Copied" and the transcript is on the clipboard, ready for ⌘V.
8. Optional: Settings > Speech model offers Whisper large-v3 turbo, a separate download of about 650 MB that transcribes roughly 3× faster. Dictation keeps working while it downloads.

The shortcut can be changed under Settings > Shortcut. Settings also has the microphone choice, paste or clipboard-only output, vocabulary and transcript history.

WHY EACH PERMISSION IS NEEDED
- Microphone: records your voice while the shortcut is held, or during hands-free dictation. The General settings page also shows a live input level while it is open. Audio stays in memory and is never written to disk or sent anywhere.
- Input Monitoring: detects the push-to-talk key (Right Option by default) and the language picker shortcut while other apps are in front. The app compares each key event with the configured shortcut and does nothing else with it. Keystrokes are not recorded, stored or transmitted.
- Accessibility: pastes the transcript into the frontmost app by posting one simulated ⌘V keystroke. The app does not read other apps' content or interface. This permission is optional: without it, VibeScribe copies the transcript to the clipboard and the user pastes it.

Each permission is explained in the setup window before macOS asks for it. Once macOS has asked for the microphone, "Skip for now" lets you continue without granting them.

PRIVACY
- No account or login, and no VibeScribe server. No analytics, tracking or ads.
- Transcription runs entirely on the Mac. Audio is never saved or uploaded.
- Transcript history is stored only in the app's container on the Mac (kept for 30 days by default). It can be set to 1 or 7 days, forever, or off, and cleared at any time.
- App Privacy: Data Not Collected.

Source code (MIT): https://github.com/flatoy/vibescribe
Support: https://flatoy.github.io/vibescribe/support/
