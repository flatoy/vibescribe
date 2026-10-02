// Sprites and per-frame sequences rendered from the app's real SwiftUI views
// (Tools/VibeScribeVideoFrames). Static sprites are decoded once; sequence frames are
// swapped per frame and awaited before the screenshot, so no frame shows a stale image.
import { el, css } from './util.mjs'

export const SPRITES = {}
export const SEQ = {}
const pending = new Set()

export async function loadManifest() {
  const manifest = await (await fetch('/build/sprites/manifest.json')).json()
  for (const entry of manifest.sprites) SPRITES[entry.id] = { ...entry, src: `/build/sprites/${entry.file || entry.id + '.png'}` }
  return manifest
}

export async function loadSequences(loops) {
  for (const loop of loops) {
    const base = `/${loop.seq.replace(/^video\//, '')}`
    const layers = {}
    for (const layer of ['bars', 'statusitem', 'transcribing', 'statusitem_transcribing']) {
      const meta = await (await fetch(`${base}/${layer}/sequence.json`)).json()
      layers[layer] = { ...meta, base: `${base}/${layer}` }
    }
    SEQ[loop.key] = layers
  }
}

export function seqSrc(layer, index) {
  const i = Math.max(0, Math.min(layer.frames - 1, index))
  return `${layer.base}/frame_${String(i).padStart(5, '0')}.png`
}

/** An <img> that can swap its source per frame; frame() awaits all swaps. */
export function img(parent, cls) {
  const node = el('img', cls, parent)
  node.decoding = 'sync'
  node.draggable = false
  return node
}

export function setSrc(node, src) {
  if (node.__src === src) return
  node.__src = src
  node.src = src
  const p = node.decode().catch(() => {})
  pending.add(p)
  p.finally(() => pending.delete(p))
}

export async function settle() {
  while (pending.size) await Promise.all([...pending])
}

/** Places a sprite image so its anchor sits at (x, y), at `scale` units per sprite point. */
export function placeSprite(node, meta, x, y, scale = 1) {
  const [w, h] = meta.size_pt
  const [ax, ay] = meta.anchor_pt
  css(node, {
    left: `${x - ax * scale}px`,
    top: `${y - ay * scale}px`,
    width: `${w * scale}px`,
    height: `${h * scale}px`
  })
}

export async function preloadAll() {
  const jobs = Object.values(SPRITES).map((s) => {
    const image = new Image()
    image.src = s.src
    return image.decode().catch(() => console.warn('sprite failed', s.id))
  })
  await Promise.all(jobs)
}
