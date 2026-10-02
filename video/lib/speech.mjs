// Speech helpers for voice.mjs: transcription checks, word matching and simple
// voice measurements (pitch, rate) used to audition and match voices.
import { readFileSync } from 'node:fs'
import { secret } from './secrets.mjs'
import { SR } from './wav.mjs'

const CARTESIA_VERSION = '2026-08-14'
let openaiUnavailable = null

async function openaiTranscribe(file, language, model) {
  const key = secret('OPENAI_API_KEY')
  const form = new FormData()
  form.append('file', new Blob([readFileSync(file)], { type: 'audio/wav' }), 'clip.wav')
  form.append('model', model)
  form.append('language', language)
  form.append('temperature', '0')
  const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST', headers: { Authorization: `Bearer ${key}` }, body: form
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) {
    const error = new Error(`OpenAI ${model} ${response.status}: ${body.error?.code ?? body.error?.message ?? 'error'}`)
    error.status = response.status
    throw error
  }
  return body.text
}

async function cartesiaTranscribe(file, language) {
  const key = secret('CARTESIA_API_KEY')
  const form = new FormData()
  form.append('file', new Blob([readFileSync(file)], { type: 'audio/wav' }), 'clip.wav')
  form.append('model', 'ink-whisper')
  form.append('language', language)
  const response = await fetch('https://api.cartesia.ai/stt', {
    method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Cartesia-Version': CARTESIA_VERSION }, body: form
  })
  if (!response.ok) throw new Error(`Cartesia STT ${response.status}: ${(await response.text()).slice(0, 200)}`)
  return (await response.json()).text
}

/**
 * Transcribes a clip for verification. Prefers OpenAI (gpt-4o-transcribe, then whisper-1);
 * if the OpenAI key is rejected (401/403), falls back to Cartesia ink-whisper for the run.
 */
export async function transcribe(file, language) {
  if (!openaiUnavailable) {
    for (const model of ['gpt-4o-transcribe', 'whisper-1']) {
      try {
        return { engine: `openai ${model}`, text: (await openaiTranscribe(file, language, model)).trim() }
      } catch (error) {
        if (error.status === 401 || error.status === 403 || /not set/.test(error.message)) {
          openaiUnavailable = error.message
          console.warn(`  OpenAI transcription unavailable (${error.message}); using Cartesia ink-whisper`)
          break
        }
        if (model === 'whisper-1') throw error
      }
    }
  }
  return { engine: 'cartesia ink-whisper', text: (await cartesiaTranscribe(file, language)).trim() }
}

export function words(text) {
  return text.toLowerCase().normalize('NFC')
    .replace(/[-‐‑–—/]/g, ' ')
    .replace(/[’']/g, '')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .split(/\s+/).filter(Boolean)
}

/**
 * Compares heard vs intended words. Passes on an exact word match, on a match after
 * removing spaces ("back off" = "backoff", "wifi" = "wi fi"), or when every substitution
 * is an accepted spelling variant listed in voices.json (e.g. names).
 */
export function compareWords(intended, heard, accept = {}) {
  const a = words(intended)
  const b = words(heard)
  if (a.join(' ') === b.join(' ')) return { pass: true, wer: 0, diffs: [] }
  if (a.join('') === b.join('')) return { pass: true, wer: 0, diffs: [], note: 'matches after joining compounds' }
  // Token Levenshtein with backtrace.
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)])
  for (let j = 1; j <= b.length; j++) d[0][j] = j
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1))
    }
  }
  const diffs = []
  let i = a.length; let j = b.length
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && d[i][j] === d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)) {
      if (a[i - 1] !== b[j - 1]) diffs.unshift({ want: a[i - 1], got: b[j - 1] })
      i--; j--
    } else if (i > 0 && d[i][j] === d[i - 1][j] + 1) { diffs.unshift({ want: a[i - 1], got: null }); i-- } else { diffs.unshift({ want: null, got: b[j - 1] }); j-- }
  }
  const accepted = (x) => x.want && x.got && (accept[x.want] ?? []).map((v) => v.toLowerCase()).includes(x.got)
  const real = diffs.filter((x) => !accepted(x))
  return { pass: real.length === 0, wer: Math.round((real.length / a.length) * 1000) / 1000, diffs }
}

/** Downsamples by an integer factor after a simple windowed-sinc low-pass. */
function decimate(samples, factor) {
  const taps = 63
  const fc = 0.45 / factor
  const h = new Float32Array(taps)
  let sum = 0
  for (let k = 0; k < taps; k++) {
    const m = k - (taps - 1) / 2
    const sinc = m === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * m) / (Math.PI * m)
    h[k] = sinc * (0.54 - 0.46 * Math.cos(2 * Math.PI * k / (taps - 1)))
    sum += h[k]
  }
  const out = new Float32Array(Math.floor(samples.length / factor))
  for (let o = 0; o < out.length; o++) {
    let acc = 0
    const c = o * factor
    for (let k = 0; k < taps; k++) { const idx = c + k - 31; if (idx >= 0 && idx < samples.length) acc += samples[idx] * h[k] }
    out[o] = acc / sum
  }
  return out
}

/**
 * Voice measurements: YIN pitch on voiced frames (median F0, spread in semitones),
 * speech-active time and words per second of speech.
 */
export function measureVoice(samples, wordCount) {
  const rate = 16000
  const x = decimate(samples, SR / rate)
  const win = 640; const hop = 160; const tauMin = Math.floor(rate / 400); const tauMax = Math.floor(rate / 70)
  const f0 = []
  let active = 0
  const d = new Float32Array(tauMax + 1)
  for (let start = 0; start + win + tauMax < x.length; start += hop) {
    let e = 0
    for (let i = 0; i < win; i++) e += x[start + i] ** 2
    const db = 10 * Math.log10(e / win + 1e-12)
    if (db < -40) continue
    active++
    d[0] = 1
    let running = 0
    for (let tau = 1; tau <= tauMax; tau++) {
      let s = 0
      for (let i = 0; i < win; i++) { const v = x[start + i] - x[start + i + tau]; s += v * v }
      running += s
      d[tau] = running > 0 ? (s * tau) / running : 1
    }
    let tau = -1
    for (let t = tauMin; t <= tauMax; t++) {
      if (d[t] < 0.15) { while (t + 1 <= tauMax && d[t + 1] < d[t]) t++; tau = t; break }
    }
    if (tau > 0) {
      const a = d[tau - 1]; const b = d[tau]; const c = d[Math.min(tau + 1, tauMax)]
      const shift = (a - c) / (2 * (a - 2 * b + c) || 1)
      f0.push(rate / (tau + shift))
    }
  }
  f0.sort((p, q) => p - q)
  const q = (p) => f0[Math.min(f0.length - 1, Math.floor(p * f0.length))]
  const median = f0.length ? q(0.5) : 0
  const spread = f0.length ? 12 * Math.log2(q(0.9) / q(0.1)) : 0
  const speechSeconds = (active * hop) / rate
  return {
    f0MedianHz: Math.round(median),
    f0Spread10to90St: Math.round(spread * 10) / 10,
    voicedFraction: Math.round((f0.length / Math.max(1, active)) * 100) / 100,
    speechSeconds: Math.round(speechSeconds * 100) / 100,
    wordsPerSpeechSecond: Math.round((wordCount / Math.max(0.1, speechSeconds)) * 100) / 100
  }
}
