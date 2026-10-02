// Pure maths for the stage: easing, springs, key interpolation. Everything is a function of
// time, so any frame can be rendered on its own, in any order, by any worker.

export const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x))
export const lerp = (a, b, u) => a + (b - a) * u
export const unlerp = (a, b, x) => (b === a ? (x >= b ? 1 : 0) : clamp((x - a) / (b - a)))
export const mix = lerp

/** Progress of `t` through [start, start + dur], clamped to 0..1. */
export const prog = (t, start, dur) => (dur <= 0 ? (t >= start ? 1 : 0) : clamp((t - start) / dur))

export const ease = {
  linear: (u) => u,
  easeInQuad: (u) => u * u,
  easeOutQuad: (u) => 1 - (1 - u) * (1 - u),
  easeInCubic: (u) => u * u * u,
  easeOutCubic: (u) => 1 - Math.pow(1 - u, 3),
  easeInOutCubic: (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2),
  easeInOutSine: (u) => -(Math.cos(Math.PI * u) - 1) / 2,
  easeOutSine: (u) => Math.sin((u * Math.PI) / 2),
  easeInSine: (u) => 1 - Math.cos((u * Math.PI) / 2),
  easeOutQuart: (u) => 1 - Math.pow(1 - u, 4),
  easeInQuart: (u) => u * u * u * u,
  easeOutQuint: (u) => 1 - Math.pow(1 - u, 5),
  easeInOutQuint: (u) => (u < 0.5 ? 16 * u ** 5 : 1 - Math.pow(-2 * u + 2, 5) / 2),
  easeInOutExpo: (u) => (u <= 0 ? 0 : u >= 1 ? 1 : u < 0.5 ? Math.pow(2, 20 * u - 10) / 2 : (2 - Math.pow(2, -20 * u + 10)) / 2),
  easeOutExpo: (u) => (u >= 1 ? 1 : 1 - Math.pow(2, -10 * u)),
  easeOutBack: (u, s = 1.70158) => 1 + (s + 1) * Math.pow(u - 1, 3) + s * Math.pow(u - 1, 2),
  easeInBack: (u, s = 1.70158) => (s + 1) * u * u * u - s * u * u,
  whip: (u) => ease.easeInOutExpo(u)
}

/** CSS-style cubic-bezier(x1, y1, x2, y2), solved with Newton steps. */
export function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
  const sx = (t) => ((ax * t + bx) * t + cx) * t
  const sy = (t) => ((ay * t + by) * t + cy) * t
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx
  return (u) => {
    if (u <= 0) return 0
    if (u >= 1) return 1
    let t = u
    for (let i = 0; i < 8; i++) {
      const e = sx(t) - u
      const d = dx(t)
      if (Math.abs(e) < 1e-6 || Math.abs(d) < 1e-6) break
      t -= e / d
    }
    return sy(clamp(t))
  }
}

// House curves for type: a fast, confident settle (like Apple keynote titles).
ease.title = bezier(0.16, 1, 0.3, 1)
ease.settle = bezier(0.22, 1, 0.36, 1)
ease.swift = bezier(0.65, 0, 0.35, 1)

/**
 * SwiftUI spring(response, dampingFraction) step response from 0 to 1 at time `t` seconds
 * after the change. Under-damped springs overshoot; callers clamp what must not.
 */
export function spring(t, response = 0.38, damping = 0.78) {
  if (t <= 0) return 0
  const w0 = (2 * Math.PI) / response
  if (damping >= 1) {
    return 1 - Math.exp(-w0 * t) * (1 + w0 * t)
  }
  const wd = w0 * Math.sqrt(1 - damping * damping)
  const a = damping * w0
  return 1 - Math.exp(-a * t) * (Math.cos(wd * t) + (a / wd) * Math.sin(wd * t))
}

/** Interpolates camera-style keys [{t, ..., ease}] where each key's ease shapes the move into it. */
export function sampleKeys(keys, t, fields) {
  if (t <= keys[0].t) return pick(keys[0], fields)
  const last = keys[keys.length - 1]
  if (t >= last.t) return pick(last, fields)
  let i = 0
  while (i < keys.length - 2 && t >= keys[i + 1].t) i++
  const a = keys[i], b = keys[i + 1]
  const u = (ease[b.ease] || ease.linear)(unlerp(a.t, b.t, t))
  const out = {}
  for (const f of fields) {
    if (f === 's') out.s = Math.exp(lerp(Math.log(a.s), Math.log(b.s), u))
    else out[f] = lerp(a[f], b[f], u)
  }
  out.ease = b.ease
  out.u = u
  return out
}

function pick(k, fields) {
  const out = {}
  for (const f of fields) out[f] = k[f]
  return out
}

/** Deterministic hash noise in [0, 1). */
export function hash(n) {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453
  return x - Math.floor(x)
}

export const px = (v) => `${Math.round(v * 1000) / 1000}px`

export function el(tag, cls, parent, html) {
  const node = document.createElement(tag)
  if (cls) node.className = cls
  if (html !== undefined) node.innerHTML = html
  if (parent) parent.appendChild(node)
  return node
}

/** Sets style properties only when they change, to keep layout work per frame small. */
export function css(node, props) {
  const cache = node.__css || (node.__css = {})
  for (const k in props) {
    const v = props[k]
    if (cache[k] !== v) {
      cache[k] = v
      node.style[k] = v
    }
  }
}

export function show(node, visible) {
  if (node.__shown !== visible) {
    node.__shown = visible
    node.style.display = visible ? '' : 'none'
  }
}

export function setText(node, text) {
  if (node.__text !== text) {
    node.__text = text
    node.textContent = text
  }
}

export function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
}
