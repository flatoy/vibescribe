# Video sprites: real VibeScribe UI as PNGs

`Tools/VibeScribeVideoFrames` renders the app's own SwiftUI views from VibeScribeCore (the overlay pill,
the language picker, Settings pages, keycaps, the status item) as transparent PNGs for the stage. It
hosts each view in an offscreen, dark-appearance window and captures it with `cacheDisplay`, so the
PNGs show exactly what the app draws. Everything it writes goes under `video/build/`, which is gitignored.

Run everything from the repository root:

```sh
swift build --scratch-path .build-video --product VibeScribeVideoFrames
B=.build-video/debug/VibeScribeVideoFrames

$B sprites                                   # all sprites -> video/build/sprites/ (about 60 s)
$B sprites --only pill_listening*,picker     # ids, prefix* patterns or groups; merges manifest.json
$B sprites --list                            # ids and groups, no rendering

$B test-envelope --out video/build/sequences/test/test.envelope.json
$B sequence --envelope video/build/sequences/test/test.envelope.json --out video/build/sequences/test/listening

# Scene B (L1): the overlay appears at 5.55 s, the voice starts at 5.8 s, transcribing starts at 11.92 s
E=video/build/audio/L1.envelope.json
$B sequence --layer pill       --envelope $E --t0 5.55 --envelope-at 0.25 --duration 6.37 --out video/build/sequences/L1/pill
$B sequence --layer bars       --envelope $E --t0 5.55 --envelope-at 0.25 --duration 6.37 --out video/build/sequences/L1/bars
$B sequence --layer statusitem --envelope $E --t0 5.55 --envelope-at 0.25 --duration 6.37 --out video/build/sequences/L1/statusitem
$B sequence --state transcribing --badge en --t0 11.92 --duration 1.2 --out video/build/sequences/L1/transcribing

$B envelope --wav video/build/audio/L1.wav --out /tmp/L1.meter.json   # the app's LevelMeter applied to a WAV
$B verify                                                              # real views vs replicas -> video/build/verify/
```

On a machine whose locale isn't `en_US`, the tool relaunches itself with `-AppleLocale en_US -AppleLanguages (en)`
so that dates and numbers are formatted in en-US.

## Sprites (`video/build/sprites/`)

The tool writes `<id>.png` and a `<id>.json` sidecar for every id in `video/spec.json`, plus a few extras
(`pill_copied`, `pill_nospeech`, `pill_listening_sample`, `statusitem_*`). `manifest.json` lists them all
in spec order: `{schema: "vibescribe-video-sprites/1", units, colour, warnings, sprites: [entry…]}`.

Entry and sidecar fields:

| field | meaning |
|---|---|
| `file`, `group`, `scale` | PNG name, group (pill, picker, settings, keycap, glyph, statusitem, icon) and px per pt |
| `size_px`, `size_pt` | PNG size. Trimmed to the pixels that have alpha (the shadow included), grown to whole points |
| `content_rect_pt` | `[x, y, w, h]` of the view itself (pill body, picker panel, window, keycap) without its shadow, in sprite points from the top-left |
| `anchor`, `anchor_pt` | `top_center`, `top_left` or `center` of `content_rect_pt`: put this point on the stage position |
| `placement_world` | where the spec places it (pills: top_center at x 720, top 42; picker: top_center at x 720, top 106) |
| `bars_rect_pt` | pills with painted-out bars: the 33×16 pt rect where SpectrumBars belongs |
| `caret_rect_pt` | pickers, history search, vocabulary editor: a 1 pt wide caret at the end of the text. The sprites have no caret, so the stage draws and blinks it |
| `state`, `text` | what the view shows (query, row count, timer, labels), useful for checking |

Scales: pills, pickers, keycaps and glyphs are 4x. Settings are 3x: a 780×560 window inside a 896×683 pt sprite, so the window shadow fits.
`icon_app.png` is a byte-for-byte copy of `Icon.png`.

Pills:
- `pill_listening_t*`, `pill_handsfree_t*` and `pill_transcribing_*` are clean plates. Their bars are painted out by interpolating each pixel row across `bars_rect_pt` ± 0.5 pt, and the transcribing shimmer is removed. The stage draws the bars on top, either from `sequence --layer bars` or its own SpectrumBars, and redraws the shimmer.
- Timer sprites read exactly 0:0N.
- Result pills (`pasted`, `copied`, `nospeech`) are captured unchanged.

