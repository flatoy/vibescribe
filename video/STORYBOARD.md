# VibeScribe launch film: "A Day Out Loud"

- **Launch film:** 58.4 s at 1920×1080 and 60 fps.
- **App Store App Preview ("Hold. Talk. Pasted."):** 29.3 s at 1920×1080 and 30 fps.
- **Machine-readable spec:** [`spec.json`](spec.json). Where the two differ, the spec is authoritative for timings.

## Producer's call

The brief mentioned two director treatments, but only one arrived: **"A Day Out Loud"** (58.0 s, with a 29.5 s preview). There was nothing to weigh it against, so I judged it on its own merits. It is a strong spine, and I kept its shape:

- **One day, four places to type.** A single person moves from email to terminal to chat to notes, a little later on Thursday each time. The use cases read as a life rather than a feature list.
- **The loop is taught once, slowly.** The email beat runs the full loop at a pace a first-time viewer can follow: hold, Listening, release, Transcribing, the whole text lands, "Pasted 19 words". Every later beat can then move faster.
- **Spectrum bars carry the transitions.** The colourful bars are the app's signature. They become the menu bar icon in the cold open, wipe between scenes, and contract into the app icon at the end.
- **The Wi-Fi plant pays off.** The menu bar shows Wi-Fi off from the first frame of the evening note. The privacy beat then reveals it, so "runs on your Mac" is something the viewer has just watched happen, not just a claim.
- **The preview cut is mostly app footage.** It runs three loops back to back with no price words.

I changed the following so that every frame matches the real app (checked against `Sources/`):

