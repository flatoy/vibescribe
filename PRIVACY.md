# VibeScribe Privacy Policy

**Effective date: 2 October 2026**

This policy explains how VibeScribe, the dictation app for Mac, handles your information. It covers VibeScribe 1.0 and later as distributed on the Mac App Store, and the VibeScribe website at https://flatoy.github.io/vibescribe/.

## The short version

- **VibeScribe does not collect any personal data.** Nothing you say, dictate or type is sent to us or to anyone else.
- **Your voice is processed on your Mac.** The audio is held in memory only while it is being transcribed, then discarded. It is never saved to disk and never uploaded.
- **Your transcripts, history, vocabulary and settings stay on your Mac**, and you can delete them at any time.
- **The only network access is downloading the Whisper speech model** from Hugging Face (huggingface.co). Like any download, this reveals your Mac's IP address to Hugging Face.
- **There are no analytics, ads, tracking, third-party SDKs or accounts.**

## Who is responsible

VibeScribe is published by Hello World AS ("we", "us"). Hello World AS is the controller for any personal data covered by this policy. VibeScribe is designed so that we never receive personal data from the app. You can contact us at https://github.com/flatoy/vibescribe/issues.

## What we collect

Nothing. VibeScribe has no servers of its own and no sign-in. We do not receive your audio, transcripts, history, vocabulary, settings, usage statistics, crash reports, device identifiers, contacts, location or any other information from the app. That is why VibeScribe's App Store privacy label says **Data Not Collected**.

If you have turned on **Share with app developers** in System Settings > Privacy & Security > Analytics & Improvements, Apple may share crash reports and anonymous usage statistics with us. That sharing is controlled by you and by Apple under Apple's privacy policy. VibeScribe adds nothing of its own to it.

## Microphone and audio

VibeScribe listens only while you hold your dictation shortcut, or after you tap it to start hands-free dictation, until you stop or cancel. The audio:

- comes from the microphone you choose in Settings > General,
- is kept in your Mac's memory while the Whisper model transcribes it on your Mac,
- is discarded as soon as the text is ready or you cancel with esc,
- is never written to disk, never uploaded and never shared.

While Settings > General is open, VibeScribe also reads the microphone's input level to draw the level meter next to the microphone picker. The level is not recorded or stored.

## Your keyboard (Input Monitoring)

To notice your shortcut while you work in other apps, macOS requires the Input Monitoring permission. VibeScribe checks each key event only to see whether it matches your shortcut (or esc while recording), then ignores it. It does not record, store or send what you type.

## Pasting (Accessibility) and the clipboard

To paste the text into the app you are using, VibeScribe puts the transcript on the clipboard and sends a Command-V keystroke. Sending that keystroke requires the Accessibility permission. Without it, the transcript is copied to the clipboard and you paste it yourself.

By default, VibeScribe puts back whatever was on your clipboard about a quarter of a second after pasting. You can turn this off with "Restore clipboard after pasting" in Settings > General. Your previous clipboard contents are held in memory only for that moment.

If Handoff is turned on, macOS's Universal Clipboard can make clipboard contents, including a transcript, briefly available to your other Apple devices signed in to the same Apple Account. That is a macOS feature handled by Apple.

## What is stored on your Mac

Everything below stays on your Mac and is never sent anywhere. Files are kept in VibeScribe's own App Sandbox container at `~/Library/Containers/io.m10s.vibescribe`.

- **Transcript history.** When history is on, each transcript is saved with its date and time, its language, the length of the recording, and the name of the app it was pasted into (or "Clipboard"). History is kept for 30 days by default. In Settings > History you can choose Don't keep history, Keep 1 day, Keep 7 days, Keep 30 days or Keep forever. Older entries are deleted automatically.
- **Your latest transcript** is also kept in memory, even when history is off, so that you can copy it from the menu bar. It is gone when you quit VibeScribe.
- **Settings and vocabulary.** Your shortcuts, languages (chosen, pinned and recently used), microphone choice, sound, pasting and menu bar options, history setting, chosen speech model and the vocabulary words you enter are stored in the app's standard macOS preferences.
- **Speech models.** The Whisper model files, about 630 MB for large-v3 and about 650 MB for large-v3 turbo, are stored in the app's Application Support folder.
- **Activity log.** VibeScribe keeps a short technical log in memory, such as "Recording stopped" or "Pasted into the active app". It never contains what you said, it is not saved to disk, and it is cleared when you quit. If you click **Copy diagnostic report** in Settings > About & diagnostics, the log, together with the app and macOS versions, model status, permission status and your main settings, is copied to your clipboard so you can decide whether to share it. Nothing is sent automatically.

