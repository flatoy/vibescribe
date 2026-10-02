#!/usr/bin/env node
// Re-times spec.json to the voice clips that were actually synthesised (build/audio/clips.json)
// and writes build/timeline.json, the single source of truth for the stage, the sprite
// sequences, the music, the SFX and the mix.
//
//   node timeline.mjs            write build/timeline.json and print the schedule
//
// Re-timing rule (spec.timing_rules): every dictation loop is anchored at the END of the voice,
// so key_up, stop, Transcribing, Pasted, hidden and everything after them keep their storyboard
// times, and the transitions keep their cover points. Only the key press, the recording start and
// the voice start move, by the clip's measured length:
//
//   hold:  voice_start = (spec key_up - 0.20) - clip.duration
//          key_down = voice_start - 0.30, recording_start = key_down + 0.05
//   tap:   tap 1 and the voice start stay where the storyboard has them (the opening tap is the
//          beat the caption teaches); tap 2 = max(spec tap 2, voice_end + 0.15)
//
// The pasted text and the word count are the app's own transcript of the clip (clips.json ->
// app_engine: WhisperKit large-v3 with the app's decode options), i.e. exactly what VibeScribe
// would paste for that audio.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(fileURLToPath(import.meta.url))
const spec = JSON.parse(readFileSync(join(ROOT, 'spec.json'), 'utf8'))
const clipsFile = JSON.parse(readFileSync(join(ROOT, 'build', 'audio', 'clips.json'), 'utf8'))
const clips = Object.fromEntries(clipsFile.clips.map((c) => [c.id, c]))
const r3 = (v) => Math.round(v * 1000) / 1000
const near = (a, b) => Math.abs(a - b) < 1e-6
const clone = (v) => JSON.parse(JSON.stringify(v))

const TAU_STOP = spec.timing_rules.stop_delay_s // 0.2
const DEBOUNCE = spec.timing_rules.combo_debounce_s // 0.05
const PASTED_S = spec.timing_rules.pasted_visible_s // 1.3

// ------------------------------------------------------------------ loops

const LOOP_SCENES = { 'B-inbox': 'B', 'C-agent': 'C', 'D-chat': 'D', 'E-note': 'E' }
const loops = []
const remaps = {} // scene id -> [[from, to], ...]

for (const scene of spec.scenes) {
  const key = LOOP_SCENES[scene.id]
  if (!key) continue
  const d = spec.timing_rules.derived[key]
  const clip = clips[scene.voice]
  if (!clip) throw new Error(`no clip ${scene.voice} in clips.json`)
  const engine = clip.app_engine && clip.app_engine.text ? clip.app_engine : null
  const text = engine ? engine.text : clip.text
  const words = text.trim().split(/\s+/).length
  const transcribing = scene.overlay.find((o) => o.phase === 'transcribing')
  const pastedEntry = scene.overlay.find((o) => o.phase === 'pasted')
  const hold = r3(pastedEntry.t - transcribing.t)
  const loop = { scene: scene.id, key, clip: clip.id, language: clip.language, badge: transcribing.badge.toLowerCase(), text, words, text_source: engine ? 'app_engine' : 'spec', clip_duration: clip.duration }
  const map = []
  if (d.tap1_down !== undefined) {
    loop.mode = 'tap'
    loop.voice_start = r3(d.tap1_down + 0.5)
    loop.voice_end = r3(loop.voice_start + clip.duration)
    loop.tap1_down = d.tap1_down
    loop.key_down = d.tap1_down
    loop.rec_start = r3(d.tap1_down + DEBOUNCE)
    loop.tap1_up = d.tap1_up
    loop.hands_free = d.tap1_up
    loop.tap2_down = r3(Math.max(d.tap2_down, loop.voice_end + 0.15))
    loop.tap2_up = r3(loop.tap2_down + (d.tap2_up - d.tap2_down))
    loop.key_up = loop.tap2_up
    loop.stop = r3(loop.tap2_up + TAU_STOP)
    map.push([d.tap2_down, loop.tap2_down], [d.tap2_up, loop.tap2_up], [d.stop, loop.stop])
  } else {
    loop.mode = 'hold'
    loop.voice_end = r3(d.key_up - 0.2)
    loop.voice_start = r3(loop.voice_end - clip.duration)
    loop.key_down = r3(loop.voice_start - 0.3)
    loop.rec_start = r3(loop.key_down + DEBOUNCE)
    loop.key_up = r3(loop.voice_end + 0.2)
    loop.stop = r3(loop.key_up + TAU_STOP)
    const shift = loop.key_down - d.key_down
    if (Math.abs(shift) > 0.35) console.warn(`warning: ${key} key_down moves by ${shift.toFixed(3)} s; check the scene's early beats`)
    map.push([d.key_down, loop.key_down], [d.start, loop.rec_start], [d.key_up, loop.key_up], [d.stop, loop.stop])
  }
  loop.pasted = r3(loop.stop + hold)
  loop.hidden = r3(loop.pasted + PASTED_S)
  map.push([d.pasted, loop.pasted], [d.hidden, loop.hidden])
  loop.transcribing_hold = hold
  loop.envelope_at = r3(loop.voice_start - loop.rec_start)
  loop.recorded = r3(loop.stop - loop.rec_start)
  loop.timer_max = Math.floor(loop.recorded - 1e-6)
  loop.duration_label = `0:${String(Math.round(loop.recorded)).padStart(2, '0')}`
  loop.seq = `build/sequences/${key}`
  loops.push(loop)
  remaps[scene.id] = map.filter(([a, b]) => !near(a, b))
}