1. **24-hour clock everywhere:** Thu 09:12, 11:47, 16:05 and 19:48. This matches History's `HH:mm` rows and the App Store screenshots.
2. **Transcribing is never a flash.** It holds 1.2 s in the hero loop and at least 0.8 s elsewhere. Large-v3 takes a moment, and the film should not imply otherwise.
3. **The "~3× faster" montage card is cut.** In the app that figure compares large-v3 turbo with large-v3, not voice with typing, so a card would mislead. The model appears instead in the privacy beat, as the real Settings › Speech model card ("Works offline · Speech never leaves this Mac · ✓ Ready").
4. **The shortcut card changes Right ⌥ to Right ⌘, not fn.** The recorder masks out `.function`, so a lone fn press cannot be recorded today. Right ⌘ is a real, supported change, and the Reset button appears as it does in the app.
5. **The menu bar icon is accurate.** While recording it shows colourful bars and a timer, with no highlight capsule (the README art adds one; the real status item doesn't). The menu bar timer rounds and the pill timer counts whole seconds, so they can differ by a second, as they do in the app.
6. **All host windows are generic and drawn on stage:** "Inbox", "Terminal" (with a generic `agent` command), "Chat" and "Notes". There is no third-party chrome, logo or brand.
7. **Language continuity.** After the German reply, the evening scene is back on English, switched off-screen. The montage picker shows the day's history: Recent German and Japanese, with English pinned.
8. **The keycap overlay is a film device.** It is a key indicator, not app UI, and it uses the real `Keycap` view. The spec says so explicitly.
9. **Pricing words are confined to the launch film.** "No subscription" and "Free" appear only there. The App Preview contains no pricing words, no "App Store" and no URL.
10. **Lines were synthesised and measured before timing.** All four lines were generated with the chosen voice and transcribed back. The timeline is anchored to the measured lengths, and every on-screen word count matches the pasted transcript.

## Concept

VibeScribe opens on its main promise, that it is free, and then spends one ordinary Thursday proving the loop. She holds Right ⌥ and talks, lets go, and the whole text lands wherever her cursor was.

- **Two kinds of type:**
  - kinetic captions, which carry the story;
  - the app's own UI, which carries the proof.
- **No narrator.** The only voice is hers, talking to her Mac.
- **Sound:** a light, original music bed and soft UI sounds frame the voice.
- **Ending:** the film closes on the icon, "Free on the Mac App Store" and the website.

## Cast and world

| Element | Detail |
|---|---|
| Person | Off-screen. Voice: Cartesia "Cathy" (`e8e5fffb-252c-436d-b842-8879b84445b6`), a relaxed, warm young adult who talks to her Mac rather than to an audience |
| Desktop | The app's wallpaper recipe (indigo to plum with blue and rose glows) and a 26 pt translucent menu bar. Menu bar items: apple.logo, the front app's name and menus, the VibeScribe item, Wi-Fi, battery and the clock |
| Inbox, 09:12 | Compose "Re: Offsite agenda for Thursday" to Priya Raman. The quoted agenda puts the budget review last, at 15:30 |
| Terminal, 11:47 | `trailhead — zsh`, `❯ agent`, prompt "Coding assistant · describe the change, ⏎ to send", `› █` |
| Chat, 16:05 | Lena Fischer: "Wir gehen heute Abend Pizza essen. Kommst du mit?" |
| Notes, 19:48 | "To do" with the item "Offsite bus booked" and an empty bullet. Wi-Fi is off |

## Shot table: launch film (60 fps, 58.4 s)

The overlay pill sits centred, 16 pt below the menu bar. Captions are bottom-left kinetic type unless noted.

| Time (s) | Picture | On-screen text | Sound |
|---|---|---|---|
| **A. Cold open** | | | |
| 0.00–0.80 | Fade up from black on the blurred wallpaper. Seven spectrum bars breathe in the centre to the beat (the app's own bar math) | | Pad swell |
| 0.80–1.60 | **"Free"** slams in and a spectrum rule draws under it | **Free** | Impact |
| 1.60–3.50 | "Free" shrinks into the first word of the line. The rest rises in word by word | **Free voice transcription** / **for your Mac.** (from 2.40) | Light groove, ticks |
| 3.60–4.00 | T1: the bars shrink, turn white and fly into the menu bar, becoming the VibeScribe waveform icon with "EN". The wallpaper sharpens, the Inbox window fades in, and the camera lands at 2× on the status item | | Whoosh, glass tap |
| **B. Inbox reply: the loop, slowly** | | | |
| 4.00–5.20 | Hold on the idle "EN" status item. The camera eases out to the compose window | | Minimal groove |
| 5.50 | The Right ⌥ keycap presses at the bottom of the frame | | Key down |
| 5.55 | The pill springs in with live bars and "Listening 0:00". The menu bar icon turns colourful and shows a timer | **Hold Right ⌥ and talk.** (5.70–9.60) | Start tick |
| 5.80–11.52 | She dictates **L1**. The bars follow her voice and the timer counts up to 0:06. The camera pushes in slowly, drifting right so the colourful status item stays in frame. Every recording keeps it in view until the punch-in | | Voice, music ducked |
| 11.72 | Key released | **Let go.** | Key up |
| 11.92 | The pill shows "Transcribing" with an EN badge, a shimmer and the thinking bars. The menu bar shows white thinking bars. The camera punches in to 1.75× | | Stop pop |
| 13.12 | **The whole reply lands at once** in the body. The pill shows "✓ Pasted 19 words" | **Let go. It's pasted.** | Soft text-land tick |
| 14.42–15.30 | The pill exits. The pointer moves to Send and clicks, and the window drops away as sent | | Click, soft whoosh |
| 15.20–16.00 | T2: bars rise, covering the frame at 15.60 | | Rising whoosh |
| **C. Coding agent** | | | |
| 15.60–16.35 | The trailhead terminal with the agent prompt `› █`. Menu bar clock 11:47 | **Talk to your coding agent.** (16.70–20.60) | Hats join |
| 16.35 / 16.40 | Key down, then "Listening" | | Key, start tick |
| 16.65–23.00 | She dictates **L2** | | Voice |
| 23.20 / 23.40 | Release, then "Transcribing" with EN. Punch in to 1.75× | | Key up, stop pop |
| 24.30 | The whole prompt lands after `› `. The pill shows "Pasted 18 words" | | Text-land tick |
| 24.75–25.25 | ↩ is pressed. The agent prints "◇ Reading Sources/Upload/UploadClient.swift", "◇ Plan: retry with exponential backoff, 0.5 s → 8 s" and "⠋ Writing a test for the offline case…". The camera eases out to show them | | Return, faint ticks |
| 25.20–26.00 | T3: bars sweep left to right, covering at 25.60 | | Sweep whoosh |
| **D. Chat in German** | | | |
| 26.00 | Lena's message pops in. Menu bar clock 16:05 | | Receive blip |
| 26.60 | ⌥⇧ keycaps. The language picker slides down: PINNED Automatic ⌘1, English ⌘2 ✓, Spanish ⌘3; RECENT Japanese, French; "now: en" | **Switch languages with ⌥⇧** (26.40–28.40) | Key, panel slide |
| 27.20–27.50 | She types g, ge, ger. The count goes 22 results, 6 results, 2 results. German · Deutsch is highlighted, Georgian · Ქართული below it | | Type ticks |
| 27.90 | ↩: the picker lifts away and the menu bar badge changes from EN to **DE** | | Return, panel lift |
| 28.50 / 28.55 | Key down, then "Listening" | **Reply in German.** (28.80–30.80) | Key, start tick |
| 28.80–31.90 | She dictates **L3** in German | | Voice |
| 32.10 / 32.30 | Release, then "Transcribing" with a **DE** badge. The camera punches in to 2.4× on the badge | | Key up, stop pop |
| 33.10 | The camera whips back as the German reply lands in the composer. The pill shows "Pasted 10 words" | | Whip, text-land tick |
| 33.70–34.25 | ↩ sends the message. Typing dots appear, then Lena replies: "Perfekt, bis später!" | | Send, receive |
| 34.80–35.60 | T4: bars fall, covering at 35.20 | | Falling whoosh |
| **E. Hands-free note** | | | |
| 35.20–35.90 | The Notes window "To do", in an evening grade. Menu bar clock 19:48, **Wi-Fi slashed** (planted, not pointed out) | | Filter closes a little |
| 35.90–36.05 | A quick tap on Right ⌥ (the keycap shows "tap"). "Listening" becomes **"Hands-free 0:00 · Tap ⌥ to stop · esc to cancel"** | **Tap for hands-free.** (36.10–38.20) | Key, start tick |
| 36.40–39.85 | She dictates **L4** with her hands off the keyboard | | Voice |
| 40.10–40.42 | A second tap, then "Transcribing" with EN | | Key, stop pop |
| 41.22 | The note lands on the empty bullet. The pill shows "Pasted 11 words" | | Text-land tick |
| **F. Offline and private** | | | |
| 42.40–42.80 | The camera whips to the menu bar at 3× and lands on the slashed Wi-Fi icon beside the VibeScribe item. Two ring pings | | Drums cut, whip, pings |
| 42.80–43.80 | Hold | **Wi-Fi off.** (centred) | Pad and sub |
| 43.80–44.40 | Pull back to the full desktop, which dims and blurs. The real **Settings › Speech model** card rises at the right: "Whisper large-v3 · In use · Most accurate · 100 languages" and "Works offline · Speech never leaves this Mac · ✓ Ready" | | Soft whoosh |
| 44.20–47.20 | Hold | **Runs on your Mac.** (44.20) / **Nothing leaves it.** (44.60). Chips: **No account** (45.20), **No API key** (45.40), **No subscription** (45.60) | Chip ticks, riser from 46.40 |
| **G. Montage on the drop (1.6 s per card)** | | | |
| 47.20–48.80 | The picker at 1.3×, with a ticker of the app's native language names (Deutsch, Español, 日本語, Français, Português, हिन्दी, 한국어, 中文, Italiano, Norsk, العربية, Tiếng Việt, Cymraeg, Èdè Yorùbá) | **100 languages.** / Or let Automatic detect it. | Drop hit |
| 48.80–50.40 | Settings › History shows today's four transcripts (19:48, 16:05, 11:47, 09:12). Typing "oat" in the search field leaves one row | **Searchable history.** / Stored only on this Mac. | Wipe, type ticks |
| 50.40–52.00 | Settings › Language › Vocabulary. Typing ", SwiftUI" changes the counter from **4 words** to **5 words** | **Custom vocabulary.** / Add names and jargon. | Wipe, type ticks |
| 52.00–53.60 | Settings › Shortcut: the Right ⌥ field shows "Press a key… esc" with a dashed accent border, then **Right ⌘** with the Reset button | **Your shortcut.** / Hold, tap, or both. | Wipe, click, key |
| **H. End card** | | | |
| 53.60–54.00 | Seven bars contract to the centre and bloom into the app icon | | Bloom |
| 54.20–58.40 | Icon | **VibeScribe** (54.20) / **Free on the Mac App Store** (54.60) / `flatoy.github.io/vibescribe` (55.00) | Final D major chord with a bell, ringing out |
| 57.90–58.40 | Fade to black | | Tail |

## Dictated lines

The spoken text and the pasted transcript are identical, with Whisper-style punctuation. Word counts use the app's rule (split on whitespace), which is the number the pill shows. Durations are measured after trimming silence. A check pass with Cartesia ink-whisper heard every word.

| Clip | Lang | Spoken = pasted transcript | Words | Length | Target start | Scene | Delivery |
|---|---|---|---|---|---|---|---|
| L1 | en | Hi Priya, looks great! Could we do the budget review first, so we end on the fun stuff? Thanks. | 19 | 5.72 s | 5.80 | B Inbox | Friendly, a small smile on "looks great" |
| L2 | en | Uploads keep failing on bad Wi-Fi. Add retries with backoff, and write a test for the offline case. | 18 | 6.35 s | 16.65 | C Terminal | Matter-of-fact, thinking aloud |
| L3 | de | Klingt gut! Ich bin dabei, komme aber ein bisschen später. | 10 | 3.10 s | 28.80 | D Chat | Casual native German, generated with `language: de` |
| L4 | en | Call the landlord about the heating. Oh, and buy oat milk. | 11 | 3.45 s | 36.40 | E Notes | Evening note-to-self, with an afterthought lift on the last part |

History rows derived from the real timing rules: 09:12 Inbox EN 0:06; 11:47 Terminal EN 0:07; 16:05 Chat DE 0:04; 19:48 Notes EN 0:04.

**Re-timing:** start times are targets. Every key, pill and paste event is anchored to its clip using the app's timing:

- **Hold:** key down 0.30 s before the voice; recording starts 0.05 s after key down.
- **Release:** key up 0.20 s after the voice ends; Transcribing starts 0.20 s after release.
- **Pasted:** appears after the scene's Transcribing hold and stays for 1.3 s.
- **Tap:** the first tap comes 0.50 s before the voice and is held for 0.15 s; the second tap comes 0.25 s after the voice ends.

If synthesis comes out longer, later events slide. If the film would pass 60 s, trim in this order: the B establishing hold, the F hold, the H tail.

## Sound design

The film's sounds are all original. None are Apple's sound files.

| Cue family | When | Character | Level |
|---|---|---|---|
| Start tick (app analogue) | At each recording start (key down + 0.05 s) | A glassy tick in the spirit of the system "Tink" the app plays when Play sounds is on | About −21 dB |
| Stop pop (app analogue) | At each stop (release + 0.2 s) | A soft bubble pop in the spirit of the system "Pop" | About −21 dB |
| Key down / key up | On every keycap press and release | A low-profile mechanical key, with a softer release | −20 to −23 dB |
| Text land (film only) | The frame the transcript lands | A very soft paper tick. The app itself makes no paste sound | −24 dB |
| Transition whooshes | T1 to T7 | Rise, sweep (panned left to right), fall, whip and bloom; pitched to the move | −16 to −22 dB |
| Chat blips | Lena's message, the send, the reply | Two-note blips | −24 to −26 dB |
| Picker | Slide in, type ticks, lift | Airy and short (0.18 s in, 0.14 s out) | −26 to −28 dB |
| Wi-Fi ping | 42.80 | Two sonar-like pings with the ring | −20 dB |
| Riser / drop | 46.40–47.20 | A noise and tonal riser into the drop hit | −16 / −12 dB |

The full cue list with exact times is in `spec.json` under `sfx` (62 cues).

## Music

- **Source:** original, generated procedurally at build time.
- **Tempo and key:** 150 BPM in a half-time feel (one bar = 1.6 s), D major, chords D–Bm–G–A at one chord per bar.
- **Mood:** warm and optimistic: soft plucks, a round sub, an airy pad, brushed hats and a glass bell for accents. Never busy under the voice.

| Section | Time (s) | Content |
|---|---|---|
| Intro | 0.0–0.8 | Pad swell |
| Hit | 0.8–4.0 | Impact on "Free", sparse kick, pluck arpeggio |
| Verse 1 | 4.0–16.0 | Minimal kick and rim, quiet pluck |
| Verse 2 | 16.0–25.6 | Adds hats and a counter-line |
| Verse 3 | 25.6–35.2 | Adds moving bass, with a lift on the picker |
| Verse 4 | 35.2–42.4 | Evening colour: filter a little closed, thinner hats |
| Breakdown | 42.4–46.4 | Drums out on the whip; pad and sub only |
| Riser | 46.4–47.2 | Snare roll and filter sweep |
| Drop | 47.2–53.6 | Full groove, with a stab on each card |
| Outro | 53.6–58.4 | Final D major chord and bell at 54.0, ringing out; fade 57.4–58.4 |

- **Ducking:** a sidechain from the voice pulls the music down 8 dB (30 ms attack, 250 ms release).
- **Master:** two-pass loudnorm to −16 LUFS and −1.5 dBTP, encoded as AAC 256 kb/s at 48 kHz.

## App Preview cut: "Hold. Talk. Pasted." (29.3 s, 30 fps, 1920×1080)

The preview is rendered natively at 30 fps from the same stage:

- It contains primarily app footage, with captions only.
- Audio is included: voice, music and UI sounds.
- There are no pricing words, no "App Store" and no URL.
- The film's transitions and captions are replaced by the ones listed here.
- The music is a separate render cut to exactly 29.3 s, with no "Free" impact.

| Preview time (s) | Source (film s) | Picture | Captions | Audio |
|---|---|---|---|---|
| 0.00–9.30 | B 5.20–14.50 | Opens directly on the compose window. Hold, Listening, L1, Transcribing (EN), the reply lands, "Pasted 19 words" | **Hold Right ⌥ and talk.** (0.40–4.20); **Let go.** (6.60), then **It's pasted.** (7.95), both until 8.90 | L1 at 0.60 |
| 8.90–9.70 | | Bars rise, covering at 9.30 | | Whoosh |
| 9.30–19.00 | C 15.80–25.50 | Terminal agent: L2, Transcribing, the prompt lands, "Pasted 18 words", ↩, agent lines | **Transcribed on your Mac.** (16.95–18.60) | L2 at 10.15 |
| 18.60–19.40 | | Bars sweep, covering at 19.00 | | Sweep |
| 19.00–26.80 | D 26.10–33.90 | ⌥⇧ picker, "ger", German chosen (EN→DE), L3, Transcribing (DE) with punch-in, the reply lands, "Pasted 10 words", sent | **Speak any of 100 languages.** (19.60–23.80) | L3 at 21.70 |
| 26.70–27.10 | | The bars contract into the icon | | Bloom |
| 26.80–29.30 | Slate | The app icon, **VibeScribe**, **Hold a key. Speak. It's pasted.**, then the real pill "✓ Pasted 6 words" (counting that line) | | Resolve chord |

- **Poster frame:** 8.27 s, the "Pasted 19 words" moment with the reply in the window.
- **Re-timing:** if the clips are re-synthesised and the preview passes 29.5 s, trim P1's head and the slate first.

## Claims check

| On screen | Backed by |
|---|---|
| Free | App Store description ("free, with no subscription, no in-app purchases and no ads"); the site title |
| Hold Right ⌥, let go to paste | The default push-to-talk key is Right ⌥ (`HotkeyListener.swift`); stop comes 0.2 s after release (`HotkeyCoordinator.swift`) |
| Whole text at once, "Pasted N words" | Delivery is a single ⌘V (`TextOutput`); the pill shows `wordCount` (`VibeScribeApp.swift`, `RecordingSession.swift`) |
| ⌥⇧ picker, search "ger" | The default picker shortcut is ⇧⌥; matching was re-run on the app's list and returned German and Georgian (2 results) |
| 100 languages, Automatic | 100 codes plus Automatic (`WhisperLanguage`); "Most accurate · 100 languages" (`SpeechModels.swift`) |
| Tap for hands-free | Tap threshold 0.25 s, latched; the pill shows "Hands-free" with "Tap ⌥ to stop · esc to cancel" (`OverlayView.swift`) |
| Wi-Fi off, runs on your Mac, nothing leaves it | "Works offline · Speech never leaves this Mac" (Speech model page); README Privacy: the only network use is the one-time model download |
| No account, no API key | README: "No account, API key or cloud service is involved." |
| No subscription (film only) | App Store description |
| Searchable history, stored only on this Mac | `TranscriptHistory.search` matches text or app name; History's empty state says "stored only on this Mac" |
| Custom vocabulary, 4 → 5 words | `vocabularyWords` counts comma-separated entries |
| Your shortcut; hold, tap, or both | `ShortcutField` with Reset; trigger modes Hold or tap, Hold only, Tap only |
| Colourful menu bar icon only while recording | `MenuBarController.refreshButton` |

## Production notes

- **Sprites** are the real SwiftUI views rendered by `Tools/VibeScribeVideoFrames`, which mirrors the VibeScribeScreenshots target. Build it with `swift build --scratch-path .build-video --product VibeScribeVideoFrames`.
  - Overlay, picker, keycap and glyph sprites render at 4×; Settings sprites at 3×.
  - The bars inside the pill are clean-plated and redrawn live by the stage using the app's formula.
  - The Transcribing shimmer is removed from the sprite (per-pixel minimum of three captures) and redrawn by the stage.
  - The full list of 53 sprites is in `spec.json` under `sprites`.
- **SF fonts and symbols** are never committed. Text uses the system font in Chromium. SF Mono loads from the local Terminal.app bundle at render time. Symbols come from SwiftUI renders.
- **Gitignored outputs:**
  - `video/build/` and `video/out/` hold sprites, audio and renders.
  - `video/.env` holds the TTS key (mode 600).
