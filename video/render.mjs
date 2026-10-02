#!/usr/bin/env node
// Renders the stage (stage/index.html) frame by frame with Playwright Chromium and encodes the
// launch film and the App Preview cut.
//
//   node render.mjs                 render missing frames (film + preview), then encode everything
//   node render.mjs --only film     film only (also: --only preview)
//   node render.mjs --frames-only   render frames, skip encoding
//   node render.mjs --encode-only   encode from existing frames and the mix
//   node render.mjs --force         re-render every frame (frames are otherwise resumed)
//   node render.mjs --workers 8     parallel browser pages (default: CPU count - 2)
//   node render.mjs --ss 4          supersampling factor (default 4; 1 renders straight at 1080p)
//   node render.mjs --stills [film:2.0,preview:8.27,...]   key-frame PNGs into build/stills/
//   node render.mjs --serve         serve the stage at http://localhost:8765/stage/?t=12.3
//
// The viewport is 1440x810 CSS px at deviceScaleFactor 4/3, i.e. 1920x1080 device pixels. Time is
// the only input: frame i of the film is t = i/60, frame i of the preview is t = i/30. Camera
// moves get real motion blur: the stage reports how many sub-frames a 180-degree shutter needs and
// the renderer averages them.
//
// Each frame is drawn at --ss times that resolution and scaled down. Chromium snaps text and
// boxes to whole device pixels, so at 1080p a slow zoom moves elements in visible 1 px steps,
// each on its own beat; at 4x the steps are a quarter pixel and average out.
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'

const ROOT = path.dirname(fileURLToPath(import.meta.url))
const BUILD = path.join(ROOT, 'build')
const OUT = path.join(ROOT, 'out')
const FONT_DIR = '/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts'
const W = 1440, H = 810, DPR = 4 / 3

const argv = process.argv.slice(2)
const flag = (n) => argv.includes(n)
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : d }
const SS = Number(opt('--ss', 4))

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg', '.otf': 'font/otf', '.svg': 'image/svg+xml', '.wav': 'audio/wav' }

function serve(port = 0) {
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    let file
    if (url.startsWith('/fonts/')) {
      // System SF Mono, read in place from Terminal.app (never copied into the repo).
      const name = path.basename(url)
      if (!/^SF-Mono-[A-Za-z]+\.otf$/.test(name)) return res.writeHead(404).end()
      file = path.join(FONT_DIR, name)
    } else {
      file = path.join(ROOT, url.endsWith('/') ? url + 'index.html' : url)
      if (!file.startsWith(ROOT) || /\/(\.env|node_modules)/.test(file)) return res.writeHead(403).end()
    }
    fs.readFile(file, (err, buf) => {
      if (err) return res.writeHead(404).end()
      res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' })
      res.end(buf)
    })
  })
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server)))
}

async function openStage(browser, base) {
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: DPR * SS })
  const page = await ctx.newPage()
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e)))
  // 404s are reported as console errors; optional assets (the music envelope) may be missing,
  // so they are logged by URL instead of failing the render.
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()) })
  page.on('response', (r) => { if (r.status() >= 400 && !/favicon|music\.envelope/.test(r.url())) console.warn(`warn: ${r.status()} ${r.url()}`) })
  await page.goto(`${base}/stage/index.html`)
  const t0 = Date.now()
  for (;;) {
    const st = await page.evaluate(() => ({ ready: !!(window.__stage && window.__stage.ready), error: window.__stage && window.__stage.error }))
    if (st.error) throw new Error(`stage init failed:\n${st.error}`)
    if (st.ready) break
    if (errors.length) throw new Error(`stage errors:\n${errors.join('\n')}`)
    if (Date.now() - t0 > 60000) throw new Error('stage never became ready')
    await new Promise((r) => setTimeout(r, 100))
  }
  const cdp = await ctx.newCDPSession(page)
  const st = { ctx, page, cdp, errors }
  const [w, h] = imageSize(Buffer.from(await capture(st, 'png'), 'base64'))
  if (w !== OUT_W * SS || h !== OUT_H * SS) throw new Error(`capture is ${w}x${h}, expected ${OUT_W * SS}x${OUT_H * SS}`)
  return st
}

