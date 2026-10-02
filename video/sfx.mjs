#!/usr/bin/env node
// Original sound effects for every cue type in timeline.sfx / timeline.preview.sfx, synthesised
// here (no sample libraries, no Apple sound files). The app-analogue start/stop sounds are new
// designs "in the spirit of" a glassy tick and a soft bubble pop, not copies.
//
//   node sfx.mjs        writes build/audio/sfx/<type>[-<variant>].wav (peak-normalised to 0 dBFS)
//                       and build/audio/sfx/cues.json (film + preview cue lists -> files)
//
// mix.mjs places each cue at its time with gain = level_db (the cue's peak level in dBFS).
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Biquad, SVF, SR, TAU, blepSaw, clamp, fdnReverb, midiToHz, pan, rng, stereo } from './lib/dsp.mjs'
import { writeWav } from './lib/wav.mjs'

const ROOT = dirname(fileURLToPath(import.meta.url))
const OUT = join(ROOT, 'build', 'audio', 'sfx')
const TL = JSON.parse(readFileSync(join(ROOT, 'build', 'timeline.json'), 'utf8'))

// ------------------------------------------------------------------ helpers

const buf = (dur) => stereo(Math.round(dur * SR))
const N = (o) => o[0].length

function put(o, i, v, p = 0) {
  if (i < 0 || i >= N(o)) return
  const [gl, gr] = pan(p)
  o[0][i] += v * gl * Math.SQRT2
  o[1][i] += v * gr * Math.SQRT2
}

function mixInto(dst, src, at = 0, gain = 1) {
  const i0 = Math.round(at * SR)
  for (let i = 0; i < N(src) && i0 + i < N(dst); i++) { dst[0][i0 + i] += src[0][i] * gain; dst[1][i0 + i] += src[1][i] * gain }
  return dst
}

/** Adds a short reverb tail (wet only) to o, in place. */
function verb(o, { wet = 0.25, decay = 1.0, damp = 7000, predelay = 0.012, hp = 300, size = 0.8 } = {}) {
  const [l, r] = fdnReverb(o, { decay, damp, predelay, hp, size })
  for (let i = 0; i < N(o); i++) { o[0][i] += l[i] * wet; o[1][i] += r[i] * wet }
  return o
}

/** Noise through a band-pass whose centre follows f(u), amplitude a(u), pan p(u); u = 0..1 over dur. */
function sweptNoise(o, at, dur, { f, q = 1.2, a, p = () => 0, seed = 1, lp = null, decorrelate = 0 }) {
  const i0 = Math.round(at * SR)
  const n = Math.round(dur * SR)
  const rL = rng(seed); const rR = rng(seed + 999)
  const svfL = new SVF(); const svfR = new SVF()
  const lpL = lp ? new Biquad('lowpass', lp, 0.7) : null
  const lpR = lp ? new Biquad('lowpass', lp, 0.7) : null
  for (let j = 0; j < n && i0 + j < N(o); j++) {
    const u = j / n
    if ((j & 31) === 0) { const fc = f(u); svfL.setFreq(fc, q); svfR.setFreq(fc, q) }
    const nl = rL() * 2 - 1
    const nr = decorrelate ? (nl * (1 - decorrelate) + (rR() * 2 - 1) * decorrelate) / Math.hypot(1 - decorrelate, decorrelate) : nl
    svfL.tick(nl); svfR.tick(nr)
    let l = svfL.bp; let r = svfR.bp
    if (lpL) { l = lpL.tick(l); r = lpR.tick(r) }
    const amp = a(u)
    const [gl, gr] = pan(p(u))
    o[0][i0 + j] += l * amp * gl * Math.SQRT2
    o[1][i0 + j] += r * amp * gr * Math.SQRT2
  }
  return o
}

const expSweep = (f0, f1) => (u) => f0 * (f1 / f0) ** u
const hann = (u) => Math.sin(Math.PI * clamp(u, 0, 1)) ** 2
const skew = (peak, pow = 1) => (u) => (u < peak ? (u / peak) ** pow : (1 - (u - peak) / (1 - peak)) ** 1.3)

function normalize(o, peak = 0.999) {
  let p = 0
  for (const ch of o) for (let i = 0; i < ch.length; i++) p = Math.max(p, Math.abs(ch[i]))
  if (p > 0) for (const ch of o) for (let i = 0; i < ch.length; i++) ch[i] *= peak / p
  return o
}

