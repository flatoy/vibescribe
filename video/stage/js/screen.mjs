// Screen-space pieces that do not zoom with the camera: the cold-open spectrum bars, the keycap
// HUD, the model card, the feature montage cards, the end card, and all spectrum transitions.
import { clamp, lerp, prog, ease, spring, el, css, show } from './util.mjs'
import { SPRITES, img, setSrc } from './assets.mjs'
import { createText, measureText, updateText, createRule, updateRule, createTicker, updateTicker } from './type.mjs'

export const SPECTRUM = ['#6EC6EA', '#7BA3F0', '#9A8AE6', '#C68AEE', '#D884C4', '#EE9A8F', '#EDBB7A']
export const PROFILE = [0.34, 0.72, 0.48, 1, 0.56, 0.78, 0.34]
const SPEEDS = [7.9, 10.4, 6.9, 9, 7.6, 9.7, 6.6]
const PHASES = [0.2, 1.9, 3.1, 0.8, 2.6, 4.2, 5]
const W = 1440
const H = 810
const BLINK = 0.53
const blink = (t, since) => Math.floor(Math.max(0, t - since) / BLINK) % 2 === 0

const hexRgb = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)]
const mixToWhite = (h, u) => {
  const [r, g, b] = hexRgb(h)
  return `rgb(${Math.round(lerp(r, 255, u))}, ${Math.round(lerp(g, 255, u))}, ${Math.round(lerp(b, 255, u))})`
}

// Icon bars in the 1024 px app icon (measured from Icon.png).
const ICON_BARS = [0, 1, 2, 3, 4, 5, 6].map((i) => {
  const tops = [432, 333, 404, 254, 374, 344, 432]
  const bottoms = [591, 691, 620, 771, 650, 680, 591]
  return { cx: 211.5 + 100 * i, w: 72, top: tops[i], bottom: bottoms[i] }
})

/** Screen rect of icon bar i for an icon of `size` centred at (cx, cy), scaled by k about its centre. */
export function iconBarRect(i, cx, cy, size, k = 1) {
  const b = ICON_BARS[i]
  const f = (size / 1024) * k
  const x = cx + (b.cx - 512) * f
  const yc = cy + ((b.top + b.bottom) / 2 - 512) * f
  const h = (b.bottom - b.top) * f
  const w = b.w * f
  return { x: x - w / 2, y: yc - h / 2, w, h, r: w / 2 }
}

// ------------------------------------------------------------------ cold-open bars

export function buildHeroBars(parent) {
  const root = el('div', 'heroBars', parent)
  const bars = SPECTRUM.map((c) => {
    const b = el('div', 'hbar', root)
    css(b, { background: c })
    return b
  })
  return { root, bars }
}

/** Live bars (pill.bars.live maths) at 18 x 96 with a 12 gap, centred at (720, 330). */
function liveRects(T, level) {
  const tq = Math.floor(T * 30 + 1e-6) / 30
  const lv = level(tq)
  return PROFILE.map((p, i) => {
    const f = clamp(0.2 + 0.03 * Math.sin(3 * tq + PHASES[i]) + 0.8 * lv * p * (0.72 + 0.28 * Math.sin(tq * SPEEDS[i] + PHASES[i])), 0.18, 1)
    const h = Math.max(18, 96 * f)
    return { x: 621 + i * 30, y: 330 - h / 2, w: 18, h, r: 9 }
  })
}

