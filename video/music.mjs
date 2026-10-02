#!/usr/bin/env node
// Original, procedurally generated music beds for the launch film and the App Preview cut.
// No samples, no loops from libraries: every note is synthesised here from timeline.music
// (150 BPM half-time, D major, D-Bm-G-A, one chord per bar).
//
//   node music.mjs            writes build/audio/music-film.wav, music-preview.wav and
//                             music.envelope.json (kick/bass level that drives the cold-open bars)
//
// To use your own track instead, see README.md ("Swapping the music"): drop a WAV at
// build/audio/music-film.wav (and music-preview.wav) and re-run `npm run mix && npm run encode`.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Biquad, SVF, SR, TAU, blepSaw, clamp, dbToGain, fdnReverb, gainToDb, limit, lufs, midiToHz, pan, peakDb, pingPong, rng, soft, stereo, sweepLowpass, widen } from './lib/dsp.mjs'
import { writeWav } from './lib/wav.mjs'

const ROOT = dirname(fileURLToPath(import.meta.url))
const OUT = join(ROOT, 'build', 'audio')
const TL = JSON.parse(readFileSync(join(ROOT, 'build', 'timeline.json'), 'utf8'))
const M = TL.music
const BEAT = 60 / M.bpm
const BAR = BEAT * 4
const STEP = BEAT / 4
const TARGET_LUFS = -20 // bed level before the mix; mix.mjs normalises the whole programme to -16
const CEILING_DB = -3

// Voicings (MIDI). Pad voicings share D3/D4 where they can so chord changes stay smooth.
const PROG = ['D', 'Bm', 'G', 'A']
const PAD = { D: [50, 54, 57, 62], Bm: [50, 54, 59, 62], G: [50, 55, 59, 62], A: [49, 52, 57, 64] }
const ARP = { D: [62, 66, 69, 74], Bm: [59, 62, 66, 71], G: [59, 62, 67, 71], A: [61, 64, 69, 73] }
const BASS = { D: 38, Bm: 35, G: 31, A: 33 }
const COUNTER = { D: [78, 76], Bm: [74, 73], G: [74, 71], A: [73, 76] }

// Patterns in 16th steps of one 16-step bar.
const ARP_PATTERNS = {
  arp8: [[0, 0], [2, 1], [4, 2], [6, 3], [8, 2], [10, 1], [12, 2], [14, 3]],
  sparse: [[0, 0], [3, 2], [6, 1], [10, 3], [12, 2]],
  arp16: Array.from({ length: 16 }, (_, i) => [i, [0, 1, 2, 3, 2, 1, 3, 2][i % 8]]),
  bars: [[0, 0], [8, 2]]
}
const BASS_PATTERNS = {
  hold: [[0, 0, 16]],
  root: [[0, 0, 6], [6, 0, 2], [10, 0, 5]],
  moving: [[0, 0, 4], [4, 12, 2], [6, 0, 2], [10, 7, 2], [12, 0, 2], [14, 12, 2]]
}

// ------------------------------------------------------------------ arrangement

/** Piecewise-linear automation through [t, v] points. */
function auto(points) {
  return (t) => {
    if (t <= points[0][0]) return points[0][1]
    for (let i = 1; i < points.length; i++) {
      const [t1, v1] = points[i]
      if (t < t1) {
        const [t0, v0] = points[i - 1]
        return t1 === t0 ? v1 : v0 + (v1 - v0) * (t - t0) / (t1 - t0)
      }
    }
    return points[points.length - 1][1]
  }
}

const base = { pad: 0.55, kick: null, rim: null, snare: null, hats: null, sub: null, arp: null, arpLevel: 0.5, arpBright: 0.75, counter: false }

