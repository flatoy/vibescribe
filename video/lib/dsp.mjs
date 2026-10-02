// Small, dependency-free DSP toolkit shared by voice.mjs, music.mjs, sfx.mjs and mix.mjs.
// Everything is offline and sample-accurate at 48 kHz; randomness is always seeded.
import { SR } from './wav.mjs'

export { SR }
export const TAU = Math.PI * 2
export const dbToGain = (db) => 10 ** (db / 20)
export const gainToDb = (g) => 20 * Math.log10(Math.max(g, 1e-12))
export const midiToHz = (m) => 440 * 2 ** ((m - 69) / 12)
export const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))

/** mulberry32: tiny seeded PRNG returning [0, 1). */
export function rng(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

export const stereo = (n) => [new Float32Array(n), new Float32Array(n)]

// ---------------------------------------------------------------- filters

/** RBJ biquad. type: lowpass, highpass, bandpass, peak, lowshelf, highshelf, notch. */
export class Biquad {
  constructor(type, freq, q = 0.7071, gainDb = 0) {
    this.x1 = this.x2 = this.y1 = this.y2 = 0
    this.set(type, freq, q, gainDb)
  }

  set(type, freq, q = 0.7071, gainDb = 0) {
    const w = TAU * clamp(freq, 5, SR * 0.49) / SR
    const cos = Math.cos(w)
    const sin = Math.sin(w)
    const alpha = sin / (2 * q)
    const A = 10 ** (gainDb / 40)
    let b0, b1, b2, a0, a1, a2
    switch (type) {
      case 'lowpass': b0 = (1 - cos) / 2; b1 = 1 - cos; b2 = b0; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; break
      case 'highpass': b0 = (1 + cos) / 2; b1 = -(1 + cos); b2 = b0; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; break
      case 'bandpass': b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; break
      case 'notch': b0 = 1; b1 = -2 * cos; b2 = 1; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; break
      case 'peak': b0 = 1 + alpha * A; b1 = -2 * cos; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cos; a2 = 1 - alpha / A; break
      case 'lowshelf': {
        const s = 2 * Math.sqrt(A) * alpha
        b0 = A * ((A + 1) - (A - 1) * cos + s); b1 = 2 * A * ((A - 1) - (A + 1) * cos); b2 = A * ((A + 1) - (A - 1) * cos - s)
        a0 = (A + 1) + (A - 1) * cos + s; a1 = -2 * ((A - 1) + (A + 1) * cos); a2 = (A + 1) + (A - 1) * cos - s
        break
      }
      case 'highshelf': {
        const s = 2 * Math.sqrt(A) * alpha
        b0 = A * ((A + 1) + (A - 1) * cos + s); b1 = -2 * A * ((A - 1) + (A + 1) * cos); b2 = A * ((A + 1) + (A - 1) * cos - s)
        a0 = (A + 1) - (A - 1) * cos + s; a1 = 2 * ((A - 1) - (A + 1) * cos); a2 = (A + 1) - (A - 1) * cos - s
        break
      }
      default: throw new Error(`unknown biquad ${type}`)
    }
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0; this.a1 = a1 / a0; this.a2 = a2 / a0
    return this
  }

  tick(x) {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2
    this.x2 = this.x1; this.x1 = x; this.y2 = this.y1; this.y1 = y
    return y
  }

  run(buf) { for (let i = 0; i < buf.length; i++) buf[i] = this.tick(buf[i]); return buf }
}

/** Applies a chain of biquad specs ([type, f, q, gain]) in place to each channel. */
export function eq(channels, specs) {
  for (const ch of channels) for (const s of specs) new Biquad(...s).run(ch)
  return channels
}

/**
 * Topology-preserving state-variable filter (Simper). Stable under fast cutoff
 * modulation, which is what the pad sweeps and pluck envelopes need.
 */
export class SVF {
  constructor() { this.ic1 = 0; this.ic2 = 0; this.setFreq(1000, 0.7071) }
  setFreq(freq, q = 0.7071) {
    const g = Math.tan(Math.PI * clamp(freq, 10, SR * 0.45) / SR)
    const k = 1 / q
    this.a1 = 1 / (1 + g * (g + k)); this.a2 = g * this.a1; this.a3 = g * this.a2; this.k = k
  }
  /** Returns lowpass; highpass/bandpass available on this.hp / this.bp after the call. */
  tick(v0) {
    const v3 = v0 - this.ic2
    const v1 = this.a1 * this.ic1 + this.a2 * v3
    const v2 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3
    this.ic1 = 2 * v1 - this.ic1
    this.ic2 = 2 * v2 - this.ic2
    this.bp = v1
    this.hp = v0 - this.k * v1 - v2
    return v2
  }
}

/** Runs a 24 dB/oct low-pass whose cutoff follows cutoffAt(t) (updated every 32 samples). */
export function sweepLowpass(buf, cutoffAt, q = 0.6, start = 0) {
  const a = new SVF(); const b = new SVF()
  for (let i = 0; i < buf.length; i++) {
    if ((i & 31) === 0) { const f = cutoffAt((start + i) / SR); a.setFreq(f, q); b.setFreq(f, 0.5412) }
    buf[i] = b.tick(a.tick(buf[i]))
  }
  return buf
}

// ---------------------------------------------------------------- oscillators

/** PolyBLEP residual for band-limited discontinuities. */
export function polyBlep(t, dt) {
  if (t < dt) { t /= dt; return t + t - t * t - 1 }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1 }
  return 0
}

