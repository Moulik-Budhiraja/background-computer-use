// When the Background Computer Use app is installed and set up, `bcu serve`
// starts it and uses its engine. A stand-in app (a script that runs
// `bcu serve` as "Background Computer Use") plays the app here, in its own
// BCU_HOME, so the installed app isn't touched.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { after, test } from 'node:test'
import { EngineClient, socketPath, startEngine, type EngineStart } from '../src/index.ts'

const bcu = process.env.BCU_BIN ?? resolve(import.meta.dirname, '../../../.build/debug/bcu')
const lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
const dirs: string[] = []
const started: EngineStart[] = []
const tag = `${process.pid}-${Date.now()}`

function home(): string {
  const d = mkdtempSync(join(tmpdir(), 'bcu-'))
  dirs.push(d)
  return d
}

const app = join(home(), 'Stand-in.app')
mkdirSync(join(app, 'Contents/MacOS'), { recursive: true })
writeFileSync(
  join(app, 'Contents/Info.plist'),
  `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>standin</string>
<key>CFBundleIdentifier</key><string>dev.moulik.bcu-test-standin-${tag}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>`
)
const script = join(app, 'Contents/MacOS/standin')
writeFileSync(script, `#!/bin/sh\nexec "${bcu}" serve --owner "Background Computer Use" --no-parent-watch --own-engine\n`)
chmodSync(script, 0o755)

function record(dir: string, fields: Record<string, unknown> = {}) {
  const o = { path: app, version: 'test', protocol: 1, accessibility: true, screen_recording: true, ...fields }
  writeFileSync(join(dir, 'app.json'), JSON.stringify(o))
}

const lockPid = (dir: string) => Number(readFileSync(join(dir, 'engine.lock'), 'utf8').split('\n')[0])

after(() => {
  for (const s of started) s.process?.kill('SIGTERM')
  for (const d of dirs) {
    try {
      process.kill(lockPid(d), 'SIGTERM')
    } catch {}
  }
  try {
    execFileSync(lsregister, ['-u', app])
  } catch {}
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
})

test('starts the installed app and uses its engine', { timeout: 40_000 }, async () => {
  const dir = home()
  record(dir)
  const s = await startEngine({ bcu, owner: 'Test Host', env: { ...process.env, BCU_HOME: dir } })
  started.push(s)
  assert.equal(s.kind, 'running')
  assert.equal(s.owner, 'Background Computer Use')
  assert.equal(s.process, undefined)
  assert.equal(s.pid, lockPid(dir))
  const c = await EngineClient.connect({ path: socketPath(dir) })
  assert.equal((await c.hello()).engine.owner, 'Background Computer Use')
  c.close()
})

for (const [why, fields] of [
  ['without its permissions', { screen_recording: false }],
  ['that speaks another protocol', { protocol: 2 }],
  ["that isn't there any more", { path: '/nonexistent/Background Computer Use.app' }]
] as const) {
  test(`runs its own engine with an app ${why}`, async () => {
    const dir = home()
    record(dir, fields)
    const s = await startEngine({ bcu, owner: 'Test Host', env: { ...process.env, BCU_HOME: dir } })
    started.push(s)
    assert.equal(s.kind, 'ready')
  })
}

test('runs its own engine with ownEngine', async () => {
  const dir = home()
  record(dir)
  const s = await startEngine({ bcu, owner: 'Test Host', ownEngine: true, env: { ...process.env, BCU_HOME: dir } })
  started.push(s)
  assert.equal(s.kind, 'ready')
  assert.equal(s.owner, undefined)
})