function filmPlan() {
  const dur = TL.duration
  const grid0 = 0.8
  const S = {
    intro: { ...base, introPluck: true },
    hit: { ...base, kick: [0], sub: 'hold', arp: 'arp8', arpLevel: 0.75, arpBright: 0.7 },
    verse_1: { ...base, kick: [0, 10], rim: [8], sub: 'root', arp: 'sparse', arpLevel: 0.45 },
    verse_2: { ...base, kick: [0, 10], rim: [8], sub: 'root', arp: 'sparse', arpLevel: 0.45, hats: 'eighths', counter: true },
    verse_3: { ...base, kick: [0, 10], rim: [8], sub: 'moving', arp: 'sparse', arpLevel: 0.5, hats: 'eighths', counter: true },
    verse_4: { ...base, kick: [0, 10], rim: [8], sub: 'moving', arp: 'sparse', arpLevel: 0.42, arpBright: 0.35, hats: 'thin' },
    breakdown: { ...base, sub: 'hold', arp: 'bars', arpLevel: 0.4, arpBright: 0.4 },
    riser: { ...base, sub: 'hold', roll: true },
    drop: { ...base, kick: [0, 6, 10], snare: [8], sub: 'moving', arp: 'arp16', arpLevel: 0.5, arpBright: 0.8, hats: 'full', counter: true },
    outro: { ...base }
  }
  const chordAt = (t) => {
    if (t < grid0) return 'D'
    const k = Math.floor((t - grid0) / BAR + 1e-9)
    if (k <= 25) return PROG[k % 4]
    if (k <= 28) return ['D', 'Bm', 'A'][k - 26]
    if (k <= 32) return PROG[(k - 29) % 4]
    return 'D'
  }
  return {
    name: 'film',
    dur,
    grid0,
    sections: M.sections.map((s) => ({ ...s, set: S[s.id] })),
    chordAt,
    padLevel: auto([[0, 0], [0.78, 0.85], [0.8, 0.95], [3.6, 0.8], [4.4, 0.55], [42.2, 0.55], [42.6, 0.9], [46.4, 0.85], [47.2, 1.0], [47.4, 0.62], [53.5, 0.62], [53.7, 1.0], [58.4, 0.9]]),
    padCut: auto([[0, 280], [0.8, 1900], [26.4, 1800], [26.8, 2600], [27.9, 2600], [28.4, 1800], [35.2, 1800], [36.8, 1150], [42.4, 1150], [42.5, 1500], [46.4, 900], [47.2, 7000], [47.35, 2600], [53.6, 2600], [54.2, 2200], [58.4, 1000]]),
    finalAt: 53.6,
    bells: [[54.0, 1.0]],
    stabs: [47.2, 48.8, 50.4, 52.0],
    ticks: 3.6,
    roll: [46.4, 47.2],
    fadeIn: 0,
    fadeOut: [57.4, 58.4],
    envelope: true
  }
}

function previewPlan() {
  const P = TL.preview.music
  const dur = P.duration
  const grid0 = -0.4 // puts the outro (26.8) on a downbeat
  const q = (t) => grid0 + Math.round((t - grid0) / BEAT) * BEAT // arrangement changes land on beats
  const S = {
    verse_1: { ...base, kick: [0, 10], rim: [8], sub: 'root', arp: 'sparse', arpLevel: 0.45 },
    verse_2: { ...base, kick: [0, 10], rim: [8], sub: 'root', arp: 'sparse', arpLevel: 0.45, hats: 'eighths', counter: true },
    verse_3: { ...base, kick: [0, 10], rim: [8], sub: 'moving', arp: 'sparse', arpLevel: 0.5, arpBright: 0.65, hats: 'eighths', counter: true },
    outro: { ...base }
  }
  const finalAt = q(P.sections.find((s) => s.id === 'outro').start)
  const chordAt = (t) => {
    if (t >= finalAt - 1e-6) return 'D'
    const k = Math.floor((t - grid0) / BAR + 1e-9)
    return PROG[(k + 3) % 4]
  }
  return {
    name: 'preview',
    dur,
    grid0,
    sections: P.sections.map((s) => ({ ...s, start: s.start === 0 ? 0 : q(s.start), end: s.end >= dur ? dur : q(s.end), set: S[s.id] })),
    chordAt,
    padLevel: auto([[0, 0.55], [finalAt - 0.05, 0.6], [finalAt + 0.1, 1.0], [dur, 0.9]]),
    padCut: auto([[0, 1700], [q(19.0), 1800], [q(19.0) + 0.6, 2400], [finalAt, 2400], [finalAt + 0.6, 2100], [dur, 1200]]),
    finalAt,
    bells: [[P.bell ?? finalAt + 0.1, 1.0]],
    stabs: [],
    ticks: null,
    roll: null,
    fadeIn: 0.15,
    fadeOut: [dur - 1.0, dur],
    envelope: false
  }
}

// ------------------------------------------------------------------ instruments

class Tracks {
  constructor(n) {
    this.n = n
    for (const k of ['pad', 'pluck', 'counter', 'sub', 'kick', 'rim', 'snare', 'hats', 'bell', 'stab']) this[k] = stereo(n)
  }
}

