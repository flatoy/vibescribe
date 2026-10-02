// World-space pieces: wallpaper, menu bar with the VibeScribe status item, the generic host
// windows (mail, terminal, chat, notes), the overlay pill, the language picker and the pointer.
// Everything here zooms with the camera. Apps are generic mock-ups: no third-party chrome.
import { clamp, lerp, prog, ease, spring, el, css, show, setText, escapeHtml } from './util.mjs'
import { SPRITES, SEQ, img, setSrc, seqSrc, placeSprite } from './assets.mjs'

const W = 1440
const H = 810
const BLINK = 0.53

/** Caret blink that restarts (solid) whenever the caret moves at `since`. */
export const blinkOn = (t, since = 0) => Math.floor(Math.max(0, t - since) / BLINK) % 2 === 0

// ------------------------------------------------------------------ wallpaper

export function buildWallpaper(parent) {
  const root = el('div', 'wallpaper', parent)
  const paint = el('div', 'paint', root)
  const evening = el('div', 'wpEvening', root)
  const dim = el('div', 'wpDim', root)
  return { root, paint, evening, dim }
}

export function updateWallpaper(wp, { blur = 0, dim = 0, evening = 0 }) {
  css(wp.root, { filter: blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : 'none' })
  css(wp.dim, { opacity: dim.toFixed(4) })
  css(wp.evening, { opacity: evening.toFixed(4) })
}

// ------------------------------------------------------------------ menu bar

export function buildMenubar(parent) {
  const root = el('div', 'menubar', parent)
  const left = el('div', 'left', root)
  const apple = img(left, 'apple')
  setSrc(apple, SPRITES.glyph_apple_logo.src)
  css(apple, { width: '13px', height: '16px' })
  const app = el('span', 'app', left)
  const menus = el('span', 'menus', left)
  const right = el('div', 'right', root)
  const clock = el('span', 'clock', right)
  const battery = img(right, 'battery')
  setSrc(battery, SPRITES.glyph_battery_75.src)
  const wifi = img(right, 'wifi')
  const si = el('div', 'si', right)
  const siIdleA = img(si, 'idleA')
  const siIdleB = img(si, 'idleB')
  const siSeq = img(si, 'seq')
  const measure = el('span', 'clock measure', root)
  return { root, left, apple, app, menus, right, clock, battery, wifi, si, siIdleA, siIdleB, siSeq, measure, widths: {}, menuKey: null }
}

function clockWidth(mb, text) {
  if (!(text in mb.widths)) {
    const hidden = mb.root.style.display === 'none'
    if (hidden) mb.root.style.display = ''
    mb.measure.textContent = text
    mb.widths[text] = mb.measure.offsetWidth
    if (hidden) mb.root.style.display = 'none'
  }
  return mb.widths[text]
}

/** Right-hand layout like StoreMenuBar: clock, 16, battery, 16, wifi, 14, status item. */
export function menubarLayout(mb, clockText) {
  const clockRight = W - 18
  const clockLeft = clockRight - clockWidth(mb, clockText)
  const batteryRight = clockLeft - 16
  const batteryLeft = batteryRight - 22.5
  const wifiRight = batteryLeft - 16
  const wifiLeft = wifiRight - 17
  const siRight = wifiLeft - 14
  return { clockLeft, batteryLeft, wifiLeft, wifiCenter: [wifiLeft + 8.5, 13], siRight, batteryCenter: [batteryLeft + 11.25, 13] }
}

