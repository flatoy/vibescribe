#!/usr/bin/env node
// Builds Tools/VibeScribeVideoFrames and renders every UI sprite plus the per-frame overlay
// sequences for each dictation loop in build/timeline.json (run timeline.mjs first).
//
//   node sprites.mjs                  sprites + sequences
//   node sprites.mjs --sequences      sequences only (sprites already rendered)
//   node sprites.mjs --sprites        sprites only
//
// Per loop (B, C, D, E) it writes build/sequences/<loop>/:
//   bars/                 live SpectrumBars from the clip's envelope, from recording start to stop (+0.3 s)
//   statusitem/           the recording status item (bars + rounded timer), same span
//   transcribing/         the whole Transcribing pill (plate + thinking bars + shimmer), stop to Pasted (+0.3 s)
//   statusitem_transcribing/
// All at 60 fps on the film clock (--t0 = film time of frame 0), so the stage indexes frames as
// floor((t - t0) * 60). SwiftPM uses its own scratch path and never the default .build.
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(fileURLToPath(import.meta.url))
const REPO = dirname(ROOT)
const SCRATCH = '.build-video'
const BIN = join(REPO, SCRATCH, 'debug', 'VibeScribeVideoFrames')
const args = process.argv.slice(2)
const only = args.includes('--sequences') ? 'sequences' : args.includes('--sprites') ? 'sprites' : 'all'

function run(cmd, argv, opts = {}) {
  const started = Date.now()
  const r = spawnSync(cmd, argv, { cwd: REPO, stdio: opts.quiet ? ['ignore', 'pipe', 'pipe'] : 'inherit', encoding: 'utf8' })
  if (r.status !== 0) {
    if (opts.quiet) process.stderr.write((r.stdout || '') + (r.stderr || ''))
    throw new Error(`${cmd} ${argv.join(' ')} failed (${r.status})`)
  }
  return (Date.now() - started) / 1000
}

console.log('building VibeScribeVideoFrames (scratch path .build-video)')
run('swift', ['build', '--scratch-path', SCRATCH, '--product', 'VibeScribeVideoFrames'])

if (only !== 'sequences') {
  const s = run(BIN, ['sprites'])
  console.log(`sprites done in ${s.toFixed(1)} s`)
}

if (only !== 'sprites') {
  const timelinePath = join(ROOT, 'build', 'timeline.json')
  if (!existsSync(timelinePath)) throw new Error('build/timeline.json is missing: run node timeline.mjs first')
  const timeline = JSON.parse(readFileSync(timelinePath, 'utf8'))
  const TAIL = 0.3
  const jobs = []
  for (const loop of timeline.loops) {
    const env = join(ROOT, 'build', 'audio', `${loop.clip}.envelope.json`)
    const dir = join(ROOT, loop.seq)
    const live = ['--envelope', env, '--t0', String(loop.rec_start), '--envelope-at', String(loop.envelope_at), '--duration', String(loop.recorded + TAIL), '--fps', '60']
    jobs.push([`${loop.key} bars`, ['sequence', '--layer', 'bars', ...live, '--out', join(dir, 'bars')]])
    jobs.push([`${loop.key} statusitem`, ['sequence', '--layer', 'statusitem', ...live, '--out', join(dir, 'statusitem')]])
    const thinking = ['--state', 'transcribing', '--badge', loop.badge, '--t0', String(loop.stop), '--duration', String(loop.transcribing_hold + TAIL), '--fps', '60']
    jobs.push([`${loop.key} transcribing`, ['sequence', '--layer', 'pill', ...thinking, '--out', join(dir, 'transcribing')]])
    jobs.push([`${loop.key} statusitem_transcribing`, ['sequence', '--layer', 'statusitem', ...thinking, '--out', join(dir, 'statusitem_transcribing')]])
  }
  for (const [label, argv] of jobs) {
    const s = run(BIN, argv, { quiet: true })
    console.log(`  ${label.padEnd(28)} ${s.toFixed(1)} s`)
  }
}
console.log('sprites.mjs done')