const idx = (t) => Math.round(t * SR)

function kick(tr, t, amp) {
  const [L, R] = tr.kick
  const i0 = idx(t)
  const len = Math.round(0.5 * SR)
  const r = rng(i0)
  let ph = 0
  const lp = new Biquad('lowpass', 4000, 0.7)
  for (let j = 0; j < len && i0 + j < tr.n; j++) {
    if (i0 + j < 0) continue
    const tt = j / SR
    const f = 52 + 105 * Math.exp(-tt / 0.028)
    ph += f / SR
    const body = Math.sin(TAU * ph) * Math.exp(-tt / 0.17) * Math.min(1, tt / 0.0015)
    const click = lp.tick(r() * 2 - 1) * Math.exp(-tt / 0.0025) * 0.35
    const v = soft((body + click) * 1.4, 1) * amp
    L[i0 + j] += v; R[i0 + j] += v
  }
}

function rim(tr, t, amp) {
  const [L, R] = tr.rim
  const i0 = idx(t)
  const len = Math.round(0.09 * SR)
  const r = rng(i0 + 7)
  const bp = new Biquad('bandpass', 3200, 1.4)
  const [gl, gr] = pan(-0.12)
  for (let j = 0; j < len && i0 + j < tr.n; j++) {
    const tt = j / SR
    const tone = Math.sin(TAU * 1720 * tt) * Math.exp(-tt / 0.011) * 0.55 + Math.sin(TAU * 830 * tt) * Math.exp(-tt / 0.018) * 0.45
    const v = (tone + bp.tick(r() * 2 - 1) * Math.exp(-tt / 0.007) * 1.4) * amp
    L[i0 + j] += v * gl; R[i0 + j] += v * gr
  }
}

function snare(tr, t, amp, short = false) {
  const [L, R] = tr.snare
  const i0 = idx(t)
  const len = Math.round((short ? 0.12 : 0.32) * SR)
  const r = rng(i0 + 11)
  const bp = new Biquad('bandpass', 1900, 0.8)
  const hp = new Biquad('highpass', 700, 0.7)
  let ph = 0
  for (let j = 0; j < len && i0 + j < tr.n; j++) {
    const tt = j / SR
    ph += (175 + 60 * Math.exp(-tt / 0.012)) / SR
    const body = Math.sin(TAU * ph) * Math.exp(-tt / 0.045) * 0.7
    // Clap-like triple burst on the noise.
    const burst = tt < 0.022 ? 0.55 + 0.45 * Math.cos(TAU * tt / 0.0105) : 1
    const nz = hp.tick(bp.tick(r() * 2 - 1)) * Math.exp(-tt / (short ? 0.03 : 0.11)) * 2.2 * burst
    const v = (body + nz) * amp
    L[i0 + j] += v; R[i0 + j] += v
  }
}

function hat(tr, t, amp, open = false) {
  const [L, R] = tr.hats
  const i0 = idx(t)
  const len = Math.round((open ? 0.3 : 0.08) * SR)
  const r = rng(i0 + 23)
  const hp = new Biquad('highpass', 7200, 0.8)
  const pk = new Biquad('peak', 10500, 1.2, 5)
  const [gl, gr] = pan(0.28)
  for (let j = 0; j < len && i0 + j < tr.n; j++) {
    const tt = j / SR
    const v = pk.tick(hp.tick(r() * 2 - 1)) * Math.exp(-tt / (open ? 0.09 : 0.022)) * Math.min(1, tt / 0.0008) * amp
    L[i0 + j] += v * gl; R[i0 + j] += v * gr
  }
}

/** Sine/triangle pluck with a fast low-pass envelope. */
function pluck(dest, n, t, midi, amp, { p = 0, bright = 0.6, decay = 0.2 } = {}) {
  const [L, R] = dest
  const f = midiToHz(midi)
  const i0 = idx(t)
  const len = Math.round((decay * 6 + 0.02) * SR)
  const svf = new SVF()
  const [gl, gr] = pan(p)
  let ph = 0
  for (let j = 0; j < len && i0 + j < n; j++) {
    if (i0 + j < 0) continue
    const tt = j / SR
    if ((j & 15) === 0) svf.setFreq(900 + 7500 * bright * Math.exp(-tt / 0.09), 0.75)
    ph += f / SR
    ph -= Math.floor(ph)
    const tri = 4 * Math.abs(ph - 0.5) - 1
    const s = Math.sin(TAU * ph) * 0.65 + tri * 0.5 + Math.sin(TAU * 2 * ph) * 0.18 * Math.exp(-tt / 0.04)
    const env = Math.min(1, tt / 0.0025) * Math.exp(-tt / decay)
    const v = svf.tick(s) * env * amp
    L[i0 + j] += v * gl; R[i0 + j] += v * gr
  }
}