/** Status item: idle (waveform + badge), recording (bars + timer) or transcribing (thinking bars + badge). */
export function updateMenubar(mb, T, cfg) {
  show(mb.root, cfg.visible)
  if (!cfg.visible) return null
  css(mb.root, { transform: `translateY(${cfg.y.toFixed(3)}px)` })
  const key = `${cfg.app}|${cfg.menus.join(',')}`
  if (mb.menuKey !== key) {
    mb.menuKey = key
    mb.app.textContent = cfg.app || ''
    mb.menus.innerHTML = cfg.menus.map((m) => `<span class="menu">${escapeHtml(m)}</span>`).join('')
    show(mb.app, !!cfg.app)
    // World x of each left-hand item (the .left box starts at x 18).
    mb.items = [mb.apple, mb.app, ...mb.menus.children].map((n) => ({ n, x: 18 + n.offsetLeft }))
  }
  // A punch-in crops the menu bar at the frame edges. Rather than leave a sliver of a word ("ll" of
  // "Shell") or half a glyph, an item (never the status item) fades out as the edge reaches it, so the crop always lands in
  // a gap. viewLeft/viewRight are the camera's world x at the frame's left and right edges.
  const vl = cfg.viewLeft ?? 0
  const vr = cfg.viewRight ?? W
  for (const it of mb.items) css(it.n, { opacity: clamp((it.x - vl) / 10).toFixed(3) })
  const L = menubarLayout(mb, cfg.clock)
  const edge = (right) => clamp((vr - right) / 10).toFixed(3)
  css(mb.clock, { opacity: edge(W - 18) })
  css(mb.battery, { opacity: edge(L.batteryLeft + 22.5) })
  css(mb.wifi, { opacity: edge(L.wifiLeft + 17) })
  setText(mb.clock, cfg.clock)
  css(mb.clock, { left: `${L.clockLeft}px` })
  css(mb.battery, { left: `${L.batteryLeft - 0.25}px`, top: '7.5px', width: '23px', height: '11px' })
  const wifiMeta = cfg.wifi === 'wifi.slash' ? SPRITES.glyph_wifi_slash : SPRITES.glyph_wifi
  setSrc(mb.wifi, wifiMeta.src)
  css(mb.wifi, { left: `${L.wifiLeft}px`, top: `${13 - wifiMeta.size_pt[1] / 2}px`, width: `${wifiMeta.size_pt[0]}px`, height: `${wifiMeta.size_pt[1]}px` })

  // Status item, right-aligned at siRight like a real NSStatusItem.
  const st = cfg.status
  const placeRight = (node, meta, opacity, filter = 'none') => {
    const [cx0, , cw] = meta.content_rect_pt
    const cxCenter = L.siRight - cw / 2
    placeSprite(node, meta, cxCenter + (meta.anchor_pt[0] - (cx0 + cw / 2)), 13)
    css(node, { opacity: opacity.toFixed(4), filter })
    show(node, opacity > 0.001)
    return cxCenter - cw / 2
  }
  let glyphLeft = L.siRight - 33.5
  if (st.kind === 'idle') {
    show(mb.siSeq, false)
    const metaA = SPRITES[`statusitem_idle_${st.badge}`]
    if (st.from && st.fade < 1) {
      const metaB = SPRITES[`statusitem_idle_${st.from}`]
      setSrc(mb.siIdleB, metaB.src)
      placeRight(mb.siIdleB, metaB, 1 - st.fade)
    } else show(mb.siIdleB, false)
    setSrc(mb.siIdleA, metaA.src)
    const glow = st.glow > 0 ? `drop-shadow(0 0 ${(4 * st.glow).toFixed(2)}px rgba(255,255,255,${(0.9 * st.glow).toFixed(3)}))` : 'none'
    glyphLeft = placeRight(mb.siIdleA, metaA, (st.from ? st.fade : 1) * (st.opacity ?? 1), glow)
  } else {
    show(mb.siIdleA, false)
    show(mb.siIdleB, false)
    setSrc(mb.siSeq, seqSrc(st.layer, st.index))
    glyphLeft = placeRight(mb.siSeq, st.layer, 1)
  }
  return { ...L, glyphCenter: [glyphLeft + 7.75, 13] }
}

// ------------------------------------------------------------------ windows