/** Band-limited saw sample at phase p (0..1) with increment dt. */
export const blepSaw = (p, dt) => 2 * p - 1 - polyBlep(p, dt)

/** Soft saturation with unity small-signal gain. */
export const soft = (x, drive = 1) => Math.tanh(x * drive) / drive

// ---------------------------------------------------------------- envelopes

/** Linear-attack, exponential-ish ADSR evaluated at time t for a note of length len. */
export function adsr(t, len, a, d, s, r) {
  if (t < 0) return 0
  let v
  if (t < a) v = t / a
  else if (t < a + d) v = 1 - (1 - s) * ((t - a) / d)
  else v = s
  if (t > len) {
    const rel = (t - len) / r
    if (rel >= 1) return 0
    const atRelease = len < a ? len / a : len < a + d ? 1 - (1 - s) * ((len - a) / d) : s
    return atRelease * (1 - rel) * (1 - rel)
  }
  return v
}

/** Equal-power pan gains for p in [-1, 1]. */
export function pan(p) {
  const a = (clamp(p, -1, 1) + 1) * Math.PI / 4
  return [Math.cos(a), Math.sin(a)]
}

// ---------------------------------------------------------------- effects

/** Stereo ping-pong feedback delay with a low-passed, slightly saturated loop. Returns the wet signal. */
export function pingPong([inL, inR], { time = 0.3, feedback = 0.35, tone = 3200, mix = 1 } = {}) {
  const n = inL.length
  const d = Math.round(time * SR)
  const bufL = new Float32Array(d); const bufR = new Float32Array(d)
  const lpL = new Biquad('lowpass', tone, 0.6); const lpR = new Biquad('lowpass', tone, 0.6)
  const hpL = new Biquad('highpass', 180, 0.6); const hpR = new Biquad('highpass', 180, 0.6)
  const [outL, outR] = stereo(n)
  let w = 0
  for (let i = 0; i < n; i++) {
    const dl = bufL[w]; const dr = bufR[w]
    outL[i] = dl * mix; outR[i] = dr * mix
    const mono = (inL[i] + inR[i]) * 0.5
    bufL[w] = hpL.tick(lpL.tick(mono + soft(dr * feedback, 1.2)))
    bufR[w] = hpR.tick(lpR.tick(soft(dl * feedback, 1.2)))
    w = (w + 1) % d
  }
  return [outL, outR]
}

/**
 * 8-line feedback delay network reverb (Hadamard mixing, per-line damping,
 * gentle delay modulation for a smooth, non-metallic tail). Returns the wet signal.
 */
