import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const START = { cwd: '/Users/me/code/web-app/api', surface: 'terminal' as const, isInteractive: true }
const ORIGIN = { kind: 'composer' } as const
const PRESENTATION = { isFullscreen: false, columns: 120 }
const NOW = Date.parse('2026-10-19T12:00:00Z')

type World = { answers?: Record<string, string>; settingsFile?: string; costs?: number[] }

function world(on: On, w: World = {}) {
  const writes = new Map<string, string>()
  const runs: string[][] = []
  const asked: string[] = []
  const sets: Record<string, unknown> = {}
  const costs = [...(w.costs ?? [1.0, 1.38])]
  const clock = mock.clock(on, { now: NOW })
  mock.store(on, {})
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/Users/me/code/web-app/api' }))
  on('session.id', () => ({ value: 'abcdef12-0000' }))
  on('session.usage', () => ({ value: { startedAt: NOW, context: { window: 200000 }, rateLimits: [], cost: { usd: costs.length > 1 ? costs.shift()! : costs[0] } } }))
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/Users/me' : e.name === 'TERM_PROGRAM' ? 'Apple_Terminal' : 'com.apple.Terminal' }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('ui.toast', () => ({ value: undefined }))
  on('fs.exists', ($, e) => ({ value: e.path.endsWith('/settings.json') ? w.settingsFile !== undefined : true }))
  on('fs.read', () => ({ value: w.settingsFile ?? '{}' }))
  on('fs.write', ($, e) => {
    writes.set(e.path, e.text)
    return { value: undefined }
  })
  on('process.run', ($, e) => {
    runs.push([...e.argv])
    const script = e.argv[2] ?? ''
    const stdout = script.includes('rev-parse') ? '/Users/me/code/web-app\n' : script.includes('login') ? 'ttys005\n' : script === 'uname -s' ? 'Darwin\n' : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') {
      const q = e.questions[0].question
      asked.push(q)
      const pick = w.answers?.[e.questions[0].header] ?? e.questions[0].options[0].label
      // '__hang__': the card in the tab is never answered.
      if (pick === '__hang__') return new Promise(() => {})
      return { result: { questions: e.questions, answers: { [q]: pick } } }
    }
    if (e.tool === 'Bash' && (e as { command: string }).command.includes('fail')) return { isError: true as const, result: 'Exit code 1', text: 'Exit code 1' }
    return { result: { stdout: '', stderr: '', interrupted: false }, text: '' }
  })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('config.set', ($, e) => {
    sets[e.key] = e.value
    return { value: e.value }
  })
  const order = () => JSON.parse(writes.get('/Users/me/.claude/order-up/queue/ttys005.json') ?? 'null')
  return { writes, runs, asked, clock, order, sets }
}

const turn = (durationMs: number) => ({ answer: 'Done.', durationMs, isAborted: false, turnId: 't', reason: 'answer' as const })

test('a long turn serves an order: the git project, its tab and app, and the bill', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await $.prompt.submit({ text: 'add rate limiting to the login endpoint\nand tests' })
  await $.tool.call({ tool: 'Edit', file_path: '/Users/me/code/web-app/api/login.ts', old_string: 'a', new_string: 'b' } as never)
  await $.tool.call({ tool: 'Bash', command: 'npm test', description: 'x' })
  await $.turn.complete(turn(252000))
  await w.clock.advance(0)
  expect(w.order()).toMatchObject({
    tty: '/dev/ttys005',
    bundleId: 'com.apple.Terminal',
    title: 'web-app · api',
    summary: 'add rate limiting to the login endpoint',
    bill: '4m12s · $0.38 · 1 file · 1 cmd',
    kind: 'done',
  })
  expect(w.runs.some(r => r[0] === '/usr/bin/open' && r.at(-1) === '/Users/me/.claude/order-up/OrderUp.app')).toBe(true)
})

test('a short turn serves nothing; a failing last command burns the dish', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await $.prompt.submit({ text: 'quick question about types' })
  await $.turn.complete(turn(4000))
  await w.clock.advance(0)
  expect(w.order()).toBeNull()
  await $.prompt.submit({ text: 'run the test suite' })
  await $.tool.call({ tool: 'Bash', command: 'npm test # fail', description: 'x' })
  await $.turn.complete(turn(64000))
  await w.clock.advance(0)
  expect(w.order()?.kind).toBe('burnt')
})

test('a question waiting on you serves a "needs you" order', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Ship the build to TestFlight now?', header: 'Ship', options: [{ label: 'Yes' }, { label: 'No' }], multiSelect: false }] } as never)
  expect(w.order()).toMatchObject({ kind: 'needs', summary: 'asks: Ship the build to TestFlight now?' })
})

