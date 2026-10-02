# VibeScribe launch film and App Preview

This folder renders the 58.4 s launch film and the 29.3 s App Store App Preview from source. The pipeline
uses the app's real SwiftUI views: every pill, menu, status item and Settings page is a sprite drawn by
`Tools/VibeScribeVideoFrames`. Those sprites are composited over generic macOS-style windows on a
deterministic HTML stage, then captured frame by frame with Playwright Chromium. The voice is Cartesia
TTS. The music and sound effects are synthesised here, so there are no samples, no library loops and no
Apple sound files.

| File | What it is |
| --- | --- |
| `spec.json`, `STORYBOARD.md` | The storyboard: scenes, camera, text, voice lines, SFX cues and the music brief |
| `SPRITES.md` | The UI states rendered from the app |
| `voice.mjs`, `voices.json` | Voices each line with Cartesia, verifies it by transcribing it back, and trims and normalises it to -18 LUFS |
| `timeline.mjs` | Re-times the storyboard to the real clip lengths and writes `build/timeline.json`, the source of truth for every later step |
| `sprites.mjs` | Builds `VibeScribeVideoFrames` (SwiftPM `--scratch-path .build-video`) and renders the sprites and the per-frame overlay sequences |
| `music.mjs` | Original music bed: 150 BPM half-time, D-Bm-G-A. One cut for the film, one for the preview |
| `sfx.mjs` | Original sound effects for every cue type |
| `mix.mjs` | Voice, SFX and a ducked music bed, mastered to -16 LUFS with a two-pass ffmpeg loudnorm |
| `render.mjs` | Renders the frames and encodes the MP4, WebM and App Preview, plus posters and contact sheets |
| `stage/` | The stage (HTML, CSS and ES modules). One time value drives everything; there are no timers or CSS animations |
| `lib/` | WAV I/O, DSP, speech-to-text checks and the secret loader |
| `tools/whisper-check` | Optional. Transcribes the clips with the app's own WhisperKit setup, so the pasted text and word counts match the app |

## Requirements

