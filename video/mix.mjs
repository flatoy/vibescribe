#!/usr/bin/env node
// Mixes the voice clips, the sound effects and the music bed for the film and the App Preview,
// then masters each with a two-pass ffmpeg loudnorm.
//
//   node mix.mjs [--only film|preview] [--stems]   (--stems also writes build/audio/stem-<mode>-{voice,sfx,music}.wav)
//
// Inputs:  build/timeline.json (voice + sfx cue times), build/audio/L*.wav (voice.mjs),
//          build/audio/sfx/cues.json (sfx.mjs), build/audio/music-{film,preview}.wav (music.mjs)
// Outputs: build/audio/mix-film.wav, build/audio/mix-preview.wav  (48 kHz stereo, 24-bit,
//          -16 LUFS integrated, true peak <= -2 dBTP so the AAC encode stays under -1.5 dBTP),
//          build/audio/mix-report.json
//
// Ducking: the music follows a sidechain from the voice bus (-8 dB, attack 30 ms, release 250 ms,
// 120 ms hold so it does not pump between words) and dips -3 dB under each app start/stop sound.
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { SR, clamp, dbToGain, gainToDb, limit, lufs, peakDb, stereo } from './lib/dsp.mjs'
import { decode, writeWav } from './lib/wav.mjs'

const ROOT = dirname(fileURLToPath(import.meta.url))
const AUDIO = join(ROOT, 'build', 'audio')
const TL = JSON.parse(readFileSync(join(ROOT, 'build', 'timeline.json'), 'utf8'))

const TARGET = { I: -16, TP: -2.0, LRA: 11 } // TP 0.5 dB under the -1.5 dBTP delivery limit (AAC overshoot margin)
const PRE_CEILING_DB = -2.6 // sample-peak ceiling before loudnorm, so loudnorm can stay linear
const DUCK = { voiceDb: -8, appSoundDb: -3, attack: 0.03, release: 0.25, hold: 0.12 }
const MUSIC_LUFS = -20 // bed level against the -18 LUFS voice clips (before ducking)
const SFX_TRIM_DB = 3 // cue levels are peak dBFS at the -18 LUFS voice reference; +3 dB keeps the UI sounds readable on laptop speakers
const APP_SOUNDS = new Set(['start_tick', 'stop_pop'])

function need(path, hint) {
  if (!existsSync(path)) throw new Error(`missing ${path.replace(ROOT + '/', '')}: run ${hint} first`)
  return path
}

function place(bus, chans, at, gain = 1) {
  const i0 = Math.round(at * SR)
  const n = bus[0].length
  for (let c = 0; c < 2; c++) {
    const src = chans[Math.min(c, chans.length - 1)]
    const dst = bus[c]
    for (let i = 0; i < src.length; i++) {
      const k = i0 + i
      if (k < 0) continue
      if (k >= n) break
      dst[k] += src[i] * gain
    }
  }
}

/** Ducking gain curve (linear) for the music bus. */
function duckCurve(n, voice, appCues) {
  // Voice activity from a 10 ms peak follower, mapped -54..-36 dBFS -> 0..1.
  const target = new Float32Array(n) // target reduction in dB (<= 0)
  const fast = Math.exp(-1 / (0.01 * SR))
  let env = 0
  let holdUntil = -1
  let act = 0
  for (let i = 0; i < n; i++) {
    const x = Math.max(Math.abs(voice[0][i]), Math.abs(voice[1][i]))
    env = x > env ? x : x + (env - x) * fast
    const a = clamp((gainToDb(env) + 54) / 18, 0, 1)
    if (a >= act) { act = a; holdUntil = i + DUCK.hold * SR } else if (i > holdUntil) act = a
    target[i] = DUCK.voiceDb * act
  }
  for (const c of appCues) {
    const i0 = Math.max(0, Math.round((c.time - 0.02) * SR)); const i1 = Math.min(n, Math.round((c.time + 0.25) * SR))
    for (let i = i0; i < i1; i++) target[i] = Math.min(target[i], DUCK.appSoundDb)
  }
  // Attack/release smoothing in dB.
  const att = Math.exp(-1 / (DUCK.attack * SR)); const rel = Math.exp(-1 / (DUCK.release * SR))
  const g = new Float32Array(n)
  let cur = 0
  for (let i = 0; i < n; i++) {
    const t = target[i]
    cur = t < cur ? t + (cur - t) * att : t + (cur - t) * rel
    g[i] = dbToGain(cur)
  }
  return g
}

