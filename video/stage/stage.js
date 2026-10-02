// VibeScribe launch film and App Preview stage. One function of time draws the whole frame:
// window.__stage.frame(t, {mode}) where mode is 'film' (60 fps master) or 'preview' (the 30 fps
// App Preview cut, mapped onto film source time segment by segment).
import { clamp, lerp, prog, ease, sampleKeys, el, css, show } from './js/util.mjs'
import { SEQ, loadManifest, loadSequences, preloadAll, settle } from './js/assets.mjs'
import * as D from './js/desktop.mjs'
import * as Ty from './js/type.mjs'
import * as S from './js/screen.mjs'

const W = 1440
const H = 810
const $ = (id) => document.getElementById(id)

let TL, SC, CAM, LOOPS, ENV
const R = {}

// ------------------------------------------------------------------ data

const scene = (prefix) => SC.find((s) => s.id.startsWith(prefix))

function camera(T) {
  const c = sampleKeys(CAM, T, ['s', 'cx', 'cy'])
  const w = W / c.s
  const h = H / c.s
  return { s: c.s, ox: clamp(c.cx - w / 2, 0, W - w), oy: clamp(c.cy - h / 2, 0, H - h) }
}

/** Kick/bass level of the music bed for the cold-open bars (falls back to a synthetic pulse). */
function musicLevel(t) {
  let lv
  if (ENV) lv = clamp(ENV.levels[Math.min(ENV.levels.length - 1, Math.max(0, Math.floor(t * ENV.fps)))] || 0, 0, 0.9)
  else {
    const beat = 0.4
    const ph = t < 0.8 ? 10 : (t - 0.8) % beat
    lv = t < 0.8 ? 0.12 + 0.2 * (t / 0.8) : 0.3 + 0.45 * Math.exp(-ph * 9)
  }
  if (t >= 0.8) lv = Math.max(lv, clamp(1 - 0.15 * Math.floor((t - 0.8) * 30)))
  return lv
}

const SEGMENTS = () => TL.preview.segments

/** Preview time -> {seg, src} (src null on the slate). */
function previewMap(t) {
  const segs = SEGMENTS()
  for (const s of segs) if (t < s.dst_out || s === segs[segs.length - 1]) return { seg: s, src: s.offset == null ? null : t + s.offset }
}

// ------------------------------------------------------------------ build

async function init() {
  TL = await (await fetch('/build/timeline.json')).json()
  SC = TL.scenes
  LOOPS = TL.loops
  CAM = SC.flatMap((s) => s.camera.map((k) => ({ ...k, ease: k.ease || 'linear' }))).sort((a, b) => a.t - b.t)
  await loadManifest()
  await loadSequences(LOOPS)
  try {
    const r = await fetch('/build/audio/music.envelope.json')
    if (r.ok) ENV = await r.json()
  } catch {}
  await Promise.all(['400 13px "SF Mono Film"', '500 13px "SF Mono Film"', '500 20px "SF Mono Film"'].map((f) => document.fonts.load(f)))
  await document.fonts.ready
  build()
  await preloadAll()
  window.__stage.ready = true
}

