// With real windows: BCU_LIVE=1 node --test test/live.test.ts
// Opens a Calculator window on a test engine's display (its own BCU_HOME),
// streams frames, takes over and types into it, then closes it. Needs
// Accessibility and Screen Recording for the app this runs under. Quits
// Calculator afterwards if it wasn't running before.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { createConnection } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { after, before, test } from 'node:test'
import { EngineClient, socketPath, startEngine, type EngineStart, type FrameEvent, type Session } from '../src/index.ts'

const live = process.env.BCU_LIVE === '1'
const bcu = process.env.BCU_BIN ?? resolve(import.meta.dirname, '../../../.build/debug/bcu')
const home = mkdtempSync(join(tmpdir(), 'bcu-'))
const env = { ...process.env, BCU_HOME: home }
const path = socketPath(home)
const session = 'live-1'
let engine: EngineStart
const running = (app: string) => {
  try {
    execFileSync('pgrep', ['-x', app])
    return true
  } catch {
    return false
  }
}
const calculatorWasRunning = running('Calculator')

before(async () => {
  if (live) engine = await startEngine({ bcu, owner: 'Live Test', logDir: join(home, 'logs'), env })
})

after(async () => {
  if (engine?.process) {
    const exited = new Promise((r) => engine.process!.once('exit', r))
    engine.process.kill('SIGTERM')
    await exited
  }
  if (live && !calculatorWasRunning && running('Calculator')) execFileSync('osascript', ['-e', 'tell application "Calculator" to quit'])
  rmSync(home, { recursive: true, force: true })
})

function toolCall(tool: string, args: Record<string, unknown> = {}): Promise<{ ok: boolean; text?: string; error?: string }> {
  return new Promise((resolve, reject) => {
    const s = createConnection(path)
    let buf = ''
    s.setEncoding('utf8')
    s.on('connect', () => s.write(JSON.stringify({ id: 1, tool, args: { ...args, _session: session, _host: 'live', _label: 'Live test' } }) + '\n'))
    s.on('data', (d: string) => {
      buf += d
      if (buf.includes('\n')) {
        s.destroy()
        resolve(JSON.parse(buf.slice(0, buf.indexOf('\n'))))
      }
    })
    s.on('error', reject)
  })
}

const until = async (f: () => boolean, ms: number) => {
  const end = Date.now() + ms
  while (!f() && Date.now() < end) await new Promise((r) => setTimeout(r, 50))
  return f()
}

test('preview, take over and type into a real window', { skip: !live, timeout: 60_000 }, async () => {
  const c = await EngineClient.connect({ path })
  let latest: Session | undefined
  const pointers: unknown[] = []
  c.on('sessions', (all) => (latest = all.find((s) => s.id === session)))
  c.on('pointer', (p) => pointers.push(p))
  await c.subscribe({ host: 'live' })

  const opened = await toolCall('open_window', { app: 'Calculator' })
  assert.ok(opened.ok, opened.error ?? "open_window failed")
  const windowId = Number(/window[_ ]id[^0-9]*(\d+)/i.exec(opened.text ?? '')?.[1])
  assert.ok(windowId > 0, `a window id in: ${opened.text}`)

  assert.ok(await until(() => !!latest?.display && latest.windows.some((w) => w.id === windowId && !!w.frame), 5000), 'the session shows its display and window')
  const win = latest!.windows.find((w) => w.id === windowId)!
  assert.equal(win.app, 'Calculator')

  const frames: FrameEvent[] = []
  const stream = await c.frames(session, { fps: 20, maxWidth: 800 })
  stream.on('frame', (f) => frames.push(f))
  assert.ok(await until(() => frames.length >= 3, 5000), `frames arrive (got ${frames.length})`)
  const jpeg = Buffer.from(frames[0].data, 'base64')
  assert.equal(jpeg[0], 0xff)
  assert.equal(jpeg[1], 0xd8)
  assert.deepEqual(frames[0].display, latest!.display)

  // Take over: the agent's actions are refused while the user drives (reads aren't).
  await c.takeOver(session)
  assert.ok(await until(() => latest?.status.state === 'user_in_control', 2000))
  const refused = await toolCall('press_key', { window_id: windowId, key: 'escape' })
  assert.ok(!refused.ok, 'an agent action is refused during take-over')

  // Hovering reports the pointer shape; keys go to the window: clear, then 7 × 6 =.
  const f = win.frame!
  await c.input(session, { type: 'mousemove', x: f.x + f.width / 2, y: f.y + f.height / 2 })
  const keys: [string, string, boolean?][] = [
    ['Escape', 'Escape'], ['Digit7', '7'], ['Digit8', '*', true], ['Digit6', '6'], ['Equal', '=']
  ]
  for (const [code, key, shiftKey] of keys) {
    await c.input(session, [{ type: 'keydown', code, key, shiftKey }, { type: 'keyup', code, key, shiftKey }])
    await new Promise((r) => setTimeout(r, 80))
  }
  await new Promise((r) => setTimeout(r, 500))
  await c.takeOver(session, false)

  const state = await toolCall('get_window_state', { window_id: windowId, screenshot: false, full: true })
  assert.ok(state.ok, state.error ?? "get_window_state failed")
  assert.match(state.text ?? '', /\b42\b/, `the keys reached Calculator: ${state.text?.slice(0, 2000)}`)

  stream.stop()
  const released = await toolCall('release_window', { window_id: windowId })
  assert.ok(released.ok, released.error ?? "release_window failed")
  assert.ok(await until(() => latest?.windows.length === 0, 5000), 'the window is gone from the session')
  c.close()
})