function windowShell(parent, cls, rect, title, titlebarHeight = 38) {
  const [x, y, w, h] = rect
  const root = el('div', `win ${cls}`, parent)
  css(root, { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px` })
  const bar = el('div', 'titlebar', root)
  css(bar, { height: `${titlebarHeight}px` })
  const lights = el('div', 'lights', bar)
  css(lights, { top: `${(titlebarHeight - 12) / 2}px` })
  for (const c of ['#FF5F57', '#FEBC2E', '#28C840']) css(el('i', '', lights), { background: c })
  const t = el('div', 'title', bar, escapeHtml(title))
  css(t, { lineHeight: `${titlebarHeight}px` })
  return { root, bar, x, y, w, h }
}

export function buildMail(parent, scene) {
  const win = scene.windows[0]
  const c = win.content
  const s = windowShell(parent, 'mail', win.rect, win.title)
  const send = el('div', 'send', s.bar, 'Send')
  for (const f of c.fields) {
    const row = el('div', 'field', s.root, `<b>${escapeHtml(f.label)}</b>${f.label === 'To:' ? `<span class="chipName">${escapeHtml(f.value)}</span>` : escapeHtml(f.value)}`)
    css(row, { top: `${f.y}px` })
  }
  const bx = c.body_origin[0] - s.x, by = c.body_origin[1] - s.y
  const glow = el('div', 'glow', s.root)
  const body = el('div', 'body', s.root)
  css(body, { left: `${bx}px`, top: `${by}px`, width: `${s.w - bx - 24}px` })
  const caret = el('div', 'caret', s.root)
  const quote = el('div', 'quote', s.root, c.quote.map(escapeHtml).join('\n'))
  css(quote, { left: `${c.quote_origin[0] - s.x}px`, top: `${c.quote_origin[1] - s.y}px` })
  // Measure where the pasted run ends (built before any camera transform, so 1 unit = 1 px).
  body.textContent = c.paste.text
  const range = document.createRange()
  range.selectNodeContents(body)
  const rects = [...range.getClientRects()]
  const box = s.root.getBoundingClientRect()
  const last = rects[rects.length - 1]
  const lines = new Set(rects.map((r) => Math.round(r.top))).size
  const endPos = [last.right - box.left, last.top - box.top]
  const runRect = [bx - 4, by - 1, Math.max(...rects.map((r) => r.right)) - box.left - bx + 8, lines * 21 + 2]
  body.textContent = ''
  return { ...s, kind: 'mail', send, body, caret, glow, quote, bx, by, paste: c.paste, endPos, runRect }
}

export function updateMail(m, T, scene) {
  const pasted = T >= m.paste.t
  setText(m.body, pasted ? m.paste.text : '')
  // Caret: at the body start until the paste, then at the end of the pasted run.
  let cx = m.bx, cy = m.by
  if (pasted) {
    ;[cx, cy] = m.endPos
    cx += 1
  }
  css(m.caret, { left: `${cx}px`, top: `${(pasted ? cy : m.by) + 2}px`, height: '17px' })
  show(m.caret, blinkOn(T, pasted ? m.paste.t : 0) && T < 14.9)
  // Text-land glow: white 18% -> 0 over 0.25 s behind the inserted run.
  const g = pasted ? 1 - prog(T, m.paste.t, 0.25) : 0
  show(m.glow, g > 0)
  if (g > 0 && m.runRect) {
    const [x, y, w, h] = m.runRect
    css(m.glow, { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px`, background: `rgba(255,255,255,${(0.18 * ease.easeOutQuad(g)).toFixed(3)})` })
  }
  // Send button press at 14.9.
  const press = T >= 14.9 && T < 15.02
  css(m.send, { filter: press ? 'brightness(0.82)' : 'none', transform: press ? 'scale(0.96)' : 'none' })
  // Window out at 15.0: scale 0.96 + fade over 0.3 s, as if sent.
  const ev = scene.events.find((e) => e.type === 'window_out')
  const u = ev ? ease.easeInOutCubic(prog(T, ev.t, ev.duration)) : 0
  const fadeIn = ease.easeOutCubic(prog(T, 3.7, 0.3))
  css(m.root, { opacity: (fadeIn * (1 - u)).toFixed(4), transform: `scale(${(1 - 0.04 * u).toFixed(4)})` })
}

export function buildTerminal(parent, scene) {
  const win = scene.windows[0]
  const c = win.content
  // The terminal is narrower than the spec rect so the pasted prompt wraps and stays in frame
  // during the 1.75x punch-in; the origin keeps the same inset from the window edge.
  const rect = [330, 96, 780, 540]
  const s = windowShell(parent, 'term', rect, win.title, 30)
  const lines = el('div', 'lines', s.root)
  css(lines, { left: '16px', top: '42px', width: `${rect[2] - 32}px` })
  const html = c.lines.slice(0, -1).map((l) => termLine(l.text, l.style)).join('')
  const fixed = el('div', 'fixed', lines, html)
  const input = el('div', 'line input', lines)
  const after = el('div', 'after', lines)
  return { ...s, kind: 'term', lines, fixed, input, after, c }
}