The picker has no shadow in the sprite, because the real panel uses the system window shadow. The stage draws it, as the spec says.

## Sequences (`sequence`)

Input envelope: `{"fps": 60, "levels": [0..1, …], "kind": "level"}`.
- `levels[i]` is the app's `LevelMeter.level` at `i/fps` seconds after the clip starts. The audio pipeline's `L*.envelope.json` files are in this form; `envelope --wav` reproduces them to within 0.0005.
- With `"kind": "target"`, `levels` holds raw per-window targets, and the tool smooths them with the real `LevelMeter.push` at 46.875 buffers/s.
- After the last level, the meter decays by ×0.85 per 1024-frame buffer.

For output frame `i`, with `t = i / fps` and film time `T = t0 + t`:

```
level     = levels[floor((t - envelope_at) * env_fps)]      (0 before envelope_at)
bars time = floor(T * 30) / 30                               (SpectrumBars' TimelineView, minimumInterval 1/30)
bars      = SpectrumBars' formula at (level, bars time)      (identical arithmetic, see verify)
timer     = floor(t - started_at)                            (TimelineView .periodic(from: startedAt, by: 1))
shimmer   = OverlayPill's shimmer at T (unquantised)         (transcribing only)
status    = refreshed at 12 Hz; title Format.duration(elapsed), which rounds
```

Layers:
- `pill`: the whole pill with its shadow, the same size and anchor as the matching `pill_*` sprite. Each frame is that second's clean plate plus the bars (plus the shimmer).
- `bars`: bars only, 37×20 pt (the 33×16 bars plus 2 pt margin). Place the frame's top-left at `bars_rect_pt.origin - (2, 2)` of the pill sprite, i.e. pill body top-left + `(11, 7)`.
- `statusitem`: the menu bar item (StatusIcons image + `" 0:0N"`), white, anchored at its centre.

Files are `frame_00000.png…` (`--prefix`, `--start-number`), all the same size. Old frames with the same prefix are deleted first.

`sequence.json` holds:
- `size_px`, `size_pt`, `content_rect_pt`, `anchor`, `anchor_pt` and `bars_rect_pt`, as in the sprite manifest
- `fps`, `frames`, `t0`, `envelope_at`, `started_at`
- `per_frame`: `[{level, timer | title, bars_time | refresh_time}]`
- `timer_changes`: `[{frame, text}]`

Encode with, for example, `ffmpeg -framerate 60 -i frame_%05d.png -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le out.mov`.

Options:

| option | default |
|---|---|
| `--state` | listening; also handsfree, transcribing |
| `--layer` | pill; also bars, statusitem |
| `--fps` | the envelope's |
| `--frames N` or `--duration S` | the envelope length + `envelope_at` |
| `--t0` | 0 |
| `--envelope-at` | 0 |
| `--started-at` | 0 |
| `--scale` | 4 |
| `--quantize` | 30 (bars refresh in Hz; 0 means continuous) |
| `--status-rate` | 12 |
| `--keycaps` | ⌥ (comma-separated, hands-free hint) |
| `--badge` | en |

## Verification (`verify`)

This command checks the replicas against the real views. The real `SpectrumBars` and `OverlayPill` are captured next to a probe `TimelineView` that runs on the same schedule. The replica is then rendered at the probe's dates and diffed pixel by pixel at 4x. It writes `video/build/verify/verify.json` and diff images ×16. Last run:
- Bars, real vs replica (live 0.15 to 1.0, thinking, still): identical (max Δ 0), apart from one thinking capture at max Δ 1.
- Real pill vs plate + replica bars, still and live: max Δ 2 of 255 (8-bit rounding).
- Real transcribing pill vs plate + replica bars + replica shimmer: max Δ 2.
- Reusing the frame renderer gives identical pixels to a fresh one.

## Known differences

- The status item is the app's StatusIcons image plus its title font, laid out in SwiftUI. It is not a capture of the real `NSStatusBarButton`, which adds its own padding and highlight.
- The shadow under the moving bars is the plate's (computed with the still bars). Bars are tiny next to the pill, and the difference is within the Δ 2 above.
- The live app's audio tap may deliver buffers larger than 1024 frames, which makes the real meter a little steppier. The envelopes assume 1024 frames at 48 kHz.