// ------------------------------------------------------------------ scenes

const TIME_KEYS = new Set(['t', 'started_at', 'time', 'start', 'end', 'cover', 'choose', 'open'])
function remapTree(node, map) {
  if (Array.isArray(node)) return node.map((v) => remapTree(v, map))
  if (!node || typeof node !== 'object') return node
  const out = {}
  for (const [k, v] of Object.entries(node)) {
    if (typeof v === 'number' && TIME_KEYS.has(k)) {
      const hit = map.find(([from]) => near(from, v))
      out[k] = hit ? hit[1] : v
    } else out[k] = remapTree(v, map)
  }
  return out
}

const scenes = spec.scenes.map((scene) => {
  const map = remaps[scene.id] || []
  const s = remapTree(clone(scene), map)
  const loop = loops.find((l) => l.scene === scene.id)
  if (loop) {
    s.loop = loop.key
    // The paste lands the app's transcript, and History shows the re-timed recording.
    for (const w of s.windows || []) {
      const c = w.content || {}
      if (c.paste) c.paste.text = loop.text
      if (c.composer && c.composer.paste) c.composer.paste.text = loop.text
      if (c.messages) for (const m of c.messages) if (m.from === 'me') m.text = loop.text
    }
    for (const o of s.overlay) if (o.phase === 'pasted') { o.words = loop.words; o.sprite = `pill_pasted_${loop.words}` }
    for (const e of s.events || []) if (e.type === 'paste') e.words = loop.words
    if (s.history_entry) { s.history_entry.text = loop.text; s.history_entry.duration_s = loop.recorded; s.history_entry.duration_label = loop.duration_label }
  }
  return s
})

// ------------------------------------------------------------------ sfx

const allMaps = Object.entries(remaps)
const sfx = spec.sfx.filter((c) => c.type !== 'none').map((cue) => {
  const sceneKey = cue.id.split('_')[0]
  const entry = allMaps.find(([id]) => id.toLowerCase().startsWith(sceneKey + '-'))
  const map = entry ? entry[1] : []
  const hit = map.find(([from]) => near(from, cue.time))
  return { ...cue, time: hit ? hit[1] : cue.time }
})

// ------------------------------------------------------------------ voice

const voice = loops.map((l) => ({ clip: l.clip, file: `build/audio/${l.clip}.wav`, start: l.voice_start, duration: l.clip_duration, scene: l.scene }))