function termLine(text, style) {
  if (!text) return '<div class="line"> </div>'
  let h = escapeHtml(text)
  if (style === 'prompt') h = h.replace(/^❯/, '<span style="color:#6EC6EA">❯</span>')
  if (style === 'input') h = h.replace(/^›/, '<span style="color:#9A8AE6">›</span>')
  if (style === 'agent') h = h.replace(/^◇/, '<span style="color:#C68AEE">◇</span>')
  return `<div class="line ${style}">${h}</div>`
}

const SPINNER = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

export function updateTerminal(m, T) {
  const paste = m.c.paste
  const enter = m.c.enter.t
  const pasted = T >= paste.t
  const sent = T >= enter
  const caret = !sent && blinkOn(T, pasted ? paste.t : 0)
  const key = `${pasted}|${sent}|${caret}`
  if (m.inputKey !== key) {
    m.inputKey = key
    const text = pasted ? escapeHtml(paste.text) : ''
    m.input.innerHTML = `<span style="color:#9A8AE6">›</span> ${text}${caret ? '<span class="block"></span>' : sent ? '' : '<span class="block off"></span>'}`
    css(m.input, { color: sent ? 'rgba(255,255,255,0.7)' : '#fff' })
  }
  let html = ''
  if (sent) {
    html += '<div class="line"> </div>'
    for (const a of m.c.agent_output) {
      if (T < a.t) continue
      let text = a.text
      if (a.spinner) {
        const i = Math.floor((T - a.t) * 12) % SPINNER.length
        html += `<div class="line agent"><span style="color:#C68AEE">${SPINNER[i]}</span>${escapeHtml(text.slice(1))}</div>`
      } else html += termLine(text, 'agent')
    }
  }
  if (m.afterHtml !== html) {
    m.afterHtml = html
    m.after.innerHTML = html
  }
}

export function buildChat(parent, scene) {
  const win = scene.windows[0]
  const c = win.content
  const s = windowShell(parent, 'chat', win.rect, '', 56)
  const head = el('div', 'head', s.bar, `<div class="avatar">LF</div><div><div class="name">Lena Fischer</div><div class="status">Active now</div></div>`)
  const stamp = el('div', 'stamp', s.root, 'Today 16:02')
  css(stamp, { top: '70px' })
  const [m1, mine, typing, reply] = c.messages
  const b1 = el('div', 'bubble left', s.root, escapeHtml(m1.text))
  css(b1, { left: '18px', top: '94px' })
  const b2 = el('div', 'bubble right', s.root, escapeHtml(mine.text))
  css(b2, { right: '18px', top: '150px' })
  const dots = el('div', 'typing', s.root, '<i></i><i></i><i></i>')
  css(dots, { left: '18px', top: '204px' })
  const b3 = el('div', 'bubble left', s.root, escapeHtml(reply.text))
  css(b3, { left: '18px', top: '204px' })
  const [cx, cy, cw, ch] = c.composer.rect_world
  const comp = el('div', 'composer', s.root)
  css(comp, { left: `${cx - s.x}px`, top: `${cy - s.y}px`, width: `${cw}px`, height: `${ch}px` })
  const ph = el('div', 'ph', comp, escapeHtml(c.composer.placeholder))
  const txt = el('div', 'ctext', comp, escapeHtml(c.composer.paste.text))
  const caret = el('div', 'caret', comp)
  el('div', 'sendbtn', comp)
  const txtW = txt.offsetWidth
  return { ...s, kind: 'chat', b1, b2, b3, dots, comp, ph, txt, caret, msgs: c.messages, paste: c.composer.paste, txtW }
}