/** glyph: {x, y, w, h} screen rect of the waveform glyph when the camera lands (T1 target). */
export function updateHeroBars(hb, T, level, glyph, opacity = 1) {
  const visible = T < 4.0
  show(hb.root, visible)
  if (!visible) return
  const live = liveRects(T, level)
  const u = ease.easeInOutCubic(prog(T, 3.6, 0.4))
  const fade = 1 - prog(T, 3.9, 0.1)
  hb.bars.forEach((b, i) => {
    let r = live[i]
    if (u > 0) {
      const gw = glyph.w / 7
      const bw = Math.max(1.2, gw * 0.5)
      const th = glyph.h * (0.35 + 0.65 * PROFILE[i])
      const tgt = { x: glyph.x + gw * i + (gw - bw) / 2, y: glyph.y + (glyph.h - th) / 2, w: bw, h: th, r: bw / 2 }
      // Stagger the flight a little from the centre out.
      const k = ease.easeInOutCubic(clamp((u - Math.abs(i - 3) * 0.03) / 0.91))
      r = { x: lerp(r.x, tgt.x, k), y: lerp(r.y, tgt.y, k), w: lerp(r.w, tgt.w, k), h: lerp(r.h, tgt.h, k), r: lerp(r.r, tgt.r, k) }
    }
    css(b, {
      transform: `translate(${r.x.toFixed(3)}px, ${r.y.toFixed(3)}px)`,
      width: `${r.w.toFixed(3)}px`,
      height: `${r.h.toFixed(3)}px`,
      borderRadius: `${r.r.toFixed(3)}px`,
      background: u > 0 ? mixToWhite(SPECTRUM[i], ease.easeInQuad(u)) : SPECTRUM[i],
      opacity: (fade * opacity).toFixed(4)
    })
  })
}

// ------------------------------------------------------------------ keycap HUD

export function hudPresses(entries) {
  const list = [...entries].sort((a, b) => a.t - b.t)
  const presses = []
  list.forEach((e, idx) => {
    if (!e.down) return
    const key = JSON.stringify(e.key)
    const up = list.slice(idx + 1).find((x) => !x.down && JSON.stringify(x.key) === key)
    presses.push({ keys: Array.isArray(e.key) ? e.key : [e.key], down: e.t, up: up ? up.t : e.t + 0.15, label: e.label || null })
  })
  presses.forEach((p, i) => {
    const next = presses[i + 1]
    p.start = p.down - 0.15
    p.end = Math.min(p.up + 0.4, next ? next.down : Infinity)
  })
  return presses
}

export function buildHud(parent, presses) {
  const root = el('div', 'hud', parent)
  const scale = 2.2
  const insts = presses.map((p) => {
    const node = el('div', 'hudInst', root)
    const metas = p.keys.map((k) => SPRITES[k])
    const gap = 6
    const totalW = metas.reduce((a, m) => a + m.size_pt[0], 0) + gap * (metas.length - 1)
    let x = -totalW / 2
    const keys = metas.map((m) => {
      const k = img(node, 'key')
      setSrc(k, m.src)
      css(k, { left: `${(x * scale).toFixed(2)}px`, top: `${(-m.anchor_pt[1] * scale).toFixed(2)}px`, width: `${m.size_pt[0] * scale}px`, height: `${m.size_pt[1] * scale}px` })
      x += m.size_pt[0] + gap
      return k
    })
    let label = null
    if (p.label) {
      label = el('div', 'lbl', node, p.label)
      css(label, { left: '-50px', top: `${(13 * scale + 8).toFixed(1)}px` })
    }
    show(node, false)
    return { p, node, keys, label }
  })
  return { root, insts }
}

export function updateHud(hud, T) {
  for (const it of hud.insts) {
    const p = it.p
    const vis = T >= p.start && T < p.end
    show(it.node, vis)
    if (!vis) continue
    const a = ease.easeOutCubic(prog(T, p.start, 0.15)) * (1 - ease.easeInQuad(prog(T, p.end - 0.15, 0.15)))
    const rise = 8 * (1 - ease.easeOutCubic(prog(T, p.start, 0.15)))
    css(it.node, { transform: `translate(720px, ${(742 + rise).toFixed(3)}px)`, opacity: a.toFixed(4) })
    let press = 0
    if (T >= p.down && T < p.up) press = ease.easeOutQuad(prog(T, p.down, 0.04))
    else if (T >= p.up) press = 1 - clamp(spring(T - p.up, 0.24, 0.62), 0, 1.15)
    const pressedNow = T >= p.down && T < p.up
    for (const k of it.keys) {
      css(k, { transform: `translateY(${(2 * 2.2 * press).toFixed(3)}px)`, filter: pressedNow || press > 0.3 ? `brightness(${(1 + 0.12 * clamp(press)).toFixed(3)})` : 'none' })
    }
  }
}

