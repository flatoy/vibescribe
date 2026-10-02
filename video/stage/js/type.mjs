// Kinetic typography in SF Pro (system-ui). Each text is a row of per-word spans; keycap
// tokens ("Right ⌥", "⌥", "⇧", "⌘") become inline keycaps. Every property is computed from
// the time variable, so any frame renders on its own.
import { clamp, lerp, prog, ease, el, css, show, escapeHtml } from './util.mjs'

const SPECTRUM = ['#6EC6EA', '#7BA3F0', '#9A8AE6', '#C68AEE', '#D884C4', '#EE9A8F', '#EDBB7A']
const KEY_RE = /Right ⌥|Right ⌘|[⌥⇧⌘]|[^\s⌥⇧⌘]+|\s+/g

function tokens(text) {
  return (text.match(KEY_RE) || []).map((s) => ({ s, kc: /^(Right [⌥⌘]|[⌥⇧⌘])$/.test(s), space: /^\s+$/.test(s) }))
}

/**
 * spec: {id, text, style, start, end, position, anchor, size_override, hardCut, after}
 * `after` names a text whose line this one continues ("Let go. It's pasted.").
 */
export function createText(parent, spec) {
  const root = el('div', `txt ${spec.style}`, parent)
  if (spec.size_override) css(root, { fontSize: `${spec.size_override}px` })
  const words = []
  for (const tk of tokens(spec.text)) {
    if (tk.space) {
      root.appendChild(document.createTextNode(tk.s))
      continue
    }
    const w = el('span', tk.kc ? 'w kc' : 'w', root, escapeHtml(tk.s))
    words.push({ node: w, kc: tk.kc })
  }
  show(root, false)
  return { spec, root, words, w: 0, h: 0, left: 0, top: 0 }
}

/** Measures the text box and per-word boxes (call once fonts are ready, while visible). */
export function measureText(item, byId) {
  const r = item.root
  r.style.display = ''
  r.style.transform = 'none'
  item.w = r.offsetWidth
  item.h = r.offsetHeight
  for (const w of item.words) {
    w.x = w.node.offsetLeft
    w.y = w.node.offsetTop
    w.w = w.node.offsetWidth
    w.h = w.node.offsetHeight
  }
  const sp = document.createElement('span')
  sp.textContent = ' '
  r.appendChild(sp)
  item.space = sp.offsetWidth
  r.removeChild(sp)
  r.style.display = 'none'
  r.__shown = false
  const s = item.spec
  const [x, y] = s.position || [72, 738]
  if (s.after && byId[s.after]) {
    const p = byId[s.after]
    item.left = p.left + p.w + p.space
    item.top = p.top
  } else if (s.style === 'caption') {
    item.left = 72
    item.top = 738 - item.h
  } else if (s.anchor === 'left' || s.style === 'chip') {
    item.left = x
    item.top = y - item.h / 2
  } else {
    item.left = x - item.w / 2
    item.top = y - item.h / 2
  }
}

/** Screen-space centre of word `i` of a measured item. */
export const wordCenter = (item, i) => [item.left + item.words[i].x + item.words[i].w / 2, item.top + item.words[i].y + item.words[i].h / 2]

const ENTER = {
  hero_xl: { dur: 0.18 },
  hero: { dur: 0.28, rise: 18, stagger: 0.06, curve: ease.title },
  caption: { dur: 0.22, rise: 10, stagger: 0.05, curve: ease.title },
  caption_center: { dur: 0.24, rise: 14, stagger: 0.04, curve: ease.title },
  sub: { dur: 0.3, rise: 6, stagger: 0, curve: ease.easeOutCubic },
  chip: { dur: 0.22 },
  end_title: { dur: 0.6, rise: 18, blur: 10, stagger: 0, curve: ease.title },
  end_sub: { dur: 0.55, rise: 14, blur: 8, stagger: 0, curve: ease.title },
  end_url: { dur: 0.5, rise: 10, blur: 6, stagger: 0, curve: ease.title }
}
const EXIT = { hero_xl: 0.2, hero: 0.18, caption: 0.2, caption_center: 0.2, sub: 0.18, chip: 0.18 }