const OUT_W = Math.round(W * DPR), OUT_H = Math.round(H * DPR)

// Width and height of a PNG (IHDR) or baseline/progressive JPEG (SOF0-SOF2).
function imageSize(buf) {
  if (buf.readUInt32BE(0) === 0x89504e47) return [buf.readUInt32BE(16), buf.readUInt32BE(20)]
  for (let i = 2; i + 9 < buf.length;) {
    if (buf[i] !== 0xff) { i++; continue }
    const m = buf[i + 1]
    if (m >= 0xc0 && m <= 0xc2) return [buf.readUInt16BE(i + 7), buf.readUInt16BE(i + 5)]
    i += 2 + buf.readUInt16BE(i + 2)
  }
  return [0, 0]
}

// A bare Page.captureScreenshot returns CSS pixels (1440x810) even under a device-scale override.
// The clip's scale makes Chromium rasterise at the device pixel ratio, so the frame is a true
// render at 1920x1080 times SS rather than an upscale.
const CLIP = { x: 0, y: 0, width: W, height: H, scale: DPR * SS }

async function capture(st, format = 'jpeg', quality = 95) {
  const r = await st.cdp.send('Page.captureScreenshot', { format, quality: format === 'jpeg' ? quality : undefined, optimizeForSpeed: true, captureBeyondViewport: false, fromSurface: true, clip: CLIP })
  return r.data
}

/** Draws time t (with motion blur when the camera moves) and returns a base64 JPEG. */
async function renderFrame(st, t, mode, { mblur = true, format = 'jpeg' } = {}) {
  const plan = mblur ? await st.page.evaluate(([t, mode]) => window.__stage.blurPlan(t, mode), [t, mode]) : { samples: 1 }
  const n = Math.max(1, plan.samples)
  if (n === 1) {
    await st.page.evaluate(([t, mode]) => window.__stage.frame(t, { mode }), [t, mode])
    if (SS === 1) return capture(st, format)
  }
  // Each shot is scaled down to 1920x1080 as soon as it is captured (at an exact SS ratio, 'high'
  // reads the box-filtered mip level) and added to a float sum on an OffscreenCanvas, so only one
  // full-size shot is in memory at a time. A fast move can take 70 sub-frames.
  await st.page.evaluate(([w, h, n]) => {
    window.__acc = { ctx: new OffscreenCanvas(w, h).getContext('2d', { willReadFrequently: true }), sum: n > 1 ? new Float32Array(w * h * 4) : null, n }
  }, [OUT_W, OUT_H, n])
  for (let k = 0; k < n; k++) {
    if (n > 1) {
      const tk = t + plan.shutter * ((k + 0.5) / n - 0.5)
      await st.page.evaluate(([tk, mode, mb]) => window.__stage.frame(tk, { mode, mblur: mb }), [tk, mode, { sx: plan.sx, sy: plan.sy }])
    }
    const shot = await capture(st, 'jpeg', 98)
    await st.page.evaluate(async (b64) => {
      const { ctx, sum } = window.__acc
      const { width: w, height: h } = ctx.canvas
      const blob = await (await fetch(`data:image/jpeg;base64,${b64}`)).blob()
      const bmp = await createImageBitmap(blob, { resizeWidth: w, resizeHeight: h, resizeQuality: 'high' })
      ctx.clearRect(0, 0, w, h)
      ctx.drawImage(bmp, 0, 0)
      bmp.close()
      if (!sum) return
      const d = ctx.getImageData(0, 0, w, h).data
      for (let i = 0; i < d.length; i++) sum[i] += d[i]
    }, shot)
  }
  return st.page.evaluate(async (format) => {
    const { ctx, sum, n } = window.__acc
    window.__acc = null
    const { width: w, height: h } = ctx.canvas
    if (sum) {
      const out = ctx.createImageData(w, h)
      for (let i = 0; i < sum.length; i++) out.data[i] = Math.round(sum[i] / n)
      ctx.putImageData(out, 0, 0)
    }
    const blob = await ctx.canvas.convertToBlob(format === 'png' ? { type: 'image/png' } : { type: 'image/jpeg', quality: 0.95 })
    const buf = new Uint8Array(await blob.arrayBuffer())
    let s = ''
    for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000))
    return btoa(s)
  }, format)
}