// ------------------------------------------------------------------ F: model card

export function buildModelCard(parent) {
  const root = el('div', 'modelCard', parent)
  const shadow = el('div', 'mshadow', root)
  const clip = el('div', 'mclip', root)
  const image = img(clip, '')
  setSrc(image, SPRITES.settings_model_ready.src)
  // Crop the Speech model page: window x 204..776, from y 4 (inside the window edges). The page sits
  // 14 px lower in the card so the heading has room above it; the clip's fill matches the pane.
  const k = 600 / 572
  css(clip, { background: '#232327' })
  // The sprite carries the window's translucent shadow above y 0, so the image is clipped at y 4.
  css(image, { left: `${(-(204 + 58) * k).toFixed(3)}px`, top: `${(14 - (4 + 90) * k).toFixed(3)}px`, width: `${(896 * k).toFixed(3)}px`, height: `${(683 * k).toFixed(3)}px`,
    clipPath: `inset(${((4 + 90) * k).toFixed(3)}px 0 0 0)` })
  return { root }
}

export function updateModelCard(mc, T) {
  const vis = T >= 44.0 && T < 47.2
  show(mc.root, vis)
  if (!vis) return
  const u = ease.easeOutCubic(prog(T, 44.0, 0.45))
  const drift = lerp(1, 1.02, ease.easeInOutSine(prog(T, 44.0, 3.2)))
  css(mc.root, { transform: `translate(760px, ${(210 + 40 * (1 - u)).toFixed(3)}px) scale(${drift.toFixed(5)})`, opacity: u.toFixed(4) })
}

// ------------------------------------------------------------------ G: montage cards

const SET_SCALE = 0.9
const CARD_RECT = [640, 150, 702, 504]
const FOCUS = {
  'G1-languages': [247, 160],
  'G2-history': [190, 70],
  'G3-vocabulary': [(490) * SET_SCALE, 322 * SET_SCALE],
  'G4-shortcut': [620 * SET_SCALE, 100 * SET_SCALE]
}

export function buildCards(parent, scene) {
  const cards = scene.cards.map((c, idx) => {
    const wrap = el('div', 'gcard', parent)
    const picker = c.visual.sprite === 'picker_montage'
    const rect = picker ? c.visual.rect : CARD_RECT
    const vis = el('div', 'gvis', wrap)
    css(vis, { left: `${rect[0]}px`, top: `${rect[1]}px`, width: `${rect[2]}px`, height: `${rect[3]}px` })
    const shadow = el('div', 'gshadow', vis)
    css(shadow, { borderRadius: picker ? '19px' : '11px' })
    const clip = el('div', 'gclip', vis)
    css(clip, { borderRadius: picker ? '19px' : '10.8px' })
    const push = el('div', 'gpush', clip)
    const [fx, fy] = FOCUS[c.id]
    css(push, { transformOrigin: `${fx}px ${fy}px` })
    const image = img(push, '')
    if (picker) {
      css(image, { left: '0px', top: '0px', width: `${rect[2]}px`, height: `${rect[2] * 372 / 380}px` })
      setSrc(image, SPRITES[c.visual.sprite].src)
    } else {
      css(image, { left: `${-58 * SET_SCALE}px`, top: `${-90 * SET_SCALE}px`, width: `${896 * SET_SCALE}px`, height: `${683 * SET_SCALE}px` })
      setSrc(image, SPRITES[c.visual.sprite_states[0].sprite].src)
    }
    const caret = el('div', 'caret', push)
    const texts = scene.text.filter((t) => t.id.startsWith(c.id)).map((t) => createText(wrap, { ...t, end: c.end + 0.2, hardCut: true }))
    const rule = createRule(wrap, 26, 4, 5)
    const ticker = c.extra?.kind === 'native_name_ticker' ? createTicker(wrap, c.extra.names, [96, 452, 560, 30]) : null
    let pointer = null
    if (c.id === 'G4-shortcut') {
      pointer = el('div', 'pointer gpointer', wrap, POINTER_SVG)
    }
    return { c, idx, wrap, vis, push, image, caret, texts, rule, ticker, pointer, picker, rect }
  })
  const bar = el('div', 'wipeBar', parent)
  return { cards, bar }
}