function fadeTail(o, dur = 0.01) {
  const n = Math.round(dur * SR)
  for (const ch of o) for (let j = 0; j < n; j++) ch[ch.length - 1 - j] *= j / n
  return o
}

// ------------------------------------------------------------------ building blocks

/** Decaying sine partial with optional pitch glide (ratio over glideT). */
function partial(o, at, f, amp, decay, { attack = 0.0008, p = 0, glide = 1, glideT = 0.03, len = decay * 7 } = {}) {
  const i0 = Math.round(at * SR)
  let ph = 0
  for (let j = 0; j < Math.round(len * SR); j++) {
    const tt = j / SR
    const fr = f * (1 + (glide - 1) * (1 - Math.exp(-tt / glideT)))
    ph += fr / SR
    put(o, i0 + j, Math.sin(TAU * ph) * amp * Math.min(1, tt / attack) * Math.exp(-tt / decay), p)
  }
  return o
}

/** Filtered noise burst. */
function burst(o, at, { type = 'bandpass', f = 2000, q = 1, amp = 1, decay = 0.01, len = decay * 8, seed = 1, p = 0, attack = 0.0004 }) {
  const i0 = Math.round(at * SR)
  const r = rng(seed)
  const bq = new Biquad(type, f, q)
  for (let j = 0; j < Math.round(len * SR); j++) {
    const tt = j / SR
    put(o, i0 + j, bq.tick(r() * 2 - 1) * amp * Math.min(1, tt / attack) * Math.exp(-tt / decay), p)
  }
  return o
}

/** Soft low-profile mechanical key. weight scales body pitch/size; up = release. */
function key(o, at, seed, { weight = 1, up = false, p = 0 } = {}) {
  const r = rng(seed)
  const j = () => 0.9 + 0.2 * r()
  if (!up) {
    burst(o, at, { type: 'highpass', f: 3200 * j(), q: 0.7, amp: 0.45, decay: 0.0022, seed: seed + 1, p })
    burst(o, at, { type: 'bandpass', f: 950 * j() / weight, q: 1.4, amp: 0.9, decay: 0.011, seed: seed + 2, p })
    partial(o, at + 0.001, 200 * j() / weight, 0.55, 0.016, { p, attack: 0.0015 })
    burst(o, at + 0.007 + 0.003 * r(), { type: 'bandpass', f: 1700 * j(), q: 1.2, amp: 0.3, decay: 0.006, seed: seed + 3, p })
  } else {
    burst(o, at, { type: 'highpass', f: 2600 * j(), q: 0.7, amp: 0.32, decay: 0.0018, seed: seed + 4, p })
    burst(o, at, { type: 'bandpass', f: 1450 * j(), q: 1.4, amp: 0.5, decay: 0.007, seed: seed + 5, p })
    partial(o, at + 0.001, 330 * j(), 0.25, 0.01, { p })
  }
  return o
}

function typeTick(o, at, seed) {
  const r = rng(seed)
  burst(o, at, { type: 'highpass', f: 3600 + 600 * r(), q: 0.7, amp: 0.4, decay: 0.0018, seed: seed + 1 })
  burst(o, at, { type: 'bandpass', f: 1300 + 300 * r(), q: 1.5, amp: 0.7, decay: 0.008, seed: seed + 2 })
  partial(o, at + 0.001, 260 + 40 * r(), 0.35, 0.011)
  return o
}

function uiTick(o, at, f = 2900, p = 0) {
  partial(o, at, f, 0.8, 0.008, { p })
  partial(o, at, f * 2.01, 0.35, 0.004, { p })
  burst(o, at, { type: 'highpass', f: 5000, amp: 0.15, decay: 0.0015, seed: Math.round(f) })
  return o
}

// ------------------------------------------------------------------ cue types