function build() {
  const world = $('world')
  const scr = $('screen')
  R.world = world
  R.worldDim = $('worldDim')
  R.fade = $('fade')
  R.wp = D.buildWallpaper(world)
  const B = scene('B'), C = scene('C'), Dd = scene('D'), E = scene('E')
  R.mail = D.buildMail(world, B)
  R.term = D.buildTerminal(world, C)
  R.chat = D.buildChat(world, Dd)
  R.notes = D.buildNotes(world, E)
  R.mb = D.buildMenubar(world)
  R.rings = D.buildRings(world)
  R.picker = D.buildPicker(world)
  R.pill = D.buildPill(world)
  R.pointer = D.buildPointer(world)
  for (const c of ['Thu 09:12', 'Thu 11:47', 'Thu 16:05', 'Thu 19:48']) D.menubarLayout(R.mb, c)

  // Screen layers, back to front.
  R.scrim = el('div', 'scrim', scr)
  R.platesLayer = el('div', 'layer-full', scr)
  R.film = el('div', 'layer-full', scr)
  R.prev = el('div', 'layer-full', scr)
  R.heroBars = S.buildHeroBars(R.film)
  R.modelCard = S.buildModelCard(R.film)
  R.cards = S.buildCards(R.film, scene('G'))
  R.icon = S.buildIcon(R.film)

  // Film type (G's type lives inside its cards).
  const hardCutAt = new Set([47.2, 58.4])
  R.texts = []
  const byId = {}
  for (const s of SC) {
    if (s.id.startsWith('G')) continue
    for (const t of s.text) {
      const spec = { ...t, hardCut: hardCutAt.has(t.end) }
      if (t.id === 'b_cap2b') spec.after = 'b_cap2a'
      if (t.id === 'free') Object.assign(spec, { end: 1.9, hardCut: true })
      const item = Ty.createText(R.film, spec)
      R.texts.push(item)
      byId[t.id] = item
    }
  }
  R.byId = byId
  R.freeRule = Ty.createRule(byId.free.root, 26, 5, 6)

  // Preview type: captions per segment plus the slate.
  R.ptexts = []
  const pById = {}
  let n = 0
  for (const seg of SEGMENTS()) {
    for (const c of seg.captions || []) {
      const id = `p${n++}`
      const spec = { id, text: c.text, style: c.style, start: c.dst_start, end: c.dst_end }
      if (n === 1) Object.assign(spec, { start: 0, landed: true })
      if (c.text === "It's pasted.") spec.after = Object.keys(pById).find((k) => pById[k].spec.text === 'Let go.')
      const item = Ty.createText(R.prev, spec)
      R.ptexts.push(item)
      pById[id] = item
    }
  }
  const slate = SEGMENTS().find((s) => s.offset == null)
  R.slate = slate
  for (const e of slate.elements.filter((x) => x.text)) {
    // A touch more air between the title and the line under it than the storyboard's 54 units.
    const position = e.style === 'end_sub' ? [e.center[0], e.center[1] + 6] : e.center
    const item = Ty.createText(R.prev, { id: e.text, text: e.text, style: e.style, start: slate.dst_in + e.start_offset, end: 99, position, anchor: 'center', hardCut: true })
    R.ptexts.push(item)
  }
  R.picon = S.buildIcon(R.prev)
  R.ppill = D.buildPill(R.prev)
  R.pillSlate = slate.elements.find((x) => x.sprite && x.sprite.startsWith('pill_'))

  // HUD (film presses, also used by the preview at source time).
  const hudEntries = SC.flatMap((s) => [...(s.keycap_hud || []), ...((s.cards || []).flatMap((c) => c.visual?.keycap_hud || []))])
  R.hud = S.buildHud(scr, S.hudPresses(hudEntries))
  R.cols = S.buildColumns(scr)

  // Measure all type (fonts are ready).
  for (const it of R.texts) Ty.measureText(it, byId)
  const chips = ['chip_account', 'chip_key', 'chip_sub'].map((id) => byId[id])
  for (let i = 1; i < chips.length; i++) chips[i].left = chips[i - 1].left + chips[i - 1].w + 12
  for (const it of R.ptexts) Ty.measureText(it, pById)
  R.plates = Ty.createPlates(R.platesLayer, R.texts)
  R.pplates = Ty.createPlates(R.platesLayer, R.ptexts)
  S.measureCards(R.cards)

  // Transition lists.
  R.filmTr = [
    { kind: 'bars_rise', start: 15.2, end: 16.0, cover: 15.6 },
    { kind: 'bars_sweep', start: 25.2, end: 26.0, cover: 25.6 },
    { kind: 'bars_fall', start: 34.8, end: 35.6, cover: 35.2 },
    { kind: 'single_bar_wipe', start: 47.05, end: 47.35, cover: 47.2 },
    { kind: 'bars_to_icon', start: 53.45, end: 54.25, coverIn: [53.45, 53.6], contract: [53.6, 54.0], icon: { cx: 720, cy: 290, size: 200 } }
  ]
  R.prevTr = [
    { kind: 'bars_rise', start: 8.9, end: 9.7, cover: 9.3 },
    { kind: 'bars_sweep', start: 18.6, end: 19.4, cover: 19.0 },
    { kind: 'bars_to_icon', start: 26.65, end: 27.35, coverIn: [26.65, 26.8], contract: [26.8, 27.1], icon: { cx: 720, cy: 250, size: 168 } }
  ]
  R.filmCuts = [15.6, 25.6, 35.2, 47.2, 53.6]
  R.prevCuts = [9.3, 19.0, 26.8]

  // T1 target: the waveform glyph where the camera lands at 4.0.
  const L = D.menubarLayout(R.mb, 'Thu 09:12')
  const cam = camera(4.0)
  const gx = L.siRight - 33.5
  R.glyph = { x: (gx - cam.ox) * cam.s, y: (13 - 8 - cam.oy) * cam.s, w: 15.5 * cam.s, h: 16 * cam.s }
}