export const POINTER_SVG = `<svg viewBox="0 0 18 26" width="18" height="26"><path d="M1.5 1.5 L1.5 20.5 L6.2 16.2 L9.4 23.6 L12.6 22.2 L9.5 15 L15.8 15 Z" fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>`

export function measureCards(g) {
  const byId = {}
  for (const card of g.cards) for (const t of card.texts) measureText(t, byId)
}

const WIPE = 0.25
const BAR_W = 150
const BOUNDS = [
  { t: 48.8, dir: -1 },
  { t: 50.4, dir: 1 },
  { t: 52.0, dir: -1 }
]
const wipeX = (T, b) => {
  const u = ease.easeInOutSine(prog(T, b.t - WIPE / 2, WIPE))
  return b.dir > 0 ? lerp(-BAR_W / 2, W + BAR_W / 2, u) : lerp(W + BAR_W / 2, -BAR_W / 2, u)
}

export function updateCards(g, T) {
  const active = T >= 47.2 && T < 53.6
  let barX = null, barDir = 1
  for (const card of g.cards) {
    const { c, idx } = card
    const inB = idx > 0 ? BOUNDS[idx - 1] : null
    const outB = idx < 3 ? BOUNDS[idx] : null
    const t0 = inB ? inB.t - WIPE / 2 : 47.2
    const t1 = outB ? outB.t + WIPE / 2 : 53.6
    const vis = active && T >= t0 && T < t1
    show(card.wrap, vis)
    if (!vis) continue
    let clip = 'none'
    if (inB && T < inB.t + WIPE / 2) {
      const x = wipeX(T, inB)
      clip = inB.dir > 0 ? `inset(0px ${(W - x).toFixed(2)}px 0px 0px)` : `inset(0px 0px 0px ${x.toFixed(2)}px)`
      barX = x
      barDir = inB.dir
    } else if (outB && T >= outB.t - WIPE / 2) {
      const x = wipeX(T, outB)
      clip = outB.dir > 0 ? `inset(0px 0px 0px ${x.toFixed(2)}px)` : `inset(0px ${(W - x).toFixed(2)}px 0px 0px)`
    }
    css(card.wrap, { clipPath: clip })
    // Visual: settle in, then a slow 3% push toward the focus point.
    const st = ease.title(prog(T, c.start - 0.05, 0.5))
    const pushK = lerp(1, 1.03, ease.easeInOutSine(prog(T, c.start, c.end - c.start + 0.15)))
    css(card.vis, { transform: `translateY(${(22 * (1 - st)).toFixed(3)}px)` })
    css(card.push, { transform: `scale(${pushK.toFixed(5)})` })
    // Sprite state and caret.
    let meta = SPRITES[c.visual.sprite]
    let since = c.start
    if (c.visual.sprite_states) {
      let s = c.visual.sprite_states[0]
      for (const x of c.visual.sprite_states) if (T >= x.t) s = x
      meta = SPRITES[s.sprite]
      since = s.t
      setSrc(card.image, meta.src)
    }
    const cr = meta.caret_rect_pt
    if (cr && !card.picker) {
      css(card.caret, { left: `${((cr[0] - 58) * SET_SCALE).toFixed(2)}px`, top: `${((cr[1] - 90) * SET_SCALE).toFixed(2)}px`, width: '1.5px', height: `${(cr[3] * SET_SCALE).toFixed(2)}px` })
      show(card.caret, blink(T, since))
    } else show(card.caret, false)
    // Type.
    card.texts.forEach((t) => updateText(t, T))
    updateRule(card.rule, 96, 436, 206, prog(T, c.start + 0.4, 0.35))
    if (card.ticker) updateTicker(card.ticker, T, c.start, true, ease.easeOutCubic(prog(T, c.start + 0.3, 0.35)))
    if (card.pointer) {
      // G4: the pointer glides to the Dictation key field, clicks at 52.3, then leaves.
      const target = [CARD_RECT[0] + 620 * SET_SCALE + 6, CARD_RECT[1] + 100 * SET_SCALE + 4]
      const u = ease.easeInOutCubic(prog(T, 52.0, 0.28))
      const x = lerp(target[0] + 120, target[0], u)
      const y = lerp(target[1] + 190, target[1], u)
      const press = T >= 52.3 && T < 52.4 ? 0.88 : 1
      const a = ease.easeOutCubic(prog(T, 51.98, 0.12)) * (1 - prog(T, 52.75, 0.2))
      show(card.pointer, a > 0.001)
      css(card.pointer, { transform: `translate(${x.toFixed(2)}px, ${y.toFixed(2)}px) scale(${press})`, opacity: a.toFixed(3) })
    }
  }
  show(g.bar, barX !== null)
  if (barX !== null) css(g.bar, { transform: `translateX(${(barX - BAR_W / 2).toFixed(2)}px)`, width: `${BAR_W}px`, background: `linear-gradient(${barDir > 0 ? 90 : 270}deg, ${SPECTRUM.join(', ')})` })
}