test('/order-up setup asks its questions, builds the app, serves a test order and saves the answers as options', async ($, on) => {
  const w = world(on, { answers: { Character: 'Barista', When: 'Turns over 2 min', Summary: 'Nothing, just the project', Corner: 'Top right', Sound: 'No sound' } })
  await $.session.start(START)
  const r = await $.command.run({ command: 'order-up', args: 'setup', origin: ORIGIN, presentation: PRESENTATION })
  await w.clock.advance(0)
  expect(w.asked).toHaveLength(8)
  expect(JSON.parse(w.writes.get('/Users/me/.claude/order-up/settings.json') ?? '{}')).toMatchObject({ afterSec: 120, summary: 'off', corner: 'top-right', sound: false })
  expect(w.runs.some(r => (r[2] ?? '').includes('build.sh'))).toBe(true)
  expect(w.order()).toMatchObject({ isTest: true, kind: 'done' })
  expect(r.text).toContain('order-up is set up')
  expect(r.text).toContain('allow it')
  expect(w.sets).toMatchObject({ 'order-up.skin': 'barista', 'order-up.after': '2 min', 'order-up.summary': 'nothing', 'order-up.corner': 'top right', 'order-up.sound': false })
  // Answers equal to what is set already are not written again.
  expect(w.sets['order-up.alwaysOn']).toBeUndefined()
})

test('/order-up set changes one option in plain words; config lists them', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  const run = (args: string) => $.command.run({ command: 'order-up', args, origin: ORIGIN, presentation: PRESENTATION })
  expect((await run('set corner top right')).text).toBe('Set corner to top right.')
  expect((await run('set sound off')).text).toBe('Set sound to off.')
  expect((await run('set always on')).text).toBe('Set alwaysOn to on.')
  expect(w.sets).toMatchObject({ 'order-up.corner': 'top right', 'order-up.sound': false, 'order-up.alwaysOn': true })
  expect((await run('set corner middle')).text).toContain('bottom right | bottom left | top right')
  expect((await run('set skin robot')).text).toBe('Set skin to robot.')
  expect(w.sets['order-up.skin']).toBe('robot')
  expect((await run('config')).text).toContain('corner')
})

test('options decide when an order is served', { options: { after: 'every turn' } }, async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await $.prompt.submit({ text: 'rename the export button please' })
  await $.turn.complete(turn(1000))
  await w.clock.advance(0)
  expect(w.order()?.kind).toBe('done')
})

test('settings.json names a project\'s color and dish', { options: { after: 'every turn' } }, async ($, on) => {
  const w = world(on, { settingsFile: JSON.stringify({ projects: { 'web-app': { color: '#123456', dish: '🍣' } } }) })
  await $.session.start(START)
  await $.prompt.submit({ text: 'rename the export button please' })
  await $.turn.complete(turn(1000))
  await w.clock.advance(0)
  expect(w.order()).toMatchObject({ color: '#123456', dish: '🍣' })
})

const QUESTION = { question: 'Ship the build to TestFlight now?', header: 'Ship', options: [{ label: 'Yes, ship it' }, { label: 'Not yet' }], multiSelect: false }

test('answer from the chef: the order carries the choices, and the chef\'s answer wins the race', async ($, on) => {
  on('process.spawn', async function* () {
    yield { stream: 'stdout' as const, text: '{"answer":"Yes, ship it"}' }
    return { value: { code: 0, signal: null } }
  })
  const w = world(on, { answers: { Ship: '__hang__' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'AskUserQuestion', questions: [QUESTION] } as never)
  expect(w.order()).toMatchObject({ kind: 'needs', options: ['Yes, ship it', 'Not yet'] })
  expect(w.order().answerId).toBeTruthy()
  expect((r as { result: { answers: Record<string, string> } }).result.answers).toEqual({ 'Ship the build to TestFlight now?': 'Yes, ship it' })
})

test('answered in the tab first: that answer stands and the chef stops waiting', async ($, on) => {
  let stopped = false
  on('process.spawn', async function* () {
    try {
      await new Promise(() => {})
    } finally {
      stopped = true
    }
    return { value: { code: 0, signal: null } }
  })
  const w = world(on, { answers: { Ship: 'Not yet' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'AskUserQuestion', questions: [QUESTION] } as never)
  expect((r as { result: { answers: Record<string, string> } }).result.answers).toEqual({ 'Ship the build to TestFlight now?': 'Not yet' })
  await w.clock.advance(0)
  expect(w.runs.some(r => (r[2] ?? '').includes('grep -q'))).toBe(true)
  void stopped
})
