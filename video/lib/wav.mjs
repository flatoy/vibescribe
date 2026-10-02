// WAV I/O. Decoding goes through ffmpeg (robust to streaming headers); encoding is
// done here so every writer produces identical, sample-accurate PCM.
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

export const SR = 48000

/** Decodes any audio file to Float32 channels at `rate` (default 48 kHz). */
export function decode(path, { channels = 1, rate = SR, filter } = {}) {
  const args = ['-hide_banner', '-loglevel', 'error', '-i', path]
  if (filter) args.push('-af', filter)
  args.push('-f', 'f32le', '-ac', String(channels), '-ar', String(rate), 'pipe:1')
  const pcm = execFileSync('ffmpeg', args, { maxBuffer: 1 << 30 })
  const interleaved = new Float32Array(pcm.buffer.slice(pcm.byteOffset, pcm.byteOffset + pcm.byteLength))
  if (channels === 1) return [interleaved]
  const frames = interleaved.length / channels
  const out = Array.from({ length: channels }, () => new Float32Array(frames))
  for (let i = 0; i < frames; i++) for (let c = 0; c < channels; c++) out[c][i] = interleaved[i * channels + c]
  return out
}

/**
 * Writes Float32 channels as PCM WAV. bits: 16 (TPDF-dithered), 24, or 32 (float).
 * Samples are hard-limited to [-1, 1] only as a last resort; callers keep headroom.
 */
export function writeWav(path, channels, { rate = SR, bits = 24 } = {}) {
  const chans = Array.isArray(channels) ? channels : [channels]
  const n = chans[0].length
  const nc = chans.length
  const bytes = bits / 8
  const dataSize = n * nc * bytes
  const buf = Buffer.alloc(44 + dataSize)
  const float = bits === 32
  buf.write('RIFF', 0)
  buf.writeUInt32LE(36 + dataSize, 4)
  buf.write('WAVE', 8)
  buf.write('fmt ', 12)
  buf.writeUInt32LE(16, 16)
  buf.writeUInt16LE(float ? 3 : 1, 20)
  buf.writeUInt16LE(nc, 22)
  buf.writeUInt32LE(rate, 24)
  buf.writeUInt32LE(rate * nc * bytes, 28)
  buf.writeUInt16LE(nc * bytes, 32)
  buf.writeUInt16LE(bits, 34)
  buf.write('data', 36)
  buf.writeUInt32LE(dataSize, 40)
  let seed = 0x9e3779b9
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296)
  let o = 44
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < nc; c++) {
      let v = chans[c][i]
      if (!(v === v)) v = 0
      if (float) { buf.writeFloatLE(v, o); o += 4; continue }
      v = Math.max(-1, Math.min(1, v))
      if (bits === 16) {
        const s = Math.round(v * 32767 + (rand() - rand()))
        buf.writeInt16LE(Math.max(-32768, Math.min(32767, s)), o)
        o += 2
      } else {
        const s = Math.max(-8388608, Math.min(8388607, Math.round(v * 8388607)))
        buf.writeIntLE(s, o, 3)
        o += 3
      }
    }
  }
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, buf)
}