export function fdnReverb([inL, inR], { decay = 2.0, damp = 5500, predelay = 0.02, size = 1, tail = 0, hp = 200, width = 1 } = {}) {
  const base = [1433, 1601, 1867, 2053, 2251, 2399, 2687, 2903].map((l) => Math.round(l * size))
  const n = inL.length + Math.round(tail * SR)
  const lines = base.map((l) => ({ buf: new Float32Array(l + 64), len: l, w: 0, lp: 0 }))
  const gains = base.map((l) => 10 ** ((-3 * l / SR) / decay))
  const dampCoef = Math.exp(-TAU * damp / SR)
  const pre = Math.max(1, Math.round(predelay * SR))
  const preL = new Float32Array(pre); const preR = new Float32Array(pre)
  const hpL = new Biquad('highpass', hp, 0.7); const hpR = new Biquad('highpass', hp, 0.7)
  const [outL, outR] = stereo(n)
  const x = new Float64Array(8)
  const lfo = base.map((_, k) => ({ rate: 0.13 + 0.07 * k, depth: 6 + k, ph: k * 0.7 }))
  let pw = 0
  for (let i = 0; i < n; i++) {
    const il = i < inL.length ? inL[i] : 0
    const ir = i < inR.length ? inR[i] : 0
    const sl = hpL.tick(preL[pw]); const sr = hpR.tick(preR[pw])
    preL[pw] = il; preR[pw] = ir; pw = (pw + 1) % pre
    for (let k = 0; k < 8; k++) {
      const L = lines[k]
      const mod = lfo[k].depth * Math.sin(TAU * lfo[k].rate * i / SR + lfo[k].ph)
      let pos = L.w - L.len - mod
      while (pos < 0) pos += L.buf.length
      const i0 = Math.floor(pos); const fr = pos - i0
      const a = L.buf[i0 % L.buf.length]; const b = L.buf[(i0 + 1) % L.buf.length]
      const v = a + (b - a) * fr
      L.lp = v * (1 - dampCoef) + L.lp * dampCoef
      x[k] = L.lp * gains[k]
    }
    // Fast Walsh-Hadamard transform (normalized) mixes the lines losslessly.
    for (let h = 1; h < 8; h <<= 1) {
      for (let j = 0; j < 8; j += h << 1) {
        for (let m = j; m < j + h; m++) { const a = x[m]; const b = x[m + h]; x[m] = a + b; x[m + h] = a - b }
      }
    }
    const norm = 1 / Math.sqrt(8)
    for (let k = 0; k < 8; k++) {
      const L = lines[k]
      const input = k % 2 === 0 ? sl : sr
      L.buf[L.w] = x[k] * norm + input * 0.35
      L.w = (L.w + 1) % L.buf.length
    }
    const l = (lines[0].lp - lines[2].lp + lines[4].lp - lines[6].lp) * 0.5
    const r = (lines[1].lp - lines[3].lp + lines[5].lp - lines[7].lp) * 0.5
    const mid = (l + r) * 0.5; const side = (l - r) * 0.5 * width
    outL[i] = mid + side; outR[i] = mid - side
  }
  return [outL, outR]
}

/** Mid/side width: widens the side channel above `lowCut` (keeps the low end mono). */
export function widen([L, R], amount = 1.3, lowCut = 160) {
  const hp = new Biquad('highpass', lowCut, 0.7)
  for (let i = 0; i < L.length; i++) {
    const m = (L[i] + R[i]) * 0.5
    const s = hp.tick((L[i] - R[i]) * 0.5) * amount
    L[i] = m + s; R[i] = m - s
  }
  return [L, R]
}

/**
 * Feed-forward lookahead peak limiter. The gain curve is the forward-looking minimum
 * of the needed gain, box-smoothed over the lookahead (so it is already down when the
 * peak arrives), with a one-pole release. Returns the maximum gain reduction in dB.
 */
export function limit(channels, { ceilingDb = -1, lookahead = 0.005, release = 0.12 } = {}) {
  const ceil = dbToGain(ceilingDb)
  const n = channels[0].length
  const la = Math.max(1, Math.round(lookahead * SR))
  const need = new Float32Array(n)
  for (let i = 0; i < n; i++) {
    let p = 0
    for (const ch of channels) p = Math.max(p, Math.abs(ch[i]))
    need[i] = p > ceil ? ceil / p : 1
  }
  const ahead = new Float32Array(n)
  const dq = new Int32Array(n)
  let head = 0; let tailIdx = 0
  for (let i = n - 1; i >= 0; i--) {
    while (tailIdx > head && need[dq[tailIdx - 1]] >= need[i]) tailIdx--
    dq[tailIdx++] = i
    while (dq[head] > i + la) head++
    ahead[i] = need[dq[head]]
  }
  const rel = Math.exp(-1 / (release * SR))
  let box = la; let g = 1; let reduction = 0
  for (let i = 0; i < n; i++) {
    box += ahead[i] - (i >= la ? ahead[i - la] : 1)
    const smooth = Math.min(1, box / la)
    g = smooth < g ? smooth : smooth + (g - smooth) * rel
    for (const ch of channels) ch[i] *= g
    if (g < 1) reduction = Math.max(reduction, -gainToDb(g))
  }
  for (const ch of channels) for (let i = 0; i < n; i++) if (Math.abs(ch[i]) > ceil) ch[i] = Math.sign(ch[i]) * ceil
  return reduction
}