const TYPES = {
  pad_swell() {
    const o = buf(0.95)
    const notes = [62, 66, 69, 74]
    const r = rng(5)
    const voices = notes.flatMap((m) => [-10, 9].map((c) => ({ f: midiToHz(m + c / 100), ph: r(), p: r() * 1.4 - 0.7 })))
    const svfL = new SVF(); const svfR = new SVF()
    for (let i = 0; i < N(o); i++) {
      const t = i / SR
      if ((i & 31) === 0) { const fc = 250 * (3200 / 250) ** clamp(t / 0.8, 0, 1); svfL.setFreq(fc, 0.9); svfR.setFreq(fc, 0.9) }
      let l = 0; let rr = 0
      for (const v of voices) { const dt = v.f / SR; v.ph = (v.ph + dt) % 1; const s = blepSaw(v.ph, dt); const [gl, gr] = pan(v.p); l += s * gl; rr += s * gr }
      const env = t < 0.8 ? (t / 0.8) ** 2.4 : Math.exp(-(t - 0.8) / 0.03)
      o[0][i] += svfL.tick(l) * env; o[1][i] += svfR.tick(rr) * env
    }
    sweptNoise(o, 0, 0.85, { f: expSweep(400, 6000), q: 0.8, a: (u) => 0.5 * u ** 2.2 * (u > 0.94 ? (1 - u) / 0.06 : 1), seed: 51, decorrelate: 0.7 })
    return fadeTail(o)
  },
  impact() {
    const o = buf(2.4)
    // Low boom with a pitch drop.
    let ph = 0
    for (let j = 0; j < Math.round(1.6 * SR); j++) {
      const tt = j / SR
      ph += (42 + 55 * Math.exp(-tt / 0.06)) / SR
      put(o, j, Math.tanh(Math.sin(TAU * ph) * 1.6) * Math.exp(-tt / 0.45) * Math.min(1, tt / 0.002) * 0.9)
    }
    burst(o, 0, { type: 'lowpass', f: 2600, q: 0.7, amp: 0.7, decay: 0.09, seed: 61 })
    // Bright pluck on top (D5, A5, D6).
    ;[[74, 0.5, -0.3], [81, 0.38, 0.3], [86, 0.28, 0]].forEach(([m, a, p]) => {
      partial(o, 0.004, midiToHz(m), a, 0.32, { p })
      partial(o, 0.004, midiToHz(m) * 2, a * 0.25, 0.08, { p })
    })
    verb(o, { wet: 0.45, decay: 1.8, damp: 5500, predelay: 0.02, size: 1 })
    return fadeTail(o, 0.2)
  },
  ui_tick: () => uiTick(buf(0.08), 0.001),
  whoosh_short() {
    const o = buf(0.5)
    sweptNoise(o, 0, 0.48, { f: (u) => (u < 0.6 ? 600 * (3800 / 600) ** (u / 0.6) : 3800 - 2000 * ((u - 0.6) / 0.4)), q: 1.1, a: skew(0.6, 1.6), p: (u) => -0.3 + 0.6 * u, seed: 71, decorrelate: 0.4 })
    sweptNoise(o, 0, 0.48, { f: () => 500, q: 0.6, a: (u) => 0.4 * skew(0.55, 2)(u), seed: 72, decorrelate: 0.4 })
    return fadeTail(o)
  },
  glass_tap() {
    const o = buf(0.45)
    partial(o, 0, 2350, 0.8, 0.09)
    partial(o, 0, 3710, 0.4, 0.06, { p: 0.2 })
    partial(o, 0, 5920, 0.25, 0.04, { p: -0.2 })
    burst(o, 0, { type: 'highpass', f: 6000, amp: 0.2, decay: 0.0015, seed: 81 })
    return fadeTail(verb(o, { wet: 0.3, decay: 0.7, size: 0.6 }))
  },
  key_down: (v = 1) => key(buf(0.12), 0.001, 100 + v * 17),
  key_up: (v = 1) => key(buf(0.09), 0.001, 200 + v * 17, { up: true }),
  key_press(v = 1) {
    const o = buf(0.22)
    key(o, 0.001, 300 + v * 17, { weight: 1.3 })
    key(o, 0.095, 320 + v * 17, { weight: 1.3, up: true })
    return o
  },
  type_tick: (v = 1) => typeTick(buf(0.07), 0.001, 400 + v * 13),
  start_tick() {
    // Glassy, short, high: a struck glass rod (original design).
    const o = buf(0.4)
    partial(o, 0, 2093, 0.85, 0.05, { glide: 0.985, glideT: 0.02 })
    partial(o, 0, 4199, 0.42, 0.024, { p: 0.1 })
    partial(o, 0, 6380, 0.22, 0.014, { p: -0.1 })
    partial(o, 0, 1046.5, 0.12, 0.04)
    burst(o, 0, { type: 'highpass', f: 7000, amp: 0.18, decay: 0.001, seed: 91 })
    return fadeTail(verb(o, { wet: 0.18, decay: 0.6, size: 0.5 }))
  },
  stop_pop() {
    // Soft bubble pop: a sine whose pitch springs upward as it decays (original design).
    const o = buf(0.3)
    let ph = 0
    for (let j = 0; j < Math.round(0.16 * SR); j++) {
      const tt = j / SR
      const f = 360 + 760 * (1 - Math.exp(-tt / 0.012))
      ph += f / SR
      put(o, j, (Math.sin(TAU * ph) + 0.12 * Math.sin(2 * TAU * ph)) * Math.min(1, tt / 0.0012) * Math.exp(-tt / 0.034))
    }
    burst(o, 0, { type: 'bandpass', f: 1500, q: 1, amp: 0.12, decay: 0.002, seed: 93 })
    return fadeTail(verb(o, { wet: 0.12, decay: 0.45, size: 0.5 }))
  },
  text_land() {
    const o = buf(0.14)
    burst(o, 0.001, { type: 'bandpass', f: 3200, q: 0.9, amp: 0.8, decay: 0.006, seed: 101 })
    burst(o, 0.01, { type: 'bandpass', f: 2600, q: 0.9, amp: 0.5, decay: 0.008, seed: 102 })
    partial(o, 0.001, 140, 0.3, 0.015)
    return o
  },
  pointer_click() {
    const o = buf(0.1)
    burst(o, 0.001, { type: 'highpass', f: 2200, q: 0.7, amp: 0.55, decay: 0.0015, seed: 111 })
    burst(o, 0.001, { type: 'bandpass', f: 620, q: 1.3, amp: 0.6, decay: 0.006, seed: 112 })
    partial(o, 0.001, 110, 0.5, 0.012, { attack: 0.001 })
    return o
  },
  whoosh_soft() {
    const o = buf(0.65)
    sweptNoise(o, 0, 0.62, { f: (u) => (u < 0.5 ? 400 * (1600 / 400) ** (u / 0.5) : 1600 * (500 / 1600) ** ((u - 0.5) / 0.5)), q: 0.8, a: hann, p: (u) => 0.25 - 0.5 * u, seed: 121, decorrelate: 0.5 })
    return fadeTail(o)
  },
  whoosh_rise() {
    const o = buf(0.82)
    sweptNoise(o, 0, 0.8, { f: expSweep(300, 6500), q: 1.6, a: (u) => u ** 1.6 * (u > 0.97 ? (1 - u) / 0.03 : 1), seed: 131, decorrelate: 0.6 })
    // Rising tonal layer.
    const lp = [new Biquad('lowpass', 1400, 0.7), new Biquad('lowpass', 1400, 0.7)]
    let ph = 0
    for (let j = 0; j < Math.round(0.8 * SR); j++) {
      const u = j / (0.8 * SR)
      const f = 160 * 4 ** u
      const dt = f / SR
      ph = (ph + dt) % 1
      const v = blepSaw(ph, dt) * 0.18 * u ** 1.4 * (u > 0.97 ? (1 - u) / 0.03 : 1)
      o[0][j] += lp[0].tick(v); o[1][j] += lp[1].tick(v)
    }
    return fadeTail(o, 0.005)
  },
  ui_tick_seq() {
    const o = buf(0.5)
    ;[2700, 2900, 3150].forEach((f, i) => uiTick(o, 0.001 + i * 0.2, f, -0.2 + 0.2 * i))
    return o
  },
  whoosh_sweep() {
    const o = buf(0.85)
    sweptNoise(o, 0, 0.82, { f: expSweep(700, 2600), q: 1, a: (u) => Math.sin(Math.PI * u) ** 1.2, p: (u) => -0.9 + 1.8 * u, seed: 141 })
    sweptNoise(o, 0, 0.82, { f: () => 380, q: 0.7, a: (u) => 0.35 * Math.sin(Math.PI * u) ** 2, p: (u) => -0.6 + 1.2 * u, seed: 142 })
    return fadeTail(o)
  },
  msg_receive() {
    const o = buf(0.55)
    for (const [at, m] of [[0.001, 81], [0.085, 88]]) {
      partial(o, at, midiToHz(m), 0.7, 0.085, { attack: 0.003 })
      partial(o, at, midiToHz(m) * 2, 0.12, 0.04, { attack: 0.003 })
    }
    return fadeTail(verb(o, { wet: 0.2, decay: 0.6, size: 0.6 }))
  },
  panel_in() {
    const o = buf(0.26)
    sweptNoise(o, 0, 0.24, { f: expSweep(2600, 900), q: 0.8, a: skew(0.2, 1.2), seed: 151, decorrelate: 0.5 })
    return fadeTail(o)
  },
  panel_out() {
    const o = buf(0.18)
    sweptNoise(o, 0, 0.16, { f: expSweep(900, 2800), q: 0.8, a: skew(0.35, 1.2), seed: 161, decorrelate: 0.5 })
    return fadeTail(o)
  },
  whoosh_micro() {
    const o = buf(0.24)
    sweptNoise(o, 0, 0.22, { f: expSweep(1200, 3200), q: 1.1, a: skew(0.45, 1.5), seed: 171, decorrelate: 0.4 })
    return fadeTail(o)
  },
  whip() {
    const o = buf(0.42)
    sweptNoise(o, 0, 0.4, { f: expSweep(4200, 650), q: 1.4, a: (u) => Math.min(1, u / 0.06) * (1 - u) ** 1.6, p: (u) => 0.5 - u, seed: 181, decorrelate: 0.3 })
    sweptNoise(o, 0, 0.3, { f: () => 260, q: 0.7, a: (u) => 0.45 * Math.min(1, u / 0.1) * (1 - u) ** 2, seed: 182 })
    return fadeTail(o)
  },
  msg_send() {
    const o = buf(0.42)
    sweptNoise(o, 0, 0.36, { f: expSweep(700, 3200), q: 1, a: hann, p: (u) => -0.2 + 0.5 * u, seed: 191 })
    let ph = 0
    for (let j = 0; j < Math.round(0.2 * SR); j++) {
      const tt = j / SR
      ph += (600 + 900 * (tt / 0.2)) / SR
      put(o, j + Math.round(0.05 * SR), Math.sin(TAU * ph) * 0.22 * Math.sin(Math.PI * tt / 0.2))
    }
    return fadeTail(o)
  },
  whoosh_fall() {
    const o = buf(0.82)
    sweptNoise(o, 0, 0.8, { f: expSweep(5000, 280), q: 1.3, a: skew(0.32, 1.3), seed: 201, decorrelate: 0.6 })
    const lp = [new Biquad('lowpass', 1200, 0.7), new Biquad('lowpass', 1200, 0.7)]
    let ph = 0
    for (let j = 0; j < Math.round(0.8 * SR); j++) {
      const u = j / (0.8 * SR)
      const f = 700 * (150 / 700) ** u
      const dt = f / SR
      ph = (ph + dt) % 1
      const v = blepSaw(ph, dt) * 0.16 * skew(0.3, 1.2)(u)
      o[0][j] += lp[0].tick(v); o[1][j] += lp[1].tick(v)
    }
    return fadeTail(o)
  },
  sonar_ping() {
    const o = buf(2.2)
    for (const [at, f, a] of [[0.001, 1240, 1], [0.851, 1175, 0.8]]) {
      partial(o, at, f, 0.75 * a, 0.26, { attack: 0.004 })
      partial(o, at, f * 2.003, 0.12 * a, 0.12, { attack: 0.004 })
    }
    return fadeTail(verb(o, { wet: 0.38, decay: 1.4, size: 0.9, predelay: 0.03 }), 0.2)
  },
  riser() {
    const o = buf(0.82)
    sweptNoise(o, 0, 0.8, { f: expSweep(400, 8500), q: 2, a: (u) => u ** 2 * (u > 0.985 ? (1 - u) / 0.015 : 1), seed: 211, decorrelate: 0.6 })
    const svf = [new SVF(), new SVF()]
    let ph = 0
    for (let j = 0; j < Math.round(0.8 * SR); j++) {
      const u = j / (0.8 * SR)
      if ((j & 31) === 0) for (const s of svf) s.setFreq(500 * 12 ** u, 0.9)
      const f = 220 * 4 ** u
      const dt = f / SR
      ph = (ph + dt) % 1
      const v = blepSaw(ph, dt) * 0.22 * u ** 1.8 * (u > 0.985 ? (1 - u) / 0.015 : 1)
      o[0][j] += svf[0].tick(v); o[1][j] += svf[1].tick(v)
    }
    return o
  },
  type_tick_seq(count = 3) {
    const times = count === 9 ? Array.from({ length: 9 }, (_, k) => 0.045 + 0.055 * k) : Array.from({ length: count }, (_, k) => 0.001 + 0.12 * k)
    const o = buf(times[times.length - 1] + 0.08)
    times.forEach((t, k) => typeTick(o, t, 500 + k * 7))
    return o
  },
  bloom() {
    const o = buf(2.6)
    const notes = [86, 90, 93, 98]
    for (let i = 0; i < Math.round(2.3 * SR); i++) {
      const t = i / SR
      const env = t < 0.4 ? (t / 0.4) ** 2 : Math.exp(-(t - 0.4) / 0.6)
      let l = 0; let r = 0
      notes.forEach((m, k) => {
        const f = midiToHz(m)
        const trem = 1 + 0.25 * Math.sin(TAU * (7 + k * 1.3) * t + k)
        const s = Math.sin(TAU * f * t) * trem * (0.5 - k * 0.07)
        const [gl, gr] = pan(-0.45 + k * 0.3)
        l += s * gl; r += s * gr
      })
      o[0][i] += l * env; o[1][i] += r * env
    }
    sweptNoise(o, 0, 0.6, { f: expSweep(2000, 7000), q: 1.2, a: (u) => 0.4 * (u < 0.66 ? (u / 0.66) ** 2 : (1 - u) / 0.34), seed: 221, decorrelate: 0.8 })
    return fadeTail(verb(o, { wet: 0.45, decay: 1.6, size: 1 }), 0.3)
  }
}