function ffmpeg(args) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', ...args], { encoding: 'utf8', maxBuffer: 1 << 26 })
  if (r.status !== 0) throw new Error(`ffmpeg failed: ${r.stderr.slice(-2000)}`)
  return r.stderr
}

const lastJson = (s) => JSON.parse(s.slice(s.lastIndexOf('{'), s.lastIndexOf('}') + 1))

const LN = `loudnorm=I=${TARGET.I}:TP=${TARGET.TP}:LRA=${TARGET.LRA}`
const measure = (input) => {
  const m = lastJson(ffmpeg(['-i', input, '-af', `${LN}:print_format=json`, '-f', 'null', '-']))
  for (const k of Object.keys(m)) if (k !== 'normalization_type') m[k] = Number(m[k])
  return m
}

function loudnorm(input, output, I = TARGET.I) {
  const ln = `loudnorm=I=${I.toFixed(2)}:TP=${TARGET.TP}:LRA=${TARGET.LRA}`
  const m = measure(input)
  const pass2 = `${ln}:measured_I=${m.input_i}:measured_TP=${m.input_tp}:measured_LRA=${m.input_lra}:measured_thresh=${m.input_thresh}:offset=${m.target_offset}:linear=true:print_format=json`
  const r = lastJson(ffmpeg(['-y', '-i', input, '-af', `${pass2},aresample=${SR}:filter_size=64:phase_shift=12:cutoff=0.97`, '-ar', String(SR), '-ac', '2', '-c:a', 'pcm_s24le', output]))
  return { pass1: m, pass2: r }
}

function ebur128(file) {
  const s = ffmpeg(['-i', file, '-af', 'ebur128=peak=true:framelog=quiet', '-f', 'null', '-'])
  const tail = s.slice(s.lastIndexOf('Summary:'))
  const num = (re) => Number((tail.match(re) || [])[1])
  return { I: num(/I:\s+(-?[\d.]+) LUFS/), LRA: num(/LRA:\s+(-?[\d.]+) LU/), TP: num(/Peak:\s+(-?[\d.]+) dBFS/) }
}

