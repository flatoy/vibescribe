#!/usr/bin/env node
// Voices every clip in spec.json with Cartesia TTS, verifies each take by transcribing
// it back, trims and loudness-normalizes it, and writes a level envelope that drives the
// stage's SpectrumBars exactly like the app's LevelMeter would.
//
//   node voice.mjs                     generate (or reuse) all clips, verify, write clips.json
//   node voice.mjs --clip L3           only one clip
//   node voice.mjs --audition [--group cast-de]   voice the audition groups in voices.json and compare
//   node voice.mjs --list [--language de] [--gender feminine]   list Cartesia voices
//   node voice.mjs --app-check         only re-run the app-engine check on the current clips
//
// Verification: every take is transcribed back (OpenAI gpt-4o-transcribe / whisper-1 when the
// key works, else Cartesia ink-whisper) and compared word by word. Then, if the
// whisper-check tool is built (npm run whisper-check:build), the final clips are also
// transcribed by the app's own engine: WhisperKit 1.1.0 with the app's local large-v3 model,
// its decode options and the film's custom vocabulary. That records exactly what VibeScribe
// would paste and the word count its pill would show (clips.json -> app_engine).
//
// Raw TTS responses are cached by sha256(model, voice, language, text, generation, take),
// so reruns never re-bill. Keys come from the environment or video/.env (never logged).
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { appMeter, Biquad, dbToGain, gainToDb, limit, lufs, peakDb } from './lib/dsp.mjs'
import { secret } from './lib/secrets.mjs'
import { compareWords, measureVoice, transcribe } from './lib/speech.mjs'
import { decode, SR, writeWav } from './lib/wav.mjs'

const ROOT = dirname(fileURLToPath(import.meta.url))
const REPO = dirname(ROOT)
const BUILD = join(ROOT, 'build', 'audio')
const CACHE = join(BUILD, 'cache', 'voice')
const spec = JSON.parse(readFileSync(join(ROOT, 'spec.json'), 'utf8'))
const cfg = JSON.parse(readFileSync(join(ROOT, 'voices.json'), 'utf8'))
const P = cfg.processing
const PROCESS_VERSION = 2 // bump when processTake changes so cached processed takes are rebuilt
const args = process.argv.slice(2)
const flag = (name) => args.includes(name)
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined }
const hash = (value) => createHash('sha256').update(JSON.stringify(value)).digest('hex').slice(0, 16)
const rel = (path) => relative(ROOT, path)

mkdirSync(CACHE, { recursive: true })

// ------------------------------------------------------------------ Cartesia

async function cartesia(path, init = {}) {
  const response = await fetch(`https://api.cartesia.ai${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${secret('CARTESIA_API_KEY')}`, 'Cartesia-Version': cfg.api_version, ...init.headers }
  })
  if (!response.ok) throw new Error(`Cartesia ${path} ${response.status}: ${(await response.text()).slice(0, 300)}`)
  return response
}

async function synthesize(request, rawPath) {
  const response = await cartesia('/tts/bytes', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model_id: request.model,
      transcript: request.text,
      voice: { mode: 'id', id: request.voice },
      language: request.language,
      output_format: { container: 'wav', encoding: 'pcm_s16le', sample_rate: cfg.sample_rate },
      ...(request.generation && { generation_config: request.generation })
    })
  })
  writeFileSync(rawPath, Buffer.from(await response.arrayBuffer()))
}

async function listVoices() {
  const file = join(BUILD, 'cartesia-voices.json')
  let voices
  if (existsSync(file) && !flag('--refresh')) voices = JSON.parse(readFileSync(file, 'utf8'))
  else {
    voices = []
    let after = ''
    for (;;) {
      const page = await (await cartesia(`/voices?limit=100${after && `&starting_after=${after}`}`)).json()
      voices.push(...page.data)
      if (!page.has_more || !page.data.length) break
      after = page.data.at(-1).id
    }
    writeFileSync(file, JSON.stringify(voices, null, 1))
  }
  const language = option('--language')
  const gender = option('--gender')
  for (const v of voices) {
    if (language && v.language !== language) continue
    if (gender && v.gender !== gender) continue
    console.log(`${v.id}  ${v.language}  ${(v.gender ?? '').padEnd(10)} ${v.name} — ${v.tagline ?? ''}: ${v.description}`)
  }
}