- macOS with Swift 6.2 or later. The Command Line Tools are enough (built and tested with Swift 6.3.3); Xcode
  is not needed. You also need Node 20 or later and `ffmpeg` with libx264, libvpx-vp9, libopus and the
  native AAC encoder (Homebrew's `ffmpeg` has all of these).
- `npm install` in this folder, then `npx playwright install chromium`.
- A Cartesia API key, needed only when the voice clips have to be generated.

## Keys

`voice.mjs` reads `CARTESIA_API_KEY` from the environment, or from `video/.env`. The `.env` file is
gitignored, and you should keep it at mode 600:

```sh
umask 077; printf 'CARTESIA_API_KEY=%s\n' "<your key>" > video/.env; chmod 600 video/.env
```

`OPENAI_API_KEY` is optional. When set, `voice.mjs` transcribes each take back with OpenAI; otherwise it
uses Cartesia's STT. Keys are only passed to `fetch` and are never printed or written anywhere else. Raw
TTS responses are cached in `build/audio/cache/` by a hash of the request, so a rebuild does not bill
again.

## Rebuild from scratch

```sh
cd video
npm install && npx playwright install chromium
npm run build
```

`npm run build` runs these steps in order. Each step can also be run on its own:

| Script | Runs | Writes |
| --- | --- | --- |
| `npm run voice` | `voice.mjs` | `build/audio/L1-L4.wav`, envelopes, `clips.json` |
| `npm run timeline` | `timeline.mjs` | `build/timeline.json` |
| `npm run sprites` | `timeline.mjs`, `sprites.mjs` | `build/sprites/`, `build/sequences/` |
| `npm run music` | `music.mjs` | `build/audio/music-film.wav`, `music-preview.wav`, `music.envelope.json` |
| `npm run sfx` | `sfx.mjs` | `build/audio/sfx/*.wav`, `build/audio/sfx/cues.json` |
| `npm run mix` | `mix.mjs` | `build/audio/mix-film.wav`, `mix-preview.wav`, `mix-report.json` |
| `npm run render` | `render.mjs` | frames in `build/frames/`, then everything in `out/` |
| `npm run encode` | `render.mjs --encode-only` | Re-encodes `out/` from the existing frames and the current mix |
| `npm run preview` | `mix.mjs` and `render.mjs`, preview only | `out/vibescribe-app-preview.mp4` and its poster |
| `npm run stills` | `render.mjs --stills` | Full-size key-frame PNGs in `build/stills/` |
| `npm run serve` | `render.mjs --serve` | Serves the stage at `/stage/index.html?t=12.3` (`&mode=preview` for the preview cut, `&play` for real-time playback) |
| `npm run whisper-check:build` | `swift build` of `tools/whisper-check` | `../.build-video-whisper/` |

Frame rendering resumes: frames that are already in `build/frames/` are kept. Use
`node render.mjs --force` after a stage change, and `--workers N` to set the number of parallel pages
(the default is the CPU count minus 2). Frames are laid out at 1440x810 CSS px with device pixel ratio
4/3, which gives a 1920x1080 frame. Camera moves faster than about 6 px per frame are motion-blurred by
averaging temporal sub-frames.

Each frame is captured at 4x that size and scaled down to 1920x1080 in the browser. Chromium snaps text
and boxes to whole device pixels, so at 1080p a slow zoom moves each element in its own 1 px steps, and
the picture seems to vibrate. At 4x the steps are a quarter pixel and average out. A full render takes
about two hours on a 10-core MacBook Air: every motion-blur sub-frame is a 7680x4320 capture. For a
quick draft, `node render.mjs --ss 1` captures straight at 1080p (about 25 minutes, with the
vibration).

The app-engine check is optional. After `npm run whisper-check:build`, `voice.mjs` also transcribes each
final clip with WhisperKit and the app's local large-v3 model. It looks for the model in
`~/Library/Application Support/io.m10s.vibescribe`, or in `VIBESCRIBE_MODEL_DIR`. The text the app would
paste, and the "Pasted N words" counts, then come from the app's own engine.

## Outputs (`out/`, gitignored)

| File | Format |
| --- | --- |
| `vibescribe-launch.mp4` | 1920x1080, 60 fps, H.264 High yuv420p (BT.709), CRF 17, AAC 256 kb/s, 48 kHz stereo, faststart |
| `vibescribe-launch.webm` | 1920x1080, 60 fps, VP9 (CRF 22), Opus 192 kb/s |
| `vibescribe-app-preview.mp4` | App Store App Preview: 1920x1080, 30 fps, 29.3 s, H.264 High yuv420p at about 11 Mb/s, AAC 256 kb/s, 48 kHz stereo |
| `vibescribe-launch-poster.png` | The film's end-slate hero frame |
| `vibescribe-app-preview-poster.png` | The preview's suggested poster frame at 8.27 s ("Pasted 19 words"). Pick that time as the poster frame when you upload |
| `vibescribe-app-preview-first-frame.png` | The preview's first frame (mail compose with "Hold Right ⌥ and talk."), for reference |

Both mixes are -16 LUFS integrated with a true peak of -2 dBTP or lower (the delivery limit is -1.5 dBTP;
the extra margin absorbs AAC overshoot). `build/verify/` holds contact sheets of both cuts
(`fps=1,scale=480:-1,tile=6x10`) and spectrograms of the music.

The App Preview cut follows App Store rules. It shows the app in use and contains no pricing words. Its
audio is a separate mix, with its own music cut, a short fade-in and a 1 s fade-out. The launch film leads
with "Free".

## Swapping the music

The bed only needs to be a 48 kHz stereo WAV for each cut. To use your own track:

1. Export the track at full length: 58.4 s for the film and 29.3 s for the preview. If you keep the
   storyboard's sections (`timeline.json` -> `music.sections`, the drop at 47.2 s, the final chord at
   53.6 s), the cuts will land on the beat.
2. Save the exports as `build/audio/music-film.wav` and `build/audio/music-preview.wav`, replacing the
   generated ones. Their loudness does not matter: `mix.mjs` gain-matches each bed to -20 LUFS
   before it ducks it under the voice and masters the whole programme. Don't run `npm run music` afterwards, as it would overwrite them.
3. Optional: delete `build/audio/music.envelope.json`. The cold-open bars then use a synthetic 150 BPM
   pulse instead of following the generated kick and bass. If you delete it, re-render the frames with
   `node render.mjs --force`.
4. Run `npm run mix && npm run encode`.

To change the generated bed instead, edit `music.mjs` (voicings, patterns and the per-section
arrangement). Then run `npm run music && npm run mix && node render.mjs --force`. The `--force` flag is
needed because the envelope that drives the cold-open bars has changed.

## Rules this pipeline keeps

- It shows no real third-party apps, logos or UI. The mail, terminal, chat and notes windows are generic
  mock-ups.
- The app's start and stop sounds are new sounds in the same spirit, not Apple's files.
- The film shows what the app really does. The transcript appears all at once after the key is released
  (VibeScribe pastes the whole transcript; there is no streaming), and the word counts come from the
  app's own transcript of each clip.
- SwiftPM never uses the default `.build`: the sprites build in `.build-video` and whisper-check builds in
  `.build-video-whisper`.
