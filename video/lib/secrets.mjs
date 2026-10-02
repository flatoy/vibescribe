// Reads API keys from the environment, then video/.env (gitignored, mode 600).
// Keys are only ever passed to fetch; never log them.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ENV_FILE = join(dirname(fileURLToPath(import.meta.url)), '..', '.env')

function fromFile(name) {
  try {
    const text = readFileSync(ENV_FILE, 'utf8')
    const match = text.match(new RegExp(`^\\s*(?:export\\s+)?${name}\\s*=\\s*["']?([^"'\\s#]+)`, 'm'))
    return match?.[1]
  } catch {
    return undefined
  }
}

export function secret(name) {
  const key = process.env[name] || fromFile(name)
  if (!key) throw new Error(`${name} is not set in the environment or video/.env`)
  return key
}