## How to delete your data

- **History:** Settings > History > Clear History. Choosing "Don't keep history" also deletes all saved transcripts straight away.
- **Vocabulary:** delete the words in Settings > Language.
- **Speech models:** Settings > Speech model > Delete removes a model you are not using. Show in Finder opens the folder that holds the models and your history.
- **Everything:** quit VibeScribe, move it to the Trash, then delete the folder `~/Library/Containers/io.m10s.vibescribe` (in Finder, choose Go > Go to Folder). This removes your history, settings, vocabulary and models. You can also remove VibeScribe from System Settings > Privacy & Security (Microphone, Input Monitoring and Accessibility) and from System Settings > General > Login Items.

We hold no data about you, so there is nothing for us to delete on our side.

## Network access

VibeScribe connects to the internet for one purpose only: downloading speech model files from Hugging Face, Inc. at huggingface.co, which may hand large files over to its content delivery network.

- **When:** during setup, after you click "Set up VibeScribe"; when you choose to download another model, such as large-v3 turbo, in Settings > Speech model; and if the model files on your Mac are missing or damaged, when you download them again.
- **What is requested:** fixed versions of public files, namely Argmax's Core ML conversion of Whisper (argmaxinc/whisperkit-coreml) and OpenAI's Whisper tokenizer files (openai/whisper-large-v3). Each file is checked against a known SHA-256 checksum before it is used.
- **What is sent:** only ordinary download requests. No audio, transcripts, vocabulary, settings, account details or identifiers are sent. The download keeps no cookies or cache afterwards.
- **What Hugging Face sees:** like any web server, Hugging Face and its delivery network receive your Mac's IP address and standard request details, such as the time of the request and a basic description of the software making it. Hugging Face handles this under its own privacy policy: https://huggingface.co/privacy. We do not receive this information.

Once the model is downloaded, VibeScribe works without an internet connection. Transcription never uses the network. VibeScribe watches whether your Mac is online only so that it can resume an interrupted download. That check uses macOS's network status and sends nothing.

## Permissions at a glance

| Permission | Why VibeScribe asks | Without it |
| --- | --- | --- |
| Microphone | To hear you while the shortcut is held | VibeScribe cannot dictate |
| Input Monitoring | To notice your shortcut in other apps | The shortcut does not work in other apps |
| Accessibility | To paste the text for you | The text is copied and you paste it with Command-V |

You can change these at any time in System Settings > Privacy & Security.

## Third-party components

VibeScribe uses WhisperKit, open-source software by Argmax, Inc., to run OpenAI's Whisper speech recognition models on your Mac. Both run entirely on your Mac inside VibeScribe and send nothing to Argmax, OpenAI or anyone else. VibeScribe contains no analytics, advertising, crash-reporting or tracking code.

## Children

VibeScribe is a general-purpose tool and is not directed at children. It does not collect personal data from anyone, including children. If you believe a child has shared personal information with us, for example in a public GitHub issue, contact us and we will help remove it.

## This website

The VibeScribe website is hosted on GitHub Pages. It uses no cookies, analytics, ads, trackers, web fonts or third-party scripts. As the host, GitHub processes technical data such as your IP address to deliver the pages and keep them secure, under the GitHub General Privacy Statement: https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement.

Support happens in GitHub issues, which are public. Please do not post personal information, recordings or private transcripts there. If you contact us on GitHub, we see your GitHub username and what you write, and we use it only to reply to you.

## Your rights

Depending on where you live, for example in the EU or EEA under the General Data Protection Regulation, you may have the right to access, correct or delete your personal data, or to object to its processing. Because VibeScribe sends us no personal data, we normally hold nothing about you. Your data lives on your Mac, under your control, and you can delete it as described above. If you have shared something with us on GitHub, we will help you with any request about it. You also have the right to lodge a complaint with your local data protection authority.

## Changes to this policy

If we change how VibeScribe handles information, we will update this policy and its effective date. If a change affects what the app collects or sends, we will update this policy before releasing that version and mention it in the release notes. Earlier versions are available in the history of this file at https://github.com/flatoy/vibescribe/commits/main/PRIVACY.md.

## Contact

Questions about privacy? Open an issue at https://github.com/flatoy/vibescribe/issues.

Hello World AS