function mix(mode) {
  const t0 = Date.now()
  const isFilm = mode === 'film'
  const dur = isFilm ? TL.duration : TL.preview.music.duration
  const n = Math.round(dur * SR)
  const voiceCues = isFilm ? TL.voice : TL.preview.voice
  const cues = JSON.parse(readFileSync(need(join(AUDIO, 'sfx', 'cues.json'), 'node sfx.mjs'), 'utf8'))[mode]

  const voice = stereo(n)
  for (const v of voiceCues) place(voice, decode(need(join(ROOT, v.file), 'node voice.mjs'), { channels: 1 }), v.start)

  const sfx = stereo(n)
  const cache = new Map()
  for (const c of cues) {
    if (!cache.has(c.file)) cache.set(c.file, decode(need(join(ROOT, c.file), 'node sfx.mjs'), { channels: 2 }))
    place(sfx, cache.get(c.file), c.time, dbToGain(c.level_db + SFX_TRIM_DB))
  }

  // Any bed works (see README, "Swapping the music"): it is gain-matched to MUSIC_LUFS first, so
  // the voice/music balance does not depend on the level the track was exported at.
  const music = decode(need(join(AUDIO, `music-${mode}.wav`), 'node music.mjs'), { channels: 2 })
  const musicGain = dbToGain(MUSIC_LUFS - lufs(music))
  for (const ch of music) for (let i = 0; i < ch.length; i++) ch[i] *= musicGain
  const duck = duckCurve(n, voice, cues.filter((c) => APP_SOUNDS.has(c.type)))

  const out = stereo(n)
  for (let c = 0; c < 2; c++) {
    for (let i = 0; i < n; i++) out[c][i] = (i < music[c].length ? music[c][i] * duck[i] : 0) + voice[c][i] + sfx[c][i]
  }
  // Programme fades: the film opens on a pluck, so it gets 40 ms against a click; the preview gets
  // a short fade-in and a 1 s fade-out; the film fades with its end slate.
  const fadeIn = isFilm ? 0.04 : 0.12
  const fadeOut = isFilm ? [57.4, dur] : [dur - 1.0, dur]
  for (let i = 0; i < n; i++) {
    const t = i / SR
    let g = 1
    if (fadeIn && t < fadeIn) g *= Math.sin((t / fadeIn) * Math.PI / 2)
    if (t >= fadeOut[0]) g *= Math.cos(clamp((t - fadeOut[0]) / (fadeOut[1] - fadeOut[0]), 0, 1) * Math.PI / 2)
    out[0][i] *= g; out[1][i] *= g
  }

  // Pre-master: gain to the target, then a lookahead limiter so the loudnorm pass stays linear.
  const before = lufs(out)
  const gain = dbToGain(TARGET.I - before)
  if (process.argv.includes('--stems')) {
    // Debug/inspection: the three buses at the pre-master gain (before limiting and fades).
    const bus = (fn) => [0, 1].map((c) => Float32Array.from({ length: n }, (_, i) => fn(c, i) * gain))
    writeWav(join(AUDIO, `stem-${mode}-voice.wav`), bus((c, i) => voice[c][i]), { bits: 32 })
    writeWav(join(AUDIO, `stem-${mode}-sfx.wav`), bus((c, i) => sfx[c][i]), { bits: 32 })
    writeWav(join(AUDIO, `stem-${mode}-music.wav`), bus((c, i) => (i < music[c].length ? music[c][i] * duck[i] : 0)), { bits: 32 })
  }
  for (const ch of out) for (let i = 0; i < n; i++) ch[i] *= gain
  let gr = limit(out, { ceilingDb: PRE_CEILING_DB, lookahead: 0.005, release: 0.08 })
  const pre = join(AUDIO, `mix-${mode}.pre.wav`)
  writeWav(pre, out, { bits: 32 })
  // Limiting lowers the loudness a little: re-measure with ffmpeg and trim until the pre-master
  // sits on the target, so the loudnorm pass only has to apply (near) unity linear gain.
  for (let k = 0; k < 4; k++) {
    const m = measure(pre)
    if (Math.abs(m.input_i - TARGET.I) < 0.05) break
    const g = dbToGain(TARGET.I - m.input_i)
    for (const ch of out) for (let i = 0; i < n; i++) ch[i] *= g
    gr = Math.max(gr, limit(out, { ceilingDb: PRE_CEILING_DB, lookahead: 0.005, release: 0.08 }))
    writeWav(pre, out, { bits: 32 })
  }

  const final = join(AUDIO, `mix-${mode}.wav`)
  let ln = loudnorm(pre, final)
  let meas = ebur128(final)
  // loudnorm and the EBU R128 meter disagree by ~0.1-0.2 LU; trim once so the meter reads the target.
  if (Math.abs(meas.I - TARGET.I) >= 0.08) {
    ln = loudnorm(pre, final, TARGET.I + (TARGET.I - meas.I))
    meas = ebur128(final)
  }
  const duckStats = { minDb: Number(gainToDb(duck.reduce((a, b) => Math.min(a, b), 1)).toFixed(1)) }
  const report = {
    file: final.replace(ROOT + '/', ''),
    duration_s: dur,
    pre: { lufs: Number(before.toFixed(2)), gain_db: Number(gainToDb(gain).toFixed(2)), limiter_db: Number(gr.toFixed(2)), peak_dbfs: Number(peakDb(out).toFixed(2)) },
    loudnorm: { type: ln.pass2.normalization_type, input_i: Number(ln.pass1.input_i), input_tp: Number(ln.pass1.input_tp), output_i: Number(ln.pass2.output_i), output_tp: Number(ln.pass2.output_tp) },
    ebur128: meas,
    duck: duckStats,
    voices: voiceCues.map((v) => `${v.clip}@${v.start}`),
    sfx_cues: cues.length
  }
  console.log(`mix-${mode}.wav  ${dur} s  I ${meas.I} LUFS  TP ${meas.TP} dBTP  LRA ${meas.LRA} LU  loudnorm ${report.loudnorm.type}  pre-limiter ${report.pre.limiter_db} dB  (${((Date.now() - t0) / 1000).toFixed(1)} s)`)
  if (report.loudnorm.type !== 'linear') console.warn(`  warning: loudnorm fell back to ${report.loudnorm.type} mode`)
  return report
}

const only = process.argv.includes('--only') ? process.argv[process.argv.indexOf('--only') + 1] : null
const reportPath = join(AUDIO, 'mix-report.json')
const report = existsSync(reportPath) ? JSON.parse(readFileSync(reportPath, 'utf8')) : {}
for (const mode of ['film', 'preview']) if (!only || only === mode) report[mode] = mix(mode)
writeFileSync(reportPath, JSON.stringify(report, null, 2))