// ------------------------------------------------------------------ processing

/**
 * HPF, trim edges to pad_ms around speech, cap internal pauses, normalize loudness.
 * Thresholds are relative to the loudest 10 ms frame so they adapt to each take.
 */
function processTake(rawPath, outPath) {
  const [x] = decode(rawPath)
  const hp = new Biquad('highpass', P.hpf_hz, 0.7071)
  const hp2 = new Biquad('highpass', P.hpf_hz, 0.7071)
  for (let i = 0; i < x.length; i++) x[i] = hp2.tick(hp.tick(x[i]))
  const frame = SR / 100
  const frames = Math.floor(x.length / frame)
  const db = new Float32Array(frames)
  for (let f = 0; f < frames; f++) {
    let s = 0
    for (let i = f * frame; i < (f + 1) * frame; i++) s += x[i] * x[i]
    db[f] = 10 * Math.log10(s / frame + 1e-12)
  }
  const top = Math.max(...db)
  const edge = Math.max(top - P.edge_threshold_db_below_peak, -62)
  let first = 0; while (first < frames && db[first] < edge) first++
  let last = frames - 1; while (last > first && db[last] < edge) last--
  const pad = Math.round((P.pad_ms / 1000) * SR)
  const from = Math.max(0, first * frame - pad)
  const to = Math.min(x.length, (last + 1) * frame + pad)

  // Pause capping inside the speech span.
  const quiet = top - P.pause_threshold_db_below_peak
  const keepFrames = Math.round(P.max_pause_s * 100)
  const cuts = []
  for (let f = first; f <= last; f++) {
    if (db[f] >= quiet) continue
    let g = f
    while (g <= last && db[g] < quiet) g++
    if (g - f > keepFrames) cuts.push([(f + Math.floor(keepFrames / 2)) * frame, (g - Math.ceil(keepFrames / 2)) * frame, (g - f) / 100])
    f = g
  }
  const xf = Math.round(0.008 * SR)
  const parts = []
  let cursor = from
  for (const [a, b] of cuts) { parts.push([cursor, a]); cursor = b }
  parts.push([cursor, to])
  const length = parts.reduce((n, [a, b]) => n + (b - a), 0) - xf * (parts.length - 1)
  const out = new Float32Array(length)
  let o = 0
  parts.forEach(([a, b], k) => {
    const seg = x.subarray(a, b)
    for (let i = 0; i < seg.length; i++) {
      let v = seg[i]
      if (k > 0 && i < xf) v *= i / xf
      if (k < parts.length - 1 && i >= seg.length - xf) v *= (seg.length - i) / xf
      if (o + i < out.length) out[o + i] += v
    }
    o += seg.length - xf
  })
  const fade = Math.round(0.006 * SR)
  for (let i = 0; i < fade; i++) { out[i] *= i / fade; out[out.length - 1 - i] *= i / fade }

  // Loudness first, then a transparent lookahead limiter catches the few plosive peaks;
  // a second pass compensates the small loudness loss so every clip lands on target.
  let limited = 0
  for (let pass = 0; pass < 3; pass++) {
    const g = dbToGain(P.target_lufs - lufs([out]))
    if (pass > 0 && Math.abs(gainToDb(g)) < 0.05) break
    for (let i = 0; i < out.length; i++) out[i] *= g
    limited = Math.max(limited, limit([out], { ceilingDb: P.max_peak_dbfs, lookahead: 0.004, release: 0.08 }))
  }
  writeWav(outPath, [out], { bits: 24 })
  return {
    duration: Math.round((out.length / SR) * 1000) / 1000,
    lufs: Math.round(lufs([out]) * 10) / 10,
    peak_dbfs: Math.round(peakDb([out]) * 10) / 10,
    limiter_max_db: Math.round(limited * 10) / 10,
    lead_trim_s: Math.round((from / SR) * 1000) / 1000,
    pauses_capped: cuts.map(([, , len]) => len)
  }
}