// ------------------------------------------------------------------ world (film source time)

function menubarConfig(T) {
  const sc = T < 4 ? scene('B') : T < 15.6 ? scene('B') : T < 25.6 ? scene('C') : T < 35.2 ? scene('D') : scene('E')
  const m = sc.background.menubar
  const app = T < 4 ? null : m.app
  return { app, menus: app ? m.menus : [], clock: T < 4 ? 'Thu 09:12' : m.clock, wifi: m.wifi }
}

function statusAt(T) {
  for (const L of LOOPS) {
    if (T >= L.rec_start && T < L.stop) return { kind: 'seq', layer: SEQ[L.key].statusitem, index: Math.floor((T - L.rec_start) * 60 + 1e-6) }
    if (T >= L.stop && T < L.pasted) return { kind: 'seq', layer: SEQ[L.key].statusitem_transcribing, index: Math.floor((T - L.stop) * 60 + 1e-6) }
  }
  const st = { kind: 'idle', badge: 'en', opacity: T < 4 ? prog(T, 3.85, 0.15) : 1, glow: 0 }
  if (T >= 27.95 && T < 35.2) {
    st.badge = 'de'
    const f = prog(T, 27.95, 0.12)
    if (f < 1) {
      st.from = 'en'
      st.fade = ease.easeInOutSine(f)
    }
    const g = prog(T, 27.95, 0.3)
    st.glow = g > 0 && g < 1 ? Math.sin(Math.PI * g) : 0
  }
  return st
}

function drawWorld(T, { slate = false, mblur = null } = {}) {
  let cam = { s: 1, ox: 0, oy: 0 }
  if (slate) {
    D.updateWallpaper(R.wp, { blur: 30, dim: 0.45 })
    for (const w of [R.mail, R.term, R.chat, R.notes]) show(w.root, false)
    show(R.mb.root, false)
    show(R.pill.root, false)
    show(R.picker.root, false)
    show(R.rings.svg, false)
    D.updatePointer(R.pointer, null)
    css(R.worldDim, { opacity: '0' })
  } else {
    cam = camera(T)
    // Wallpaper and grade.
    let wp = { blur: 0, dim: 0, evening: 0 }
    if (T < 4) {
      const u = ease.easeInOutCubic(prog(T, 3.6, 0.4))
      wp = { blur: 24 * (1 - u), dim: 0.35 * (1 - u), evening: 0 }
    } else if (T >= 35.2 && T < 47.2) wp.evening = 0.18
    else if (T >= 47.2 && T < 53.6) wp = { blur: 30, dim: 0.25, evening: 0 }
    else if (T >= 53.6) wp = { blur: 30, dim: 0.45, evening: 0 }
    D.updateWallpaper(R.wp, wp)
    const g = T >= 42.4 && T < 47.2 ? ease.easeInOutCubic(prog(T, 43.8, 0.6)) : 0
    css(R.worldDim, { opacity: (0.55 * g).toFixed(4) })
    R.worldBlur = 12 * g

    // Windows.
    show(R.mail.root, T >= 3.7 && T < 15.6)
    if (T >= 3.7 && T < 15.6) D.updateMail(R.mail, T, scene('B'))
    show(R.term.root, T >= 15.6 && T < 25.6)
    if (T >= 15.6 && T < 25.6) D.updateTerminal(R.term, T)
    show(R.chat.root, T >= 25.6 && T < 35.2)
    if (T >= 25.6 && T < 35.2) D.updateChat(R.chat, T)
    show(R.notes.root, T >= 35.2 && T < 47.2)
    if (T >= 35.2 && T < 47.2) D.updateNotes(R.notes, T)

    // Menu bar and status item.
    const mbVis = T >= 3.7 && T < 47.2
    let layout = null
    const cfg = menubarConfig(T)
    layout = D.updateMenubar(R.mb, T, { visible: mbVis, y: -26 * (1 - ease.easeOutCubic(prog(T, 3.7, 0.2))), ...cfg, status: statusAt(T), viewLeft: cam.ox, viewRight: cam.ox + W / cam.s })

    // Overlay pill, picker, pointer, rings.
    if (T < 47.2) D.updatePill(R.pill, T, LOOPS)
    else show(R.pill.root, false)
    D.updatePicker(R.picker, T, T >= 25.6 && T < 35.2 ? scene('D') : null)
    let ptr = null
    if (T >= 14.4 && T < 15.3) {
      const u = ease.easeInOutCubic(prog(T, 14.55, 0.35))
      const a = ease.easeOutCubic(prog(T, 14.4, 0.15)) * (1 - ease.easeInQuad(prog(T, 15.0, 0.3)))
      ptr = { x: lerp(980, 1100, u), y: lerp(360, 116, u), scale: T >= 14.9 && T < 14.98 ? 0.86 : 1, opacity: a }
    }
    D.updatePointer(R.pointer, ptr)
    const F = scene('F')
    const ring = F.elements.find((e) => e.kind === 'ring')
    if (T >= 42.4 && T < 44.4 && layout) D.updateRings(R.rings, T, ring, layout.wifiCenter)
    else show(R.rings.svg, false)
  }
  let filter = ''
  if (mblur && (mblur.sx > 0.05 || mblur.sy > 0.05)) {
    $('mblurStd').setAttribute('stdDeviation', `${(mblur.sx / cam.s).toFixed(3)} ${(mblur.sy / cam.s).toFixed(3)}`)
    filter += 'url(#mblur) '
  }
  if (!slate && R.worldBlur > 0.05) filter += `blur(${(R.worldBlur / cam.s).toFixed(3)}px)`
  css(R.world, { transform: `scale(${cam.s.toFixed(6)}) translate(${(-cam.ox).toFixed(4)}px, ${(-cam.oy).toFixed(4)}px)`, filter: filter.trim() || 'none' })
  return cam
}