async function renderSequence(browser, base, mode, { workers, force }) {
  const probe = await openStage(browser, base)
  const dur = await probe.page.evaluate((m) => (m === 'preview' ? window.__stage.previewDuration : window.__stage.duration), mode)
  const fps = mode === 'preview' ? 30 : 60
  const n = Math.round(dur * fps)
  const dir = path.join(BUILD, 'frames', mode)
  fs.mkdirSync(dir, { recursive: true })
  const file = (i) => path.join(dir, `${String(i).padStart(5, '0')}.jpg`)
  // Frames from an older render at another size or supersampling factor are stale, so they are
  // re-rendered too. Frames without a .ss marker predate supersampling.
  const first = fs.readdirSync(dir).find((f) => f.endsWith('.jpg'))
  const ssFile = path.join(dir, '.ss')
  const oldSS = fs.existsSync(ssFile) ? Number(fs.readFileSync(ssFile, 'utf8')) : 1
  const stale = first && (imageSize(fs.readFileSync(path.join(dir, first))).join('x') !== `${OUT_W}x${OUT_H}` || oldSS !== SS)
  if (force || stale) for (const f of fs.readdirSync(dir)) fs.unlinkSync(path.join(dir, f))
  fs.writeFileSync(ssFile, String(SS))
  for (const f of fs.readdirSync(dir)) if (Number(f.slice(0, 5)) >= n) fs.unlinkSync(path.join(dir, f))
  const todo = []
  for (let i = 0; i < n; i++) if (!fs.existsSync(file(i))) todo.push(i)
  // A motion-blurred frame costs one capture per sub-frame (up to about 70), so the workers share
  // one queue, most expensive frames first, and no worker is left with all the fast moves.
  const cost = await probe.page.evaluate(([todo, fps, mode]) => todo.map((i) => window.__stage.blurPlan(i / fps, mode).samples), [todo, fps, mode])
  await probe.ctx.close()
  const queue = todo.map((i, k) => [i, cost[k]]).sort((a, b) => b[1] - a[1] || a[0] - b[0]).map(([i]) => i)
  console.log(`${mode}: ${n} frames at ${fps} fps, ${todo.length} to render with ${workers} workers`)
  if (!todo.length) return n
  let done = 0
  const t0 = Date.now()
  await Promise.all(Array.from({ length: Math.min(workers, todo.length) }, async () => {
    const st = await openStage(browser, base)
    for (let i; (i = queue.shift()) !== undefined;) {
      const b64 = await renderFrame(st, i / fps, mode)
      fs.writeFileSync(file(i) + '.tmp', Buffer.from(b64, 'base64'))
      fs.renameSync(file(i) + '.tmp', file(i))
      if (st.errors.length) throw new Error(`stage errors at ${mode} frame ${i}:\n${st.errors.join('\n')}`)
      done++
      if (done % 100 === 0) {
        const el = (Date.now() - t0) / 1000
        process.stdout.write(`  ${mode} ${done}/${todo.length}  ${(done / el).toFixed(1)} fps  eta ${Math.round((todo.length - done) / (done / el))} s\n`)
      }
    }
    await st.ctx.close()
  }))
  console.log(`${mode}: rendered ${todo.length} frames in ${((Date.now() - t0) / 1000).toFixed(1)} s`)
  return n
}

async function stills(browser, base, list) {
  const dir = path.join(BUILD, 'stills')
  fs.mkdirSync(dir, { recursive: true })
  const st = await openStage(browser, base)
  for (const item of list) {
    const [mode, ts] = item.includes(':') ? item.split(':') : ['film', item]
    const t = Number(ts)
    const b64 = await renderFrame(st, t, mode, { format: 'png' })
    const f = path.join(dir, `${mode}-${t.toFixed(2).padStart(6, '0')}.png`)
    fs.writeFileSync(f, Buffer.from(b64, 'base64'))
    console.log(f)
  }
  if (st.errors.length) console.error(st.errors.join('\n'))
  await st.ctx.close()
}