/** One cached take: raw TTS → processed WAV → transcript check. */
async function take({ text, language, voice, generation, index, accept, wordCount, label }) {
  const request = { model: cfg.model, voice, language, text, generation, take: index }
  const key = hash(request)
  const base = join(CACHE, key)
  const raw = `${base}.raw.wav`
  const procKey = hash({ version: PROCESS_VERSION, P: { ...P, envelope_fps: 0, envelope_tail_s: 0, meter_gain_db: 0, max_takes: 0, duration_tolerance_s: 0 } })
  const file = `${base}.${procKey}.wav`
  const metaPath = `${base}.${procKey}.json`
  let meta
  if (existsSync(metaPath)) {
    meta = { ...JSON.parse(readFileSync(metaPath, 'utf8')), file, raw }
  } else {
    if (!existsSync(raw)) {
      console.log(`  voicing ${label} take ${index} (${voice.slice(0, 8)}, ${JSON.stringify(generation ?? {})})`)
      await synthesize(request, raw)
    }
    const stats = processTake(raw, file)
    const heard = await transcribe(file, language)
    const [samples] = decode(file)
    meta = { key, take: index, voice, generation, file, raw, ...stats, engine: heard.engine, heard: heard.text, measure: measureVoice(samples, wordCount) }
    writeFileSync(metaPath, JSON.stringify(meta, null, 1))
  }
  // The app-engine result is cached per (model, vocabulary) next to the STT result.
  const engine = resolveAppEngine()
  if (engine) {
    const appKey = hash({ model: basename(engine.model), vocabulary: engine.vocabulary })
    meta.app_checks ??= {}
    if (!meta.app_checks[appKey]) {
      meta.app_checks[appKey] = appTranscribe(file, language)
      writeFileSync(metaPath, JSON.stringify(meta, null, 1))
    }
    meta.app = meta.app_checks[appKey]
  }
  meta.check = compareWords(text, meta.heard, accept)
  // A take is only usable if VibeScribe itself would paste the number of words the pill shows.
  meta.appPass = !meta.app || meta.app.words === wordCount
  return meta
}

// ------------------------------------------------------------------ app-engine check

function appModelFolder() {
  if (process.env.VIBESCRIBE_MODEL_DIR) return process.env.VIBESCRIBE_MODEL_DIR
  const support = join(homedir(), 'Library', 'Application Support', 'io.m10s.vibescribe')
  if (!existsSync(support)) return null
  const folders = readdirSync(support).filter((f) => f.startsWith('WhisperModel-')).sort()
  const pick = folders.find((f) => !/turbo/.test(f)) ?? folders[0]
  return pick ? join(support, pick) : null
}

const WHISPER_BIN = join(REPO, '.build-video-whisper', 'release', 'whisper-check')
let appEngine // resolved once: { model, vocabulary } or null

function resolveAppEngine() {
  if (appEngine !== undefined) return appEngine
  const model = appModelFolder()
  const why = flag('--no-app-check') ? '--no-app-check' : !existsSync(WHISPER_BIN) ? 'run: npm run whisper-check:build' : !model ? 'no local VibeScribe model; set VIBESCRIBE_MODEL_DIR' : null
  if (why) {
    console.log(`App-engine check unavailable (${why}); takes are accepted on the STT check alone`)
    return (appEngine = null)
  }
  appEngine = { model, vocabulary: cfg.app_check?.vocabulary ?? '' }
  console.log(`App-engine check: WhisperKit 1.1.0, ${basename(model)}, vocabulary "${appEngine.vocabulary}"`)
  return appEngine
}

/**
 * Transcribes one file with VibeScribe's own engine (tools/whisper-check): what the app
 * would paste and the word count its pill would show. Read-only use of the app's model.
 * One process per file, so a bad file cannot take a batch down with it.
 */
function appTranscribe(file, language) {
  const engine = resolveAppEngine()
  if (!engine) return null
  const r = spawnSync(WHISPER_BIN, [engine.model, '--vocab', engine.vocabulary, `${language}:${file}`], { encoding: 'utf8', maxBuffer: 1 << 24 })
  const row = (r.stdout ?? '').split('\n').find((l) => l.startsWith('{'))
  if (!row) throw new Error(`whisper-check failed on ${basename(file)} (${r.signal ?? `exit ${r.status}`})`)
  const { text, words } = JSON.parse(row)
  return { engine: 'WhisperKit 1.1.0 (tools/whisper-check, app decode options)', model: basename(engine.model), vocabulary: engine.vocabulary, text, words }
}