// ------------------------------------------------------------------ screen layers

function drawFilmScreen(T) {
  show(R.film, true)
  show(R.prev, false)
  S.updateHeroBars(R.heroBars, T, musicLevel, R.glyph)
  // Type, with the "Free" shared-element morph into the first word of the headline.
  const free = R.byId.free, line1 = R.byId.free_line1
  for (const it of R.texts) {
    if (it === free || it === line1) continue
    Ty.updateText(it, T)
  }
  if (T >= 1.6 && T < 1.9) {
    const u = ease.title(prog(T, 1.6, 0.3))
    const [tx, ty] = Ty.wordCenter(line1, 0)
    const cx = free.left + free.w / 2, cy = free.top + free.h / 2
    const k = line1.words[0].w / free.w
    Ty.updateText(free, T, { dx: (tx - cx) * u, dy: (ty - cy) * u, scale: lerp(1, k, u), opacity: 1 - prog(T, 1.82, 0.08) })
  } else Ty.updateText(free, T)
  Ty.updateRule(R.freeRule, free.w * 0.06, free.h + 2, free.w * 0.88, prog(T, 0.9, 0.3), 1 - prog(T, 1.6, 0.15))
  Ty.updateText(line1, T, { wordAlpha: { 0: prog(T, 1.82, 0.08) } })
  Ty.updateScrim(R.scrim, R.texts, T)
  for (const p of R.pplates) show(p.node, false)
  Ty.updatePlates(R.plates, T)
  S.updateModelCard(R.modelCard, T)
  S.updateCards(R.cards, T)
  S.updateIcon(R.icon, T, 54.0, 720, 290, 200, T >= 53.6)
  S.updateHud(R.hud, T)
  S.updateTransitions(R.cols, T, R.filmTr)
  const fade = Math.max(1 - prog(T, 0, 0.4), prog(T, 57.9, 0.5))
  css(R.fade, { opacity: fade.toFixed(4) })
}

function drawPreviewScreen(t, src) {
  show(R.film, false)
  show(R.prev, true)
  for (const it of R.ptexts) Ty.updateText(it, t, { landed: !!it.spec.landed })
  Ty.updateScrim(R.scrim, R.ptexts, t)
  for (const p of R.plates) show(p.node, false)
  Ty.updatePlates(R.pplates, t)
  const iconT = R.prevTr[2].contract[1]
  S.updateIcon(R.picon, t, iconT, 720, 250, 168, t >= R.slate.dst_in)
  if (t >= R.slate.dst_in) {
    const p = R.pillSlate
    D.updateStaticPill(R.ppill, p.sprite, t, R.slate.dst_in + p.start_offset, { x: p.center[0], y: p.center[1] + 8 - 17 * p.scale, scale: p.scale })
  } else show(R.ppill.root, false)
  S.updateHud(R.hud, src == null ? -10 : src)
  S.updateTransitions(R.cols, t, R.prevTr)
  css(R.fade, { opacity: prog(t, TL.preview.total_s - 0.4, 0.4).toFixed(4) })
}