// ------------------------------------------------------------------ encoding

function ff(args, label) {
  console.log(`ffmpeg: ${label}`)
  const r = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { stdio: 'inherit' })
  if (r.status !== 0) throw new Error(`ffmpeg failed: ${label}`)
}

// Chrome's JPEGs are full-range BT.601 (JFIF); the deliverables are limited-range BT.709.
// ffmpeg 7+ takes the stream's colour tags from the frames, so setparams tags them; TAGS covers older builds.
const VF = (w, h) => `scale=${w}:${h}:flags=lanczos+accurate_rnd+full_chroma_int:in_range=pc:out_range=tv:in_color_matrix=bt601:out_color_matrix=bt709,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv,format=yuv420p`
const TAGS = ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv']

function need(f, hint) {
  if (!fs.existsSync(f)) throw new Error(`missing ${path.relative(ROOT, f)} (run ${hint})`)
  return f
}

function encodeFilm() {
  const frames = path.join(BUILD, 'frames', 'film', '%05d.jpg')
  const mix = need(path.join(BUILD, 'audio', 'mix-film.wav'), 'npm run mix')
  fs.mkdirSync(OUT, { recursive: true })
  ff(['-framerate', '60', '-i', frames, '-i', mix, '-map', '0:v', '-map', '1:a',
    '-vf', VF(1920, 1080), '-c:v', 'libx264', '-profile:v', 'high', '-level:v', '4.2', '-preset', 'slow', '-crf', '17',
    '-x264-params', 'keyint=120:min-keyint=60:aq-mode=3', ...TAGS,
    '-c:a', 'aac', '-b:a', '256k', '-ar', '48000', '-ac', '2', '-shortest', '-movflags', '+faststart',
    path.join(OUT, 'vibescribe-launch.mp4')], 'vibescribe-launch.mp4')
  ff(['-framerate', '60', '-i', frames, '-i', mix, '-map', '0:v', '-map', '1:a',
    '-vf', VF(1920, 1080), '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '22', '-row-mt', '1', '-deadline', 'good', '-cpu-used', '2',
    '-tile-columns', '2', '-g', '120', ...TAGS,
    '-c:a', 'libopus', '-b:a', '192k', '-ar', '48000', '-ac', '2', '-shortest',
    path.join(OUT, 'vibescribe-launch.webm')], 'vibescribe-launch.webm')
}

function encodePreview() {
  const frames = path.join(BUILD, 'frames', 'preview', '%05d.jpg')
  const mix = need(path.join(BUILD, 'audio', 'mix-preview.wav'), 'npm run mix')
  fs.mkdirSync(OUT, { recursive: true })
  // Apple asks for 10-12 Mbps. At CRF the flat UI would come out near 3 Mbps, and a single
  // bitrate pass undershoots (9.6 Mbps), so two passes put the average on 11 Mbps.
  const passlog = path.join(BUILD, 'x264-preview')
  const x264 = ['-vf', VF(1920, 1080), '-r', '30', '-c:v', 'libx264', '-profile:v', 'high', '-level:v', '4.0', '-preset', 'slow',
    '-b:v', '11M', '-maxrate', '12M', '-bufsize', '24M', '-x264-params', 'keyint=60:min-keyint=30:aq-mode=3', '-passlogfile', passlog]
  ff(['-framerate', '30', '-i', frames, ...x264, '-pass', '1', '-an', '-f', 'null', '-'], 'vibescribe-app-preview.mp4 (pass 1)')
  ff(['-framerate', '30', '-i', frames, '-i', mix, '-map', '0:v', '-map', '1:a', ...x264, '-pass', '2', ...TAGS,
    '-c:a', 'aac', '-b:a', '256k', '-ar', '48000', '-ac', '2', '-shortest', '-movflags', '+faststart',
    path.join(OUT, 'vibescribe-app-preview.mp4')], 'vibescribe-app-preview.mp4 (pass 2)')
  for (const f of fs.readdirSync(BUILD)) if (f.startsWith('x264-preview')) fs.unlinkSync(path.join(BUILD, f))
}