/** Glass bell: inharmonic additive partials with staggered decays. */
function bell(tr, t, midi, amp, p = 0) {
  const [L, R] = tr.bell
  const f = midiToHz(midi)
  const parts = [[1, 1, 2.6], [2.76, 0.42, 1.1], [5.4, 0.22, 0.5], [8.93, 0.1, 0.25], [2.0, 0.18, 1.6]]
  const i0 = idx(t)
  const len = Math.round(3.5 * SR)
  const [gl, gr] = pan(p)
  for (let j = 0; j < len && i0 + j < tr.n; j++) {
    const tt = j / SR
    let s = 0
    for (const [ratio, a, d] of parts) s += Math.sin(TAU * f * ratio * tt) * a * Math.exp(-tt / d)
    const v = s * Math.min(1, tt / 0.002) * amp
    L[i0 + j] += v * gl; R[i0 + j] += v * gr
  }
}

/** Bright detuned-saw chord stab. */
function stab(tr, t, chord, amp) {
  const [L, R] = tr.stab
  const notes = PAD[chord].map((m) => m + 12)
  const i0 = idx(t)
  const len = Math.round(0.9 * SR)
  const r = rng(i0 + 3)
  const voices = notes.flatMap((m, k) => [-8, 7].map((c, v) => ({ f: midiToHz(m + c / 100), ph: r(), p: (k / (notes.length - 1)) * 1.2 - 0.6 + (v ? 0.15 : -0.15) })))
  const svfL = new SVF(); const svfR = new SVF()
  for (let j = 0; j < len && i0 + j < tr.n; j++) {
    const tt = j / SR
    if ((j & 15) === 0) { const fc = 1200 + 5200 * Math.exp(-tt / 0.09); svfL.setFreq(fc, 0.8); svfR.setFreq(fc, 0.8) }
    let l = 0; let rr = 0
    for (const v of voices) {
      const dt = v.f / SR
      v.ph += dt; v.ph -= Math.floor(v.ph)
      const s = blepSaw(v.ph, dt)
      const [gl, gr] = pan(v.p)
      l += s * gl; rr += s * gr
    }
    const env = Math.min(1, tt / 0.003) * Math.exp(-tt / 0.22)
    L[i0 + j] += svfL.tick(l) * env * amp / voices.length * 2
    R[i0 + j] += svfR.tick(rr) * env * amp / voices.length * 2
  }
}

/** Detuned saw pad, one segment per chord with overlapping attack/release. */
function renderPad(tr, plan) {
  const [L, R] = tr.pad
  const segs = []
  for (let t = 0; t < plan.dur; ) {
    const c = plan.chordAt(t + 1e-6)
    let t1 = t + 0.01
    while (t1 < plan.dur && plan.chordAt(t1 + 1e-6) === c) t1 = Math.min(plan.dur, t1 + 0.05)
    // Snap the segment end to the grid line it crossed.
    const grid = plan.grid0 + Math.round((t1 - plan.grid0) / BEAT) * BEAT
    t1 = t1 >= plan.dur ? plan.dur : grid
    segs.push({ c, t0: t, t1 })
    t = t1
  }
  const r = rng(77)
  for (const s of segs) {
    const notes = PAD[s.c]
    const voices = notes.flatMap((m, k) => [-9, 0, 8].map((cents, v) => ({ f: midiToHz(m + cents / 100), ph: r(), p: clamp((k - 1.5) * 0.35 + (v - 1) * 0.3, -0.9, 0.9) })))
    const a = 0.18, rel = 0.5
    const i0 = Math.max(0, idx(s.t0 - 0.03))
    const i1 = Math.min(tr.n, idx(s.t1 + rel))
    for (let i = i0; i < i1; i++) {
      const t = i / SR
      const up = clamp((t - (s.t0 - 0.03)) / a, 0, 1)
      const down = t < s.t1 ? 1 : Math.max(0, 1 - (t - s.t1) / rel)
      const env = up * up * (3 - 2 * up) * down * down
      if (env <= 0) continue
      let l = 0; let rr = 0
      for (const v of voices) {
        const dt = v.f / SR
        v.ph += dt; v.ph -= Math.floor(v.ph)
        const smp = blepSaw(v.ph, dt)
        const [gl, gr] = pan(v.p)
        l += smp * gl; rr += smp * gr
      }
      L[i] += l * env / voices.length * 2.2
      R[i] += rr * env / voices.length * 2.2
    }
  }
  sweepLowpass(L, plan.padCut, 0.62)
  sweepLowpass(R, plan.padCut, 0.62)
  for (let i = 0; i < tr.n; i++) { const g = plan.padLevel(i / SR); L[i] *= g; R[i] *= g }
}