function appSummary(clip, app) {
  if (!app) return null
  return {
    ...app,
    words_match_spec: app.words === clip.transcript_word_count,
    text_matches_spec: app.text === clip.text,
    spoken_words_match: compareWords(clip.text, app.text, cfg.clips[clip.id]?.accept).pass
  }
}

// ------------------------------------------------------------------ modes

async function audition() {
  const dir = join(BUILD, 'audition')
  mkdirSync(dir, { recursive: true })
  const only = option('--group')
  const reportFile = join(dir, 'report.json')
  const report = existsSync(reportFile) ? JSON.parse(readFileSync(reportFile, 'utf8')) : {}
  for (const group of cfg.audition) {
    if (only && group.id !== only) continue
    const clip = spec.voice_clips.find((c) => c.id === group.clip)
    const settings = cfg.clips[clip.id] ?? {}
    console.log(`\nAudition ${group.id} (${group.language}) with ${clip.id}: "${clip.text}"`)
    const rows = []
    for (const v of group.voices) {
      const generation = v.generation ?? settings.generation
      const t = await take({ text: clip.text, language: group.language, voice: v.id, generation, index: 0, accept: settings.accept, wordCount: clip.transcript_word_count, label: v.name })
      const copy = join(dir, `${group.id}-${v.name.replace(/\W+/g, '_')}.wav`)
      copyFileSync(t.file, copy)
      rows.push({ name: v.name, id: v.id, meta: v.meta, generation, duration: t.duration, target: clip.measured_duration_s, pass: t.check.pass, app_words: t.app?.words ?? null, heard: t.heard, app_heard: t.app?.text ?? null, ...t.measure, file: rel(copy) })
    }
    report[group.id] = rows
    console.table(rows.map(({ name, duration, pass, app_words, f0MedianHz, f0Spread10to90St, wordsPerSpeechSecond, heard }) =>
      ({ name, duration, pass, app_words, f0MedianHz, f0Spread10to90St, wps: wordsPerSpeechSecond, heard: heard.slice(0, 60) })))
  }
  writeFileSync(reportFile, JSON.stringify(report, null, 1))
  console.log(`\nWrote ${rel(reportFile)}`)
}