// ------------------------------------------------------------------ end card icon

export function buildIcon(parent) {
  const root = el('div', 'iconWrap', parent)
  const image = img(root, 'icon')
  setSrc(image, SPRITES.icon_app.src)
  return { root, image }
}

/** Icon bloom: scale k0 -> 1 on spring(0.5, 0.7), opacity over 0.15 s. Returns the current scale. */
export function iconScale(T, t0, k0 = 0.86) {
  return lerp(k0, 1, spring(T - t0, 0.5, 0.7))
}

export function updateIcon(ic, T, t0, cx, cy, size, visible = true) {
  const vis = visible && T >= t0
  show(ic.root, vis)
  if (!vis) return
  const k = iconScale(T, t0)
  const a = prog(T, t0, 0.15)
  css(ic.root, { transform: `translate(${cx - size / 2}px, ${cy - size / 2}px) scale(${k.toFixed(5)})`, width: `${size}px`, height: `${size}px`, opacity: a.toFixed(4) })
  css(ic.image, { width: `${size}px`, height: `${size}px` })
}

// ------------------------------------------------------------------ spectrum transitions

const COL_W = W / 7
const R = COL_W / 2
const COL_H = H + 2 * R + 4

export function buildColumns(parent) {
  const root = el('div', 'columns', parent)
  const cols = SPECTRUM.map((c) => {
    const d = el('div', 'col', root)
    css(d, { background: c })
    return d
  })
  const band = el('div', 'band', parent)
  return { root, cols, band }
}

function drawCols(tc, rects) {
  show(tc.root, !!rects)
  if (!rects) return
  tc.cols.forEach((d, i) => {
    const r = rects[i]
    show(d, !!r && (r.opacity ?? 1) > 0)
    if (!r) return
    css(d, {
      transform: `translate(${r.x.toFixed(3)}px, ${r.y.toFixed(3)}px)`,
      width: `${r.w.toFixed(3)}px`,
      height: `${r.h.toFixed(3)}px`,
      borderRadius: `${r.r.toFixed(3)}px`,
      opacity: (r.opacity ?? 1).toFixed(4)
    })
  })
}

const slotX = (i) => i * COL_W - 1

/** Vertical rise: profile-shaped leading edges, full cover at `cover`. */
function riseRects(T, tr, st = 0.035) {
  const D = tr.cover - tr.start - 6 * st
  return PROFILE.map((p, i) => {
    const inU = prog(T, tr.start + i * st, D)
    const outU = prog(T, tr.cover + i * st, D)
    let top
    if (T < tr.cover) {
      if (inU <= 0) return null
      top = lerp(H, -R - 2, ease.swift(inU)) + (1 - p) * 140 * (1 - inU) * inU * 2
    } else {
      if (outU >= 1) return null
      top = lerp(-R - 2, -COL_H - 160, ease.swift(outU)) + (1 - p) * 140 * outU
    }
    return { x: slotX(i), y: top, w: COL_W + 2, h: COL_H, r: R }
  })
}