/** Sine sub following the bass pattern, softly saturated for small speakers. */
function renderSub(tr, plan, notes) {
  const [L, R] = tr.sub
  let ph = 0
  const gate = new Float32Array(tr.n)
  const freq = new Float32Array(tr.n)
  for (const nt of notes) {
    const i0 = Math.max(0, idx(nt.t)); const i1 = Math.min(tr.n, idx(nt.t + nt.len + nt.rel))
    const f = midiToHz(nt.midi)
    for (let i = i0; i < i1; i++) {
      const tt = (i - idx(nt.t)) / SR
      const env = Math.min(1, tt / 0.008) * (tt < nt.len ? 1 - 0.25 * Math.min(1, tt / Math.max(0.2, nt.len)) : 0.75 * Math.max(0, 1 - (tt - nt.len) / nt.rel)) * nt.amp
      if (env >= gate[i]) { gate[i] = env; freq[i] = f }
    }
  }
  const lp = new Biquad('lowpass', 380, 0.7)
  let f = 73
  for (let i = 0; i < tr.n; i++) {
    if (freq[i]) f += (freq[i] - f) * 0.02 // tiny glide
    ph += f / SR
    const s = soft(Math.sin(TAU * ph) * 2.2, 1) / 1.1 * gate[i]
    const v = lp.tick(s)
    L[i] = v; R[i] = v
  }
}

// ------------------------------------------------------------------ sequencing