// ------------------------------------------------------------------ preview

const pc = clone(spec.preview_cut)
const segments = pc.segments.map((seg) => ({ ...seg, offset: seg.src_in !== undefined ? r3(seg.src_in - seg.dst_in) : null }))
const inSeg = (seg, t) => seg.src_in !== undefined && t >= seg.src_in - 1e-9 && t < seg.src_out - 1e-9
const previewVoice = []
for (const v of voice) {
  const seg = segments.find((s) => inSeg(s, v.start))
  if (seg) previewVoice.push({ ...v, start: r3(v.start - seg.offset), src_start: v.start, segment: seg.id })
}
const FILM_TRANSITION = /^t\d/
const previewSfx = []
for (const cue of sfx) {
  if (FILM_TRANSITION.test(cue.id)) continue
  const seg = segments.find((s) => inSeg(s, cue.time))
  if (seg) previewSfx.push({ ...cue, time: r3(cue.time - seg.offset), src_time: cue.time, segment: seg.id })
}
const previewTransitionSfx = { bars_rise: 'whoosh_rise', bars_sweep: 'whoosh_sweep', bars_to_icon: 'bloom' }
for (const seg of segments) {
  const tr = seg.transition_out
  if (!tr) continue
  previewSfx.push({ id: `p_${seg.id}_${tr.kind}`, type: previewTransitionSfx[tr.kind], time: tr.start, level_db: tr.kind === 'bars_to_icon' ? -18 : -19, origin: 'film' })
}
previewSfx.sort((a, b) => a.time - b.time)

// Music cues for the preview bed (sections in preview time).
const previewMusic = {
  duration: pc.total_s,
  sections: [
    { id: 'verse_1', start: 0, end: 9.3 },
    { id: 'verse_2', start: 9.3, end: 19 },
    { id: 'verse_3', start: 19, end: 26.8, note: 'lift at P3' },
    { id: 'outro', start: 26.8, end: pc.total_s, note: 'resolve to D major with the bell at 26.9; fade the last second' }
  ],
  bell: 26.9
}

const timeline = {
  schema: 'vibescribe-video-timeline/1',
  generated_by: 'video/timeline.mjs',
  duration: spec.duration,
  fps: spec.output.fps,
  output: spec.output,
  world: spec.output.world,
  theme: spec.theme,
  styles: spec.styles,
  stage: spec.stage,
  timing_rules: spec.timing_rules,
  clips: Object.fromEntries(loops.map((l) => [l.clip, { id: l.clip, duration: l.clip_duration, envelope: `build/audio/${l.clip}.envelope.json`, file: `build/audio/${l.clip}.wav`, text: l.text, words: l.words }])),
  loops,
  remaps,
  scenes,
  voice,
  sfx,
  music: spec.music,
  preview: { ...pc, segments, voice: previewVoice, sfx: previewSfx, music: previewMusic }
}

mkdirSync(join(ROOT, 'build'), { recursive: true })
writeFileSync(join(ROOT, 'build', 'timeline.json'), JSON.stringify(timeline, null, 1))

console.log('loop  mode  voice            key_down  rec    key_up  stop    pasted  hidden  rec_s  timer  words')
for (const l of loops) {
  console.log(`${l.key}     ${l.mode.padEnd(5)} ${l.voice_start.toFixed(3)}-${l.voice_end.toFixed(3)}  ${l.key_down.toFixed(3)}  ${l.rec_start.toFixed(3)}  ${l.key_up.toFixed(3)}  ${l.stop.toFixed(3)}  ${l.pasted.toFixed(3)}  ${l.hidden.toFixed(3)}  ${l.recorded.toFixed(2)}   ${l.duration_label}   ${l.words}`)
}
console.log('preview voice', previewVoice.map((v) => `${v.clip}@${v.start}`).join(' '))
console.log(`wrote build/timeline.json (${sfx.length} film cues, ${previewSfx.length} preview cues)`)