// ------------------------------------------------------------------ public API

function draw(t, mode, mblur) {
  if (mode === 'preview') {
    const { src } = previewMap(t)
    drawWorld(src ?? 0, { slate: src == null, mblur })
    drawPreviewScreen(t, src)
  } else {
    drawWorld(t, { mblur })
    drawFilmScreen(t)
  }
}

async function frame(t, opts = {}) {
  draw(t, opts.mode || 'film', opts.mblur || null)
  await settle()
  await new Promise((r) => requestAnimationFrame(() => r()))
  return true
}

/**
 * Motion-blur plan for the frame at t: how many temporal sub-samples a 180-degree shutter (half the
 * frame interval: 1/120 s for the 60 fps film, 1/60 s for the 30 fps preview) needs for the camera
 * move, and the per-sample directional blur (screen units). No blur across cuts.
 */
function blurPlan(t, mode = 'film') {
  const sh = mode === 'preview' ? 1 / 60 : 1 / 120
  const srcOf = (x) => (mode === 'preview' ? previewMap(x).src : x)
  const a = srcOf(t - sh / 2), b = srcOf(t + sh / 2), m = srcOf(t)
  const cuts = mode === 'preview' ? R.prevCuts : R.filmCuts
  if (a == null || b == null || m == null) return { samples: 1 }
  for (const c of cuts) if (c > t - sh / 2 && c <= t + sh / 2) return { samples: 1 }
  if (mode === 'preview' && previewMap(t - sh / 2).seg !== previewMap(t + sh / 2).seg) return { samples: 1 }
  const ca = camera(a), cb = camera(b), cm = camera(m)
  const vw = W / cm.s, vh = H / cm.s
  const pts = [[cm.ox, cm.oy], [cm.ox + vw, cm.oy], [cm.ox, cm.oy + vh], [cm.ox + vw, cm.oy + vh], [cm.ox + vw / 2, cm.oy + vh / 2]]
  let dmax = 0, dcx = 0, dcy = 0
  pts.forEach(([x, y], i) => {
    const dx = (x - cb.ox) * cb.s - (x - ca.ox) * ca.s
    const dy = (y - cb.oy) * cb.s - (y - ca.oy) * ca.s
    dmax = Math.max(dmax, Math.hypot(dx, dy))
    if (i === 4) { dcx = dx; dcy = dy }
  })
  if (dmax <= 6) return { samples: 1, d: dmax }
  // Temporal supersampling only: sub-frames at most ~2.2 screen units apart read as a smooth
  // smear. (A per-sample SVG blur was tried; Chromium rasterises it at layer resolution, which
  // softens text, so it is off.)
  const samples = Math.min(72, Math.max(3, Math.ceil(dmax / 2.2)))
  return { samples, d: dmax, shutter: sh, sx: 0, sy: 0 }
}

window.__stage = {
  ready: false,
  frame,
  blurPlan,
  get duration() { return TL.duration },
  get previewDuration() { return TL.preview.total_s },
  previewMap: (t) => previewMap(t),
  camera
}

/**
 * Interactive viewing only (render.mjs never sets these): ?t=12.3 draws one frame, ?mode=preview
 * switches to the App Preview cut, ?play plays from t in real time (wall clock, so not frame-exact).
 */
function urlView() {
  const q = new URLSearchParams(location.search)
  if (!q.has('t') && !q.has('play')) return
  const mode = q.get('mode') === 'preview' ? 'preview' : 'film'
  const dur = mode === 'preview' ? TL.preview.total_s : TL.duration
  const start = Number(q.get('t') || 0)
  if (!q.has('play')) return void draw(start, mode, null)
  const t0 = performance.now()
  const tick = () => {
    draw((start + (performance.now() - t0) / 1000) % dur, mode, null)
    requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}

init().then(urlView).catch((e) => {
  console.error('stage init failed', e)
  window.__stage.error = String(e && e.stack || e)
})