function sequence(plan) {
  const n = Math.ceil(plan.dur * SR)
  const tr = new Tracks(n)
  const subNotes = []
  const kicks = []
  const sectionAt = (t) => plan.sections.find((s) => t >= s.start - 1e-6 && t < s.end - 1e-6) || plan.sections[plan.sections.length - 1]
  const firstStep = Math.ceil((0 - plan.grid0) / STEP - 1e-9)
  const lastStep = Math.floor((plan.dur - plan.grid0) / STEP)
  for (let s = firstStep; s <= lastStep; s++) {
    const t = plan.grid0 + s * STEP
    if (t < -1e-9 || t >= plan.dur) continue
    const pos = ((s % 16) + 16) % 16
    const sec = sectionAt(t)
    const S = sec.set
    const chord = plan.chordAt(t + 1e-6)
    if (t >= plan.finalAt - 1e-6) continue // the outro is scored separately below

    if (S.introPluck) {
      const notes = ARP.D
      const u = t / 0.8
      pluck(tr.pluck, n, t, notes[pos % 4] + 12, 0.18 + 0.25 * u, { p: pos % 2 ? 0.3 : -0.3, bright: 0.12 + 0.3 * u, decay: 0.12 })
    }
    if (S.kick && S.kick.includes(pos)) { kick(tr, t, pos === 0 ? 1 : 0.82); kicks.push(t) }
    if (S.rim && S.rim.includes(pos)) rim(tr, t, 0.8)
    if (S.snare && S.snare.includes(pos)) snare(tr, t, 1)
    if (S.hats) {
      if (S.hats === 'eighths' && pos % 2 === 0) hat(tr, t, pos % 4 === 2 ? 0.75 : 0.45)
      if (S.hats === 'thin' && pos % 4 === 2) hat(tr, t, 0.42)
      if (S.hats === 'full') hat(tr, t, pos % 4 === 2 ? 0.85 : pos % 2 === 0 ? 0.55 : 0.28, pos === 14)
    }
    if (S.arp) {
      for (const [st, ni] of ARP_PATTERNS[S.arp]) {
        if (st !== pos) continue
        const accent = pos % 4 === 0 ? 1 : 0.78
        pluck(tr.pluck, n, t, ARP[chord][ni], S.arpLevel * accent, { p: [-0.35, 0.2, -0.15, 0.35][ni], bright: S.arpBright, decay: S.arp === 'bars' ? 0.5 : 0.19 })
      }
    }
    if (S.counter && (pos === 4 || pos === 12)) {
      const m = COUNTER[chord][pos === 4 ? 0 : 1]
      pluck(tr.counter, n, t, m, 0.32, { p: 0.4, bright: 0.45, decay: 0.32 })
    }
    if (S.sub) {
      for (const [st, semi, len] of BASS_PATTERNS[S.sub]) {
        if (st !== pos) continue
        const L = Math.min(len * STEP, S.sub === 'hold' ? BAR : len * STEP)
        subNotes.push({ t, midi: BASS[chord] + semi, len: L * 0.9, rel: 0.06, amp: semi === 0 ? 1 : 0.85 })
      }
    }
  }

  // Riser ticks into the menu bar (film 3.6-4.0): four rising high plucks.
  if (plan.ticks != null) {
    ;[86, 90, 93, 98].forEach((m, i) => pluck(tr.pluck, n, plan.ticks + i * STEP, m, 0.16 + 0.08 * i, { p: -0.4 + 0.27 * i, bright: 0.6, decay: 0.06 }))
  }
  // Snare roll into the drop: 16ths then 32nds, crescendo.
  if (plan.roll) {
    const [a, b] = plan.roll
    const hits = []
    for (let t = a; t < a + (b - a) / 2 - 1e-6; t += STEP) hits.push(t)
    for (let t = a + (b - a) / 2; t < b - 1e-6; t += STEP / 2) hits.push(t)
    hits.forEach((t) => snare(tr, t, 0.22 + 0.6 * ((t - a) / (b - a)) ** 1.5, true))
  }
  // Drop stabs on the card boundaries.
  for (const t of plan.stabs) stab(tr, t, plan.chordAt(t + 1e-6), t === plan.stabs[0] ? 1 : 0.8)

  // Outro: the final D major chord rings out, with a strum and the bell.
  const F = plan.finalAt
  subNotes.push({ t: F, midi: BASS.D, len: Math.max(0.5, plan.dur - F - 1.2), rel: 1.2, amp: 0.9 })
  if (plan.name === 'film') { kick(tr, F, 1); kicks.push(F) }
  ARP.D.concat([78]).forEach((m, i) => pluck(tr.pluck, n, F + 0.4 + i * 0.035, m, 0.42 - i * 0.04, { p: -0.4 + 0.2 * i, bright: 0.55, decay: 0.6 }))
  for (const [t, a] of plan.bells) {
    bell(tr, t, 86, 0.32 * a, -0.15)
    bell(tr, t + 0.09, 93, 0.2 * a, 0.25)
  }

  renderSub(tr, plan, subNotes)
  renderPad(tr, plan)
  return { tr, kicks }
}

// ------------------------------------------------------------------ mixdown

function pumpGain(n, kicks, depth = 0.32) {
  const g = new Float32Array(n).fill(1)
  for (const k of kicks) {
    const i0 = idx(k)
    for (let j = 0; j < Math.round(0.35 * SR) && i0 + j < n; j++) {
      const tt = j / SR
      const d = depth * Math.min(1, tt / 0.006) * Math.exp(-tt / 0.11)
      g[i0 + j] = Math.min(g[i0 + j], 1 - d)
    }
  }
  return g
}