export function updateChat(m, T) {
  const [m1, mine, typing, reply] = m.msgs
  const pop = (node, t0) => {
    const u = prog(T, t0, 0.2)
    show(node, T >= t0)
    if (T >= t0) css(node, { opacity: ease.easeOutCubic(clamp(u * 1.6)).toFixed(4), transform: `scale(${(0.9 + 0.1 * ease.easeOutBack(u)).toFixed(4)})` })
  }
  pop(m.b1, m1.t)
  const pasted = T >= m.paste.t
  const sentT = mine.t
  // Composer: placeholder + caret, then the pasted text, then it flies into the bubble.
  show(m.ph, !pasted || T >= sentT)
  show(m.txt, pasted && T < sentT)
  const caretX = pasted && T < sentT ? 16 + m.txtW + 1 : 16
  css(m.caret, { left: `${caretX}px`, top: '11px', height: '18px' })
  show(m.caret, blinkOn(T, pasted ? m.paste.t : 0))
  if (pasted && T < sentT) {
    const g = 1 - prog(T, m.paste.t, 0.25)
    css(m.txt, { background: g > 0 ? `rgba(255,255,255,${(0.18 * g).toFixed(3)})` : 'transparent' })
  }
  // The sent bubble flies from the composer to its slot over 0.25 s.
  show(m.b2, T >= sentT)
  if (T >= sentT) {
    const u = ease.easeOutCubic(prog(T, sentT, 0.25))
    const dy = lerp(388 - 150 + 2, 0, u)
    css(m.b2, { transform: `translateY(${dy.toFixed(2)}px) scale(${lerp(0.94, 1, u).toFixed(4)})`, opacity: clamp(u * 3).toFixed(3) })
  }
  const tStart = typing.typing_indicator[0], tEnd = typing.typing_indicator[1]
  show(m.dots, T >= tStart && T < tEnd)
  if (T >= tStart && T < tEnd) {
    const kids = m.dots.children
    for (let i = 0; i < 3; i++) {
      const phase = (T - tStart) * 5 - i * 0.33
      const a = 0.35 + 0.55 * Math.max(0, Math.sin(phase * Math.PI))
      css(kids[i], { left: `${14 + i * 12}px`, opacity: a.toFixed(3) })
    }
    css(m.dots, { opacity: ease.easeOutCubic(prog(T, tStart, 0.12)).toFixed(3) })
  }
  pop(m.b3, reply.t)
}

export function buildNotes(parent, scene) {
  const win = scene.windows[0]
  const c = win.content
  const s = windowShell(parent, 'notes', win.rect, '')
  const stamp = el('div', 'stamp', s.root, 'Thursday 19:46')
  css(stamp, { top: '48px' })
  const ox = 432 - s.x, oy = 160 - s.y
  const lines = el('div', 'lines', s.root)
  css(lines, { left: `${ox}px`, top: `${oy + 14}px`, width: `${s.w - ox - 28}px` })
  const title = el('div', 'h', lines, escapeHtml(c.lines[0]))
  const l1 = el('div', 'l', lines, escapeHtml(c.lines[1]))
  const l2 = el('div', 'l', lines)
  const bullet = el('span', '', l2, '•  ')
  const run = el('span', 'run', l2)
  const caret = el('span', 'caretInline', l2)
  return { ...s, kind: 'notes', lines, l2, run, caret, paste: c.paste }
}

export function updateNotes(m, T) {
  const pasted = T >= m.paste.t
  setText(m.run, pasted ? m.paste.text : '')
  css(m.caret, { visibility: blinkOn(T, pasted ? m.paste.t : 0) ? 'visible' : 'hidden' })
  const g = pasted ? 1 - prog(T, m.paste.t, 0.25) : 0
  css(m.run, { background: g > 0 ? `rgba(255,255,255,${(0.18 * g).toFixed(3)})` : 'transparent' })
}

// ------------------------------------------------------------------ overlay pill

export function buildPill(parent) {
  const root = el('div', 'pill', parent)
  const mk = () => {
    const slot = el('div', 'slot', root)
    const plate = img(slot, 'plate')
    const bars = img(slot, 'bars')
    return { slot, plate, bars }
  }
  return { root, a: mk(), b: mk() }
}