async function produce() {
  const only = option('--clip')
  const clipsFile = join(BUILD, 'clips.json')
  const previous = existsSync(clipsFile) ? JSON.parse(readFileSync(clipsFile, 'utf8')).clips : []
  const results = []
  let failed = false
  for (const clip of spec.voice_clips) {
    if (only && clip.id !== only) { const kept = previous.find((c) => c.id === clip.id); if (kept) results.push(kept); continue }
    const cast = cfg.cast[clip.language]
    if (!cast) throw new Error(`voices.json has no cast entry for language ${clip.language}`)
    const settings = cfg.clips[clip.id] ?? {}
    const target = clip.measured_duration_s
    console.log(`${clip.id} [${clip.language}, ${cast.name}] target ${target}s: ${clip.text}`)
    // Takes are tried in order until one is usable and lands within tolerance of the target.
    // Usable = the STT transcript matches the line word for word AND (when the whisper-check
    // tool is built) VibeScribe's own engine would paste exactly the pill's word count.
    // voices.json may pin a take (pin_take) chosen by ear-proxy measurements, e.g. a pause.
    const takes = []
    const pinned = Number.isInteger(settings.pin_take) ? settings.pin_take : null
    const indices = pinned !== null ? [pinned] : Array.from({ length: P.max_takes }, (_, i) => i)
    for (const index of indices) {
      const t = await take({ text: clip.text, language: clip.language, voice: cast.voice_id, generation: settings.generation, index, accept: settings.accept, wordCount: clip.transcript_word_count, label: clip.id })
      takes.push(t)
      const delta = t.duration - target
      console.log(`  take ${index}${pinned !== null ? ' (pinned)' : ''}: ${t.duration.toFixed(2)}s (${delta >= 0 ? '+' : ''}${delta.toFixed(2)}) ${t.check.pass ? 'PASS' : 'FAIL'} [${t.engine}] "${t.heard}"${t.check.pass ? '' : ` diffs=${JSON.stringify(t.check.diffs)}`}`)
      if (t.app) console.log(`    app engine: ${t.appPass ? 'PASS' : 'FAIL'} ${t.app.words} words (pill ${clip.transcript_word_count}) "${t.app.text}"`)
      if (t.check.pass && t.appPass && Math.abs(delta) <= P.duration_tolerance_s) break
    }
    const passing = takes.filter((t) => t.check.pass && t.appPass)
    if (!passing.length) {
      const why = takes.some((t) => t.check.pass) ? 'the app engine would paste a different word count' : 'no take passed the transcript check'
      console.error(`  ${clip.id}: no usable take (${why})${pinned !== null ? '; the pinned take failed: unpin or pick another' : ''}`)
      failed = true
      continue
    }
    const best = passing.reduce((a, b) => (Math.abs(b.duration - target) < Math.abs(a.duration - target) ? b : a))
    const out = join(BUILD, `${clip.id}.wav`)
    copyFileSync(best.file, out)
    const [samples] = decode(out)
    const levels = appMeter(samples, { fps: P.envelope_fps, tail: P.envelope_tail_s, gainDb: P.meter_gain_db })
    const speaking = levels.slice(0, Math.floor(best.duration * P.envelope_fps)).filter((v) => v > 0.05).sort((a, b) => a - b)
    const envelopeFile = join(BUILD, `${clip.id}.envelope.json`)
    writeFileSync(envelopeFile, JSON.stringify({
      fps: P.envelope_fps,
      levels,
      clip: clip.id,
      duration: best.duration,
      tail_s: P.envelope_tail_s,
      rule: 'levels[i] is the app LevelMeter value at clip_start + i/fps: per 1024-sample window target = clamp((20*log10(rms)+50)/40, 0, 1), level += (target-level)*(target>level ? 0.6 : 0.15). Includes a decay tail after the clip.'
    }))
    results.push({
      id: clip.id,
      language: clip.language,
      scene: clip.scene,
      text: clip.text,
      words: clip.transcript_word_count,
      file: rel(out),
      path: out,
      envelope: rel(envelopeFile),
      duration: best.duration,
      spec_start: clip.start,
      spec_duration: target,
      delta_vs_spec: Math.round((best.duration - target) * 1000) / 1000,
      voice: { id: cast.voice_id, name: cast.name },
      model: cfg.model,
      generation: settings.generation ?? null,
      take: best.take,
      cache_key: best.key,
      lufs: best.lufs,
      peak_dbfs: best.peak_dbfs,
      pauses_capped_s: best.pauses_capped,
      meter: { p50: speaking[Math.floor(speaking.length / 2)] ?? 0, p95: speaking[Math.floor(speaking.length * 0.95)] ?? 0 },
      voice_measure: best.measure,
      verification: { engine: best.engine, heard: best.heard, pass: true, wer: best.check.wer, note: best.check.note ?? null, takes_tried: takes.length },
      app_engine: appSummary(clip, best.app)
    })
  }
  const doc = {
    generated_by: 'video/voice.mjs',
    model: cfg.model,
    api_version: cfg.api_version,
    sample_rate: SR,
    channels: 1,
    format: 'WAV PCM 24-bit mono, 48 kHz, HPF 70 Hz, edges trimmed to ~80 ms, pauses capped, normalized to ' + `${P.target_lufs} LUFS`,
    envelope_fps: P.envelope_fps,
    clips: results
  }
  writeFileSync(clipsFile, JSON.stringify(doc, null, 1))
  console.log(`Wrote ${rel(clipsFile)}`)
  if (failed) process.exit(1)
}

/** Re-runs only the app-engine check on the current final clips (e.g. after a vocabulary change). */
async function appCheckOnly() {
  const clipsFile = join(BUILD, 'clips.json')
  const doc = JSON.parse(readFileSync(clipsFile, 'utf8'))
  for (const r of doc.clips) {
    const clip = spec.voice_clips.find((c) => c.id === r.id)
    r.app_engine = appSummary(clip, appTranscribe(join(ROOT, r.file), r.language))
    if (r.app_engine) console.log(`  ${r.id}: ${r.app_engine.words_match_spec ? 'OK' : 'WORD COUNT DIFFERS'} app would paste ${r.app_engine.words} words (pill ${r.words}): "${r.app_engine.text}"`)
  }
  writeFileSync(clipsFile, JSON.stringify(doc, null, 1))
}

if (flag('--list')) await listVoices()
else if (flag('--app-check')) await appCheckOnly()
else if (flag('--audition')) await audition()
else await produce()