// ---------------------------------------------------------------- analysis

export function peakDb(channels) {
  let p = 0
  for (const ch of channels) for (let i = 0; i < ch.length; i++) p = Math.max(p, Math.abs(ch[i]))
  return gainToDb(p)
}

export function rmsDb(ch, from = 0, to = ch.length) {
  let s = 0
  for (let i = from; i < to; i++) s += ch[i] * ch[i]
  return gainToDb(Math.sqrt(s / Math.max(1, to - from)))
}

/** K-weighted mean-square of each channel summed (BS.1770), per 100 ms hop of 400 ms blocks. */
function kBlocks(channels) {
  const n = channels[0].length
  const hop = SR / 10
  const sums = []
  const filtered = channels.map((ch) => {
    const s1 = new Biquad('lowpass', 1000); s1.b0 = 1.53512485958697; s1.b1 = -2.69169618940638; s1.b2 = 1.19839281085285; s1.a1 = -1.69065929318241; s1.a2 = 0.73248077421585
    const s2 = new Biquad('lowpass', 1000); s2.b0 = 1; s2.b1 = -2; s2.b2 = 1; s2.a1 = -1.99004745483398; s2.a2 = 0.99007225036621
    const out = new Float64Array(n)
    for (let i = 0; i < n; i++) { const y = s2.tick(s1.tick(ch[i])); out[i] = y * y }
    return out
  })
  const hops = Math.floor(n / hop)
  const hopSum = new Float64Array(hops)
  for (let h = 0; h < hops; h++) {
    let s = 0
    for (const f of filtered) for (let i = h * hop; i < (h + 1) * hop; i++) s += f[i]
    hopSum[h] = s / hop
  }
  for (let h = 0; h + 4 <= hops; h++) sums.push((hopSum[h] + hopSum[h + 1] + hopSum[h + 2] + hopSum[h + 3]) / 4)
  return sums
}

/** Integrated loudness (LUFS) per ITU-R BS.1770-4 with absolute and relative gating. */
export function lufs(channels) {
  const blocks = kBlocks(channels)
  const toL = (ms) => -0.691 + 10 * Math.log10(Math.max(ms, 1e-20))
  const abs = blocks.filter((b) => toL(b) > -70)
  if (!abs.length) return -Infinity
  const mean = abs.reduce((a, b) => a + b, 0) / abs.length
  const rel = abs.filter((b) => toL(b) > toL(mean) - 10)
  return toL(rel.reduce((a, b) => a + b, 0) / rel.length)
}

/** Momentary loudness (400 ms) per 100 ms hop, in LUFS. */
export function momentary(channels) {
  return kBlocks(channels).map((b) => -0.691 + 10 * Math.log10(Math.max(b, 1e-20)))
}

/**
 * The app's level meter (Sources/VibeScribeCore/RecordingSession.swift LevelMeter):
 * per 1024-sample buffer, target = clamp((20 log10(rms) + 50) / 40, 0, 1);
 * level += (target - level) * (target > level ? 0.6 : 0.15). Sampled at `fps`.
 */
export function appMeter(samples, { fps = 60, tail = 0.6, gainDb = 0, window = 1024 } = {}) {
  const g = dbToGain(gainDb)
  const total = samples.length + Math.round(tail * SR)
  const windows = Math.ceil(total / window)
  const after = new Float32Array(windows)
  let level = 0
  for (let w = 0; w < windows; w++) {
    let s = 0
    for (let i = w * window; i < (w + 1) * window; i++) { const v = i < samples.length ? samples[i] * g : 0; s += v * v }
    const rms = Math.sqrt(s / window)
    const target = rms > 0 ? clamp((20 * Math.log10(rms) + 50) / 40, 0, 1) : 0
    level += (target - level) * (target > level ? 0.6 : 0.15)
    after[w] = level
  }
  const frames = Math.ceil(total / SR * fps)
  const levels = []
  for (let f = 0; f < frames; f++) {
    const done = Math.floor((f / fps) * SR / window) - 1
    levels.push(done < 0 ? 0 : Math.round(after[Math.min(done, windows - 1)] * 1000) / 1000)
  }
  return levels
}