/** The pill state for loop `L` at time T: {kind, plate meta/src, bars src, width}. */
function pillPhase(L, kind, T) {
  const seq = SEQ[L.key]
  if (kind === 'listening' || kind === 'handsfree') {
    const i = Math.floor((T - L.rec_start) * 60 + 1e-6)
    const layer = seq.bars
    const idx = clamp(i, 0, layer.frames - 1)
    const timer = layer.per_frame[idx]?.timer || '0:00'
    let n = parseInt(timer.split(':')[1], 10)
    let id = `pill_${kind}_t${n}`
    while (!SPRITES[id] && n > 0) id = `pill_${kind}_t${--n}`
    const meta = SPRITES[id]
    return { meta, src: meta.src, bars: seqSrc(layer, idx), width: meta.content_rect_pt[2] }
  }
  if (kind === 'transcribing') {
    const layer = seq.transcribing
    const i = Math.floor((T - L.stop) * 60 + 1e-6)
    return { meta: layer, src: seqSrc(layer, i), bars: null, width: layer.content_rect_pt[2] }
  }
  const meta = SPRITES[`pill_pasted_${L.words}`]
  return { meta, src: meta.src, bars: null, width: meta.content_rect_pt[2] }
}

function phasesOf(L) {
  const list = [{ t: L.rec_start, kind: 'listening' }]
  if (L.hands_free) list.push({ t: L.hands_free, kind: 'handsfree' })
  list.push({ t: L.stop, kind: 'transcribing' }, { t: L.pasted, kind: 'pasted' }, { t: L.hidden, kind: 'hidden' })
  return list
}

function drawSlot(s, ph, opacity, scaleX) {
  show(s.slot, opacity > 0.001)
  if (opacity <= 0.001) return
  setSrc(s.plate, ph.src)
  placeSprite(s.plate, ph.meta, 0, 0)
  if (ph.bars) {
    setSrc(s.bars, ph.bars)
    show(s.bars, true)
    css(s.bars, { left: `${-ph.width / 2 + 11}px`, top: '7px', width: '37px', height: '20px' })
  } else show(s.bars, false)
  css(s.slot, { opacity: opacity.toFixed(4), transform: `scaleX(${scaleX.toFixed(5)})` })
}

export function updatePill(p, T, loops, place = { x: 720, y: 42, scale: 1 }) {
  const L = loops.find((l) => T >= l.rec_start && T < l.hidden + 0.6)
  show(p.root, !!L)
  if (!L) return
  const phases = phasesOf(L)
  let ci = 0
  while (ci < phases.length - 1 && T >= phases[ci + 1].t) ci++
  const cur = phases[ci]
  // Enter on the spring, anchored at the top.
  const ue = spring(T - L.rec_start, 0.38, 0.78)
  let opacity = clamp(ue)
  let scale = 0.8 + 0.2 * ue
  let y = -12 * (1 - ue)
  if (cur.kind === 'hidden') {
    const ux = spring(T - L.hidden, 0.38, 0.78)
    opacity = clamp(1 - ux)
    y = -8 * ux
    scale = 1
  }
  css(p.root, { transform: `translate(${place.x}px, ${(place.y + y).toFixed(3)}px) scale(${(scale * place.scale).toFixed(5)})`, opacity: opacity.toFixed(4) })
  const shown = cur.kind === 'hidden' ? phases[ci - 1] : cur
  const curPh = pillPhase(L, shown.kind, T)
  const prev = cur.kind === 'hidden' ? null : phases[ci - 1]
  const dt = T - cur.t
  if (prev && dt < 0.45) {
    const prevPh = pillPhase(L, prev.kind, T)
    const u = clamp(spring(dt, 0.38, 0.78), 0, 1.2)
    const w = lerp(prevPh.width, curPh.width, u)
    const f = ease.easeInOutSine(prog(dt, 0, 0.22))
    drawSlot(p.b, prevPh, 1 - f, w / prevPh.width)
    drawSlot(p.a, curPh, f, w / curPh.width)
  } else {
    drawSlot(p.b, curPh, 0, 1)
    drawSlot(p.a, curPh, 1, 1)
  }
}