// Variants: a few takes of the keys so repeated presses are not identical.
const VARIANTS = { key_down: 3, key_up: 3, key_press: 2, type_tick: 3 }
const hash = (s) => [...s].reduce((h, c) => (Math.imul(h, 31) + c.charCodeAt(0)) >>> 0, 7)

function fileFor(cue) {
  if (cue.type === 'type_tick_seq') {
    const count = /nine/i.test(cue.note || '') ? 9 : 3
    return { key: `type_tick_seq-${count}`, make: () => TYPES.type_tick_seq(count) }
  }
  const v = VARIANTS[cue.type]
  if (v) {
    const k = (hash(cue.id) % v) + 1
    return { key: `${cue.type}-${k}`, make: () => TYPES[cue.type](k) }
  }
  if (!TYPES[cue.type]) throw new Error(`no synth for sfx type "${cue.type}" (${cue.id})`)
  return { key: cue.type, make: () => TYPES[cue.type]() }
}

mkdirSync(OUT, { recursive: true })
const made = new Map()
const lists = { film: TL.sfx, preview: TL.preview.sfx }
const manifest = { generated_by: 'video/sfx.mjs', note: 'level_db is the peak level of the cue in dBFS before the master loudness normalisation', film: [], preview: [] }
for (const [mode, cues] of Object.entries(lists)) {
  for (const cue of cues) {
    const { key, make } = fileFor(cue)
    const file = join(OUT, `${key}.wav`)
    if (!made.has(key)) {
      const o = normalize(make())
      writeWav(file, o, { bits: 24 })
      made.set(key, (o[0].length / SR).toFixed(2))
    }
    manifest[mode].push({ id: cue.id, type: cue.type, time: cue.time, level_db: cue.level_db, file: relative(ROOT, file) })
  }
}
writeFileSync(join(OUT, 'cues.json'), JSON.stringify(manifest, null, 2))
console.log(`sfx: ${made.size} sounds -> ${relative(ROOT, OUT)}/  (${[...made].map(([k, d]) => `${k} ${d}s`).join(', ')})`)
console.log(`cues: film ${manifest.film.length}, preview ${manifest.preview.length}`)