async function posters(browser, base, tl) {
  fs.mkdirSync(OUT, { recursive: true })
  const st = await openStage(browser, base)
  // Launch poster: the end card (icon, name, "Free on the Mac App Store"). App Preview poster: the
  // spec's poster frame (the "Pasted 19 words" moment), plus the cut's first frame for reference.
  const spec = JSON.parse(fs.readFileSync(path.join(ROOT, 'spec.json'), 'utf8'))
  const shots = [
    ['vibescribe-launch-poster.png', 'film', tl.output?.poster_frame_s ?? 55.6],
    ['vibescribe-app-preview-poster.png', 'preview', spec.preview_cut?.poster_frame_s ?? 8.27],
    ['vibescribe-app-preview-first-frame.png', 'preview', 0]
  ]
  for (const [name, mode, t] of shots) {
    const b64 = await renderFrame(st, t, mode, { format: 'png', mblur: false })
    fs.writeFileSync(path.join(OUT, name), Buffer.from(b64, 'base64'))
    console.log(`poster: out/${name} (${mode} t=${t})`)
  }
  await st.ctx.close()
}

function contactSheet(video, name) {
  const dir = path.join(BUILD, 'verify')
  fs.mkdirSync(dir, { recursive: true })
  ff(['-i', video, '-vf', 'fps=1,scale=480:-1,tile=6x10', '-frames:v', '1', path.join(dir, name)], `contact sheet ${name}`)
}

// ------------------------------------------------------------------ main

async function main() {
  const server = await serve(flag('--serve') ? Number(opt('--port', 8765)) : 0)
  const base = `http://127.0.0.1:${server.address().port}`
  if (flag('--serve')) {
    console.log(`stage: ${base}/stage/index.html?t=12.3   (preview cut: ?mode=preview&t=8.27, playback: ?play)`)
    return
  }
  const tl = JSON.parse(fs.readFileSync(path.join(BUILD, 'timeline.json'), 'utf8'))
  const browser = await chromium.launch({ args: ['--force-color-profile=srgb', '--disable-lcd-text', '--font-render-hinting=none', '--hide-scrollbars'] })
  try {
    if (flag('--stills')) {
      const list = opt('--stills', null)?.split(',') ??
        ['film:0.5', 'film:1.0', 'film:2.0', 'film:2.6', 'film:3.8', 'film:5.0', 'film:8.0', 'film:12.6', 'film:13.5', 'film:15.0', 'film:15.6', 'film:19.0', 'film:24.5',
          'film:27.6', 'film:29.5', 'film:33.3', 'film:38.0', 'film:41.6', 'film:43.0', 'film:45.8', 'film:47.6', 'film:49.6', 'film:51.3', 'film:52.6', 'film:53.8', 'film:55.5', 'film:58.0',
          'preview:0', 'preview:8.27', 'preview:12', 'preview:23', 'preview:28']
      await stills(browser, base, list)
      return
    }
    const only = opt('--only', null)
    const modes = only ? [only] : ['film', 'preview']
    const workers = Number(opt('--workers', Math.max(2, os.cpus().length - 2)))
    if (!flag('--encode-only')) for (const m of modes) await renderSequence(browser, base, m, { workers, force: flag('--force') })
    if (flag('--frames-only')) return
    if (modes.includes('film')) {
      encodeFilm()
      contactSheet(path.join(OUT, 'vibescribe-launch.mp4'), 'contact-film.png')
    }
    if (modes.includes('preview')) {
      encodePreview()
      contactSheet(path.join(OUT, 'vibescribe-app-preview.mp4'), 'contact-preview.png')
    }
    await posters(browser, base, tl)
  } finally {
    await browser.close()
    server.close()
  }
}

main().catch((e) => {
  console.error(e.stack || String(e))
  process.exit(1)
})