function fallRects(T, tr) {
  const r = riseRects(T, tr)
  return r.map((x) => (x ? { ...x, y: H - (x.y + x.h) } : null))
}

/** Horizontal sweep from the left, rightmost column leading, then off to the right. */
function sweepRects(T, tr, st = 0.03) {
  const D = tr.cover - tr.start - 6 * st
  const dist = W + 40
  return PROFILE.map((p, i) => {
    const order = 6 - i
    const inU = prog(T, tr.start + order * st, D)
    const outU = prog(T, tr.cover + order * st, D)
    let x
    if (T < tr.cover) {
      if (inU <= 0) return null
      x = slotX(i) - dist * (1 - ease.swift(inU))
    } else {
      if (outU >= 1) return null
      x = slotX(i) + dist * ease.swift(outU)
    }
    const lag = (1 - p) * 60 * (T < tr.cover ? 1 - inU : outU)
    return { x, y: -R - 2 + lag * 0, w: COL_W + 2, h: COL_H, r: R }
  })
}

/** Columns cover in from below, then contract into the icon's bars. */
function toIconRects(T, tr) {
  const { coverIn, contract, icon } = tr
  if (T < coverIn[0]) return null
  const st = 0.012
  const k = T >= contract[1] ? iconScale(T, contract[1]) : 0.86
  return PROFILE.map((p, i) => {
    const tgt = iconBarRect(i, icon.cx, icon.cy, icon.size, k)
    if (T < contract[0]) {
      const u = prog(T, coverIn[0] + i * st, coverIn[1] - coverIn[0] - 6 * st)
      if (u <= 0) return null
      const top = lerp(H, -R - 2, ease.easeOutCubic(u)) + (1 - p) * 120 * (1 - u)
      return { x: slotX(i), y: top, w: COL_W + 2, h: COL_H, r: R }
    }
    const u = ease.easeInOutCubic(prog(T, contract[0], contract[1] - contract[0]))
    const from = { x: slotX(i), y: -R - 2, w: COL_W + 2, h: COL_H, r: R }
    const fade = 1 - prog(T, contract[1] + 0.02, 0.15)
    if (fade <= 0) return null
    return { x: lerp(from.x, tgt.x, u), y: lerp(from.y, tgt.y, u), w: lerp(from.w, tgt.w, u), h: lerp(from.h, tgt.h, u), r: lerp(from.r, tgt.r, u), opacity: fade }
  })
}

/** One wide spectrum band: leading edge in over the first half, trailing edge out over the second. */
function drawBand(tc, T, tr) {
  const vis = T >= tr.start && T < tr.end
  show(tc.band, vis)
  if (!vis) return
  const half = tr.cover - tr.start
  const lead = W * ease.easeInOutSine(prog(T, tr.start, half))
  const trail = W * ease.easeInOutSine(prog(T, tr.cover, tr.end - tr.cover))
  css(tc.band, { clipPath: `inset(0px ${(W - lead).toFixed(2)}px 0px ${trail.toFixed(2)}px)` })
}

/** Draws whichever transition is active. list: [{kind, start, end, cover, ...}] */
export function updateTransitions(tc, T, list) {
  let rects = null
  let bandTr = null
  for (const tr of list) {
    if (tr.kind === 'single_bar_wipe') {
      if (T >= tr.start && T < tr.end) bandTr = tr
      continue
    }
    if (T < tr.start || T >= tr.end) continue
    if (tr.kind === 'bars_rise') rects = riseRects(T, tr)
    else if (tr.kind === 'bars_fall') rects = fallRects(T, tr)
    else if (tr.kind === 'bars_sweep') rects = sweepRects(T, tr)
    else if (tr.kind === 'bars_to_icon') rects = toIconRects(T, tr)
  }
  drawCols(tc, rects)
  if (bandTr) drawBand(tc, T, bandTr)
  else show(tc.band, false)
}