/** A lone sprite pill (the preview slate's "Pasted 6 words"). */
export function updateStaticPill(p, id, T, t0, place) {
  const meta = SPRITES[id]
  const u = spring(T - t0, 0.38, 0.78)
  show(p.root, T >= t0)
  if (T < t0) return
  css(p.root, { transform: `translate(${place.x}px, ${(place.y - 12 * place.scale * (1 - u)).toFixed(3)}px) scale(${(place.scale * (0.8 + 0.2 * u)).toFixed(5)})`, opacity: clamp(u).toFixed(4) })
  drawSlot(p.b, { meta, src: meta.src, width: meta.content_rect_pt[2] }, 0, 1)
  drawSlot(p.a, { meta, src: meta.src, width: meta.content_rect_pt[2] }, 1, 1)
}

// ------------------------------------------------------------------ language picker

export function buildPicker(parent) {
  const root = el('div', 'picker', parent)
  const shadow = el('div', 'pshadow', root)
  const image = img(root, '')
  const caret = el('div', 'caret', root)
  return { root, shadow, image, caret }
}

export function updatePicker(pk, T, scene) {
  const p = scene?.picker
  if (!p || T < p.open || T >= p.exit[1]) return show(pk.root, false)
  show(pk.root, true)
  let top = 106, alpha = 1
  if (T < p.slide[1]) {
    const u = ease.easeOutCubic(prog(T, p.slide[0], p.slide[1] - p.slide[0]))
    top = lerp(-358, 106, u)
    alpha = u
  }
  if (T >= p.exit[0]) {
    const u = ease.easeInQuad(prog(T, p.exit[0], p.exit[1] - p.exit[0]))
    top = 106 - 16 * u
    alpha = 1 - u
  }
  let state = p.states[0]
  for (const s of p.states) if (T >= s.t) state = s
  const meta = SPRITES[state.sprite]
  setSrc(pk.image, meta.src)
  css(pk.root, { left: `${720 - 190}px`, top: `${top.toFixed(3)}px`, opacity: alpha.toFixed(4) })
  const c = meta.caret_rect_pt
  if (c) {
    css(pk.caret, { left: `${c[0]}px`, top: `${c[1]}px`, width: `${c[2]}px`, height: `${c[3]}px` })
    show(pk.caret, blinkOn(T, state.t))
  } else show(pk.caret, false)
}

// ------------------------------------------------------------------ pointer and rings

const ARROW = `<svg viewBox="0 0 18 26" width="18" height="26"><path d="M1.5 1.5 L1.5 20.5 L6.2 16.2 L9.4 23.6 L12.6 22.2 L9.5 15 L15.8 15 Z" fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>`

export function buildPointer(parent) {
  const root = el('div', 'pointer', parent, ARROW)
  return { root }
}

export function updatePointer(pt, s) {
  show(pt.root, !!s)
  if (!s) return
  css(pt.root, { transform: `translate(${s.x.toFixed(2)}px, ${s.y.toFixed(2)}px) scale(${(s.scale ?? 1).toFixed(4)})`, opacity: (s.opacity ?? 1).toFixed(3) })
}

export function buildRings(parent) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  svg.setAttribute('class', 'rings')
  svg.setAttribute('width', String(W))
  svg.setAttribute('height', String(H))
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`)
  parent.appendChild(svg)
  const circles = [0, 1].map(() => {
    const c = document.createElementNS('http://www.w3.org/2000/svg', 'circle')
    c.setAttribute('fill', 'none')
    c.setAttribute('stroke', '#6EC6EA')
    svg.appendChild(c)
    return c
  })
  return { svg, circles }
}

export function updateRings(r, T, spec, center) {
  let any = false
  r.circles.forEach((c, i) => {
    const t0 = spec ? spec.t + i * (spec.duration + spec.gap) : 0
    const u = spec ? (T - t0) / spec.duration : -1
    if (u < 0 || u > 1) return c.setAttribute('opacity', '0')
    any = true
    const e = ease.easeOutCubic(u)
    c.setAttribute('cx', String(center[0]))
    c.setAttribute('cy', String(center[1]))
    c.setAttribute('r', (lerp(spec.radius[0], spec.radius[1], e)).toFixed(3))
    c.setAttribute('stroke-width', String(spec.stroke * (1 - 0.5 * e)))
    c.setAttribute('opacity', (Math.min(1, u * 8) * (1 - ease.easeInQuad(u))).toFixed(3))
  })
  show(r.svg, any)
}