function mixdown(plan, { tr, kicks }) {
  const n = tr.n
  const gains = { pad: 0.2, pluck: 0.4, counter: 0.34, sub: 0.17, kick: 0.42, rim: 0.24, snare: 0.34, hats: 0.2, bell: 0.34, stab: 0.26 }
  const pump = pumpGain(n, kicks)
  const [L, R] = stereo(n)
  const send = stereo(n)
  const sends = { pad: 0.16, pluck: 0.22, counter: 0.3, bell: 0.55, stab: 0.35, snare: 0.2, rim: 0.1 }
  for (const [k, g] of Object.entries(gains)) {
    const [a, b] = tr[k]
    const pumped = k === 'pad' || k === 'sub'
    for (let i = 0; i < n; i++) {
      const pg = pumped ? pump[i] : 1
      const l = a[i] * g * pg; const r = b[i] * g * pg
      L[i] += l; R[i] += r
      if (sends[k]) { send[0][i] += l * sends[k]; send[1][i] += r * sends[k] }
    }
  }
  // 3/16 ping-pong on the plucks.
  const plk = [new Float32Array(n), new Float32Array(n)]
  for (let i = 0; i < n; i++) { plk[0][i] = (tr.pluck[0][i] + tr.counter[0][i]) * gains.pluck; plk[1][i] = (tr.pluck[1][i] + tr.counter[1][i]) * gains.pluck }
  const [dl, dr] = pingPong(plk, { time: 3 * STEP, feedback: 0.34, tone: 4800 })
  const [wl, wr] = fdnReverb(send, { decay: 2.4, damp: 6200, predelay: 0.025, hp: 260, width: 1 })
  for (let i = 0; i < n; i++) {
    L[i] += dl[i] * 0.24 + wl[i] * 0.42
    R[i] += dr[i] * 0.24 + wr[i] * 0.42
  }
  const hp = [new Biquad('highpass', 28, 0.7), new Biquad('highpass', 28, 0.7)]
  hp[0].run(L); hp[1].run(R)
  widen([L, R], 1.15, 180)
  // Fades.
  for (let i = 0; i < n; i++) {
    const t = i / SR
    let g = 1
    if (plan.fadeIn > 0 && t < plan.fadeIn) g *= Math.sin((t / plan.fadeIn) * Math.PI / 2)
    const [f0, f1] = plan.fadeOut
    if (t >= f0) g *= Math.cos(clamp((t - f0) / (f1 - f0), 0, 1) * Math.PI / 2)
    L[i] *= g; R[i] *= g
  }
  // Loudness: normalise to the bed target, keep a hard ceiling.
  const gain = dbToGain(TARGET_LUFS - lufs([L, R]))
  for (let i = 0; i < n; i++) { L[i] *= gain; R[i] *= gain }
  const gr = limit([L, R], { ceilingDb: CEILING_DB, lookahead: 0.004, release: 0.15 })
  return { mix: [L, R], gr }
}

/** Kick + bass level (0..0.9) per 1/fps for the stage's cold-open bars. */
function envelope(tr, plan, fps = 60) {
  const frames = Math.ceil(plan.dur * fps)
  const per = SR / fps
  const raw = new Float32Array(frames)
  for (let f = 0; f < frames; f++) {
    let p = 0
    for (let i = Math.floor(f * per); i < Math.min(tr.n, Math.floor((f + 1) * per)); i++) {
      const v = Math.abs(tr.kick[0][i]) * 0.9 + Math.abs(tr.sub[0][i]) * 0.5 + Math.abs(tr.pad[0][i]) * 0.6
      p = Math.max(p, v)
    }
    raw[f] = p
  }
  const smooth = new Float32Array(frames)
  let s = 0
  const rel = Math.exp(-1 / (0.1 * fps))
  for (let f = 0; f < frames; f++) { s = raw[f] > s ? raw[f] : raw[f] + (s - raw[f]) * rel; smooth[f] = s }
  let ref = 1e-9
  for (let f = 0; f < Math.min(frames, 4 * fps); f++) ref = Math.max(ref, smooth[f])
  return Array.from(smooth, (v) => Math.round(clamp(0.08 + 0.82 * (v / ref) ** 0.8, 0, 0.9) * 1000) / 1000)
}

function build(plan) {
  const t0 = Date.now()
  const seq = sequence(plan)
  const { mix, gr } = mixdown(plan, seq)
  const file = join(OUT, `music-${plan.name}.wav`)
  writeWav(file, mix, { bits: 24 })
  const L = lufs(mix)
  console.log(`music-${plan.name}.wav  ${plan.dur.toFixed(1)} s  ${L.toFixed(1)} LUFS  peak ${peakDb(mix).toFixed(1)} dBFS  limiter ${gr.toFixed(1)} dB  (${((Date.now() - t0) / 1000).toFixed(1)} s)`)
  if (plan.envelope) {
    const levels = envelope(seq.tr, plan)
    writeFileSync(join(OUT, 'music.envelope.json'), JSON.stringify({ generated_by: 'video/music.mjs', fps: 60, levels }))
    console.log(`music.envelope.json  ${levels.length} frames`)
  }
}

mkdirSync(OUT, { recursive: true })
const only = process.argv.includes('--only') ? process.argv[process.argv.indexOf('--only') + 1] : null
if (!only || only === 'film') build(filmPlan())
if (!only || only === 'preview') build(previewPlan())