/**
 * Draws the item at time T. Options: hideWords (indices to keep invisible), landed (skip the
 * entrance: the item is fully set from its start), extra transform prefix.
 */
export function updateText(item, T, opts = {}) {
  const s = item.spec
  const visible = T >= s.start - 1e-6 && T < s.end
  show(item.root, visible)
  if (!visible) return false
  const en = ENTER[s.style] || ENTER.sub
  const exitDur = s.hardCut ? 0 : EXIT[s.style] ?? 0
  const xu = exitDur > 0 ? prog(T, s.end - exitDur, exitDur) : 0
  const dt = opts.landed ? 10 : T - s.start
  let rootOpacity = 1, rootTx = 0, rootTy = 0, rootScale = 1, rootBlur = 0

  if (s.style === 'hero_xl') {
    const u = prog(dt, 0, en.dur)
    rootScale = lerp(1.18, 1, ease.easeOutBack(u, 1.4))
    rootOpacity = prog(dt, 0, 0.08)
    if (xu > 0) {
      rootBlur = 12 * xu
      rootOpacity *= 1 - xu
    }
  } else if (s.style === 'chip') {
    const u = prog(dt, 0, en.dur)
    rootScale = lerp(0.92, 1, ease.easeOutBack(u, 1.6))
    rootOpacity = ease.easeOutCubic(u)
  } else {
    // Per-word rise; single-block styles use one "word" stagger of 0.
    item.words.forEach((w, i) => {
      if (opts.hideWords && opts.hideWords.includes(i)) return css(w.node, { opacity: '0' })
      const u = prog(dt - i * (en.stagger || 0), 0, en.dur)
      const e = en.curve(u)
      const ty = (en.rise || 0) * (1 - e)
      const blur = en.blur ? en.blur * (1 - e) : 0
      const wa = opts.wordAlpha && opts.wordAlpha[i] !== undefined ? opts.wordAlpha[i] : 1
      css(w.node, {
        opacity: (clamp(u * 1.6) * wa).toFixed(4),
        transform: ty > 0.001 ? `translateY(${ty.toFixed(3)}px)` : 'none',
        filter: blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : 'none'
      })
    })
  }
  if (xu > 0 && s.style !== 'hero_xl') {
    rootOpacity *= 1 - ease.easeInQuad(xu)
    if (s.style === 'caption') rootTy = -6 * ease.easeInQuad(xu)
  }
  const tx = item.left + rootTx + (opts.dx || 0)
  const ty = item.top + rootTy + (opts.dy || 0)
  const sc = rootScale * (opts.scale || 1)
  css(item.root, {
    transform: `translate(${tx.toFixed(3)}px, ${ty.toFixed(3)}px)${Math.abs(sc - 1) > 1e-5 ? ` scale(${sc.toFixed(5)})` : ''}`,
    transformOrigin: opts.origin || '50% 50%',
    opacity: (rootOpacity * (opts.opacity ?? 1)).toFixed(4),
    filter: rootBlur > 0.05 ? `blur(${rootBlur.toFixed(2)}px)` : 'none'
  })
  return true
}

// ------------------------------------------------------------------ spectrum rule

export function createRule(parent, segW = 26, gap = 4, h = 6) {
  const root = el('div', 'rule', parent)
  const segs = SPECTRUM.map((c) => {
    const i = el('i', '', root)
    css(i, { background: c, height: `${h}px`, borderRadius: `${h / 2}px` })
    return i
  })
  show(root, false)
  return { root, segs, segW, gap, h }
}

/** Draws the rule growing left to right (u 0..1) with total width w at (x, y) top-left. */
export function updateRule(rule, x, y, w, u, opacity = 1) {
  show(rule.root, u > 0 && opacity > 0)
  if (u <= 0) return
  const n = rule.segs.length
  const seg = (w - rule.gap * (n - 1)) / n
  css(rule.root, { left: `${x.toFixed(2)}px`, top: `${y.toFixed(2)}px`, opacity: opacity.toFixed(3) })
  rule.segs.forEach((s, i) => {
    const local = clamp(u * (n + 2) / n * 1.0 - i / n * 0.9)
    const e = ease.easeOutCubic(clamp(local * 1.4))
    css(s, { position: 'absolute', left: `${(i * (seg + rule.gap)).toFixed(2)}px`, top: '0px', width: `${Math.max(0, seg * e).toFixed(2)}px`, opacity: clamp(local * 3).toFixed(3) })
  })
}

// ------------------------------------------------------------------ ticker

export function createTicker(parent, names, rect) {
  const root = el('div', 'ticker', parent)
  const [x, y, w, h] = rect
  css(root, { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px` })
  const strip = el('span', '', root, names.map(escapeHtml).join('<b>·</b>') + '<b>·</b>' + names.map(escapeHtml).join('<b>·</b>'))
  return { root, strip }
}

export function updateTicker(tk, T, t0, visible, opacity) {
  show(tk.root, visible)
  if (!visible) return
  const x = -(T - t0) * 120
  css(tk.strip, { transform: `translateX(${x.toFixed(2)}px)` })
  css(tk.root, { opacity: opacity.toFixed(3) })
}

// ------------------------------------------------------------------ caption scrim

export function updateScrim(node, items, T) {
  let a = 0
  for (const it of items) {
    const s = it.spec
    if (s.style !== 'caption') continue
    const inU = prog(T, s.start - 0.12, 0.25)
    const outU = s.hardCut ? (T >= s.end ? 1 : 0) : prog(T, s.end - 0.1, 0.25)
    a = Math.max(a, inU * (1 - outU))
  }
  show(node, a > 0.001)
  css(node, { opacity: ease.easeInOutSine(a).toFixed(4) })
}

// ------------------------------------------------------------------ caption plates

/**
 * Frosted plates behind bottom-left captions, so a caption stays legible over window content
 * during punch-ins. A caption continued by an `after` caption ("Let go." + "It's pasted.")
 * shares one plate that widens when the second part arrives.
 */
export function createPlates(parent, items) {
  const plates = []
  for (const it of items) {
    if (it.spec.style !== 'caption' || it.spec.after) continue
    const tail = items.find((o) => o.spec.after === it.spec.id)
    const node = el('div', 'capPlate', parent)
    show(node, false)
    plates.push({ node, item: it, tail })
  }
  return plates
}

export function updatePlates(plates, T) {
  const PX = 20, PY = 9
  for (const p of plates) {
    const s = p.item.spec
    const end = p.tail ? p.tail.spec.end : s.end
    const hard = p.tail ? p.tail.spec.hardCut : s.hardCut
    const inU = ease.easeOutCubic(prog(T, s.start - 0.06, 0.22))
    const outU = hard ? (T >= end ? 1 : 0) : ease.easeInQuad(prog(T, end - 0.2, 0.2))
    const a = inU * (1 - outU)
    show(p.node, a > 0.001)
    if (a <= 0.001) continue
    let w = p.item.w
    if (p.tail && T >= p.tail.spec.start) w += (p.tail.space + p.tail.w) * ease.title(prog(T, p.tail.spec.start - 0.04, 0.26))
    const x = p.item.left - PX, y = p.item.top - PY + (s.style === 'caption' ? -6 * outU : 0)
    css(p.node, {
      transform: `translate(${x.toFixed(2)}px, ${y.toFixed(2)}px) scale(${lerp(0.97, 1, inU).toFixed(4)})`,
      width: `${(w + 2 * PX).toFixed(2)}px`,
      height: `${(p.item.h + 2 * PY).toFixed(2)}px`,
      opacity: a.toFixed(4)
    })
  }
}
