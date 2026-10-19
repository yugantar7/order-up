import type { EngineInterface, PluginOptions, Register } from 'claude-code'

// order-up: when a Claude Code turn finishes (or a session needs you) in a tab you
// are not looking at, a tiny chef pops up on your Mac with the order. The mod
// writes orders to ~/.claude/order-up/queue/ and keeps a heartbeat per session in
// ~/.claude/order-up/sessions/; the OrderUp app (helper/, built by /order-up setup)
// draws the chef and the menu bar kitchen, and jumps to the tab on a click.

type Settings = {
  // A turn at least this long raises an order; 0 for every turn.
  afterSec: number
  summary: 'prompt' | 'haiku' | 'off'
  needs: boolean
  corner: 'bottom-right' | 'bottom-left' | 'top-right'
  sound: boolean
  menubar: boolean
  // Keep the menu bar chef when no Claude session runs, and start it at login.
  stayOpen: boolean
  // Optional per-project look, by project name: { "my-app": { "color": "#5B9BFF", "dish": "🍜" } }
  projects?: Record<string, { color?: string; dish?: string }>
}

const DEFAULTS: Settings = { afterSec: 30, summary: 'prompt', needs: true, corner: 'bottom-right', sound: true, menubar: true, stayOpen: false }
const LOGIN_AGENT = 'Library/LaunchAgents/dev.order-up.chef.plist'
const STORE_ON = 'enabled'
const STORE_TOLD = 'toldAboutSetup'
// Answers from /order-up setup not yet written to the options (each write reloads the mod).
const STORE_PENDING = 'pendingOptions'

// The options the manifest declares (`userConfig`): set on install, in /config, by
// /order-up setup, or /order-up set. Each field, the values it takes, and its meaning.
const FIELDS: Record<string, { values: readonly (string | boolean)[]; label: string }> = {
  after: { values: ['every turn', '30s', '1 min', '2 min', '5 min'], label: 'pop up after a turn of' },
  summary: { values: ['your prompt', 'haiku summary', 'nothing'], label: 'each order says' },
  needsYou: { values: [true, false], label: 'pop up when a session needs you' },
  corner: { values: ['bottom right', 'bottom left', 'top right'], label: 'the chef stands' },
  sound: { values: [true, false], label: 'ring a bell' },
  menubar: { values: [true, false], label: 'menu bar chef' },
  alwaysOn: { values: [true, false], label: 'menu bar chef when Claude is not running (starts at login)' },
}
const AFTER: Record<string, number> = { 'every turn': 0, '30s': 30, '1 min': 60, '2 min': 120, '5 min': 300 }

function fromOptions(o: PluginOptions): Settings {
  const pick = <T>(v: unknown, fallback: T): T => (v === undefined ? fallback : (v as T))
  return {
    afterSec: AFTER[String(o.after)] ?? DEFAULTS.afterSec,
    summary: o.summary === 'haiku summary' ? 'haiku' : o.summary === 'nothing' ? 'off' : 'prompt',
    needs: pick(o.needsYou, DEFAULTS.needs),
    corner: o.corner === 'bottom left' ? 'bottom-left' : o.corner === 'top right' ? 'top-right' : 'bottom-right',
    sound: pick(o.sound, DEFAULTS.sound),
    menubar: pick(o.menubar, DEFAULTS.menubar),
    stayOpen: pick(o.alwaysOn, DEFAULTS.stayOpen),
  }
}

const PALETTE = ['#5B9BFF', '#FF5C6C', '#C77DFF', '#A3C94A', '#E8B84B', '#4FD1C5', '#F687B3', '#F6AD55', '#9AE6B4', '#90CDF4']
const DISHES = ['🍜', '🍕', '🍣', '🥗', '🍰', '🌮', '🥘', '🍔', '🥞', '🍝', '🍤', '🧁']

// Walks up to the login process, whose tty is the tab's (Terminal.app and iTerm2
// both start one per tab; a wrapper such as tmux gets its own pty, so this finds the tab's).
const FIND_TTY =
  'p=$$; while [ "$p" -gt 1 ]; do case "$(ps -o comm= -p "$p")" in *login) ps -o tty= -p "$p"; exit;; esac; p=$(ps -o ppid= -p "$p" | tr -d " "); done; ps -o tty= -p $PPID'

type Session = { key: string; tty?: string; bundleId?: string; app: string; title: string; color: string; dish: string }

let isOn = true
let settings: Settings = DEFAULTS
let options: PluginOptions = {}
let base = ''
let me: Session | null = null
let state: 'cooking' | 'needs' | 'ready' | 'idle' = 'idle'
let stateSince = 0
// The turn being cooked: when it started, what it cost so far, what it touched.
let turn: { at: number; usd: number; prompt: string; files: Set<string>; commands: number; lastFailed: boolean } | null = null

function hash(text: string): number {
  let h = 7
  for (const ch of text) h = (h * 31 + (ch.codePointAt(0) ?? 0)) >>> 0
  return h
}

function short(text: string, n: number): string {
  const one = text.replace(/\s+/g, ' ').trim()
  return one.length > n ? `${one.slice(0, n - 1)}…` : one
}

function span(ms: number): string {
  const s = Math.round(ms / 1000)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  return m < 60 ? `${m}m${String(s % 60).padStart(2, '0')}s` : `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m`
}

async function sh($: EngineInterface, script: string, args: string[] = [], timeoutMs = 10000) {
  return $.process.run(['/bin/sh', '-c', script, 'sh', ...args], { timeoutMs })
}

function appPath(): string {
  return `${base}/OrderUp.app`
}

// settings.json: the app's copy of the options, plus the project colors and dishes
// people add by hand (the only part of it they edit).
async function writeSettings($: EngineInterface): Promise<void> {
  await $.fs.write(`${base}/settings.json`, JSON.stringify(settings, null, 2))
}

async function loadSettings($: EngineInterface): Promise<void> {
  let projects: Settings['projects']
  if (await $.fs.exists(`${base}/settings.json`)) {
    try {
      projects = (JSON.parse(await $.fs.read(`${base}/settings.json`)) as Partial<Settings>).projects
    } catch {
      // a half-edited file: no project looks this time
    }
  }
  settings = { ...fromOptions(options), projects }
}

// Writes options; each write reloads the mod, so what is left waits in the store
// and the next load finishes it.
async function applyOptions($: EngineInterface, want: Record<string, string | boolean>): Promise<void> {
  await $.store.set(STORE_PENDING, want)
  for (const [key, value] of Object.entries(want)) {
    if (options[key] === value) continue
    const r = await $.config.set({ key: `order-up.${key}`, value })
    if ('deny' in r && r.deny) throw new Error(`could not set ${key}: ${r.deny}`)
  }
  await $.store.set(STORE_PENDING, null)
}

async function finishPending($: EngineInterface): Promise<void> {
  const want = (await $.store.get(STORE_PENDING)) as Record<string, string | boolean> | null | undefined
  if (want) await applyOptions($, want)
}

function describe(): string {
  const shown = (v: unknown) => (v === true ? 'on' : v === false ? 'off' : String(v))
  return Object.entries(FIELDS)
    .map(([k, f]) => `  ${k.padEnd(9)} ${shown(options[k] ?? (k === 'after' ? '30s' : ''))}  — ${f.label} (${f.values.map(shown).join(' | ')})`)
    .join('\n')
}

// `/order-up set corner top right`: one option by name, its value in plain words.
async function setOne($: EngineInterface, args: string): Promise<string> {
  const [name = '', ...rest] = args.trim().split(/\s+/)
  const key = Object.keys(FIELDS).find(k => k.toLowerCase() === name.toLowerCase() || (name === 'always' && k === 'alwaysOn') || (name === 'needs' && k === 'needsYou'))
  if (!key) return `Which one? ${Object.keys(FIELDS).join(', ')}. For example: /order-up set corner top right`
  const raw = rest.join(' ').toLowerCase()
  const f = FIELDS[key]
  const value = typeof f.values[0] === 'boolean' ? (['on', 'yes', 'true'].includes(raw) ? true : ['off', 'no', 'false'].includes(raw) ? false : undefined) : f.values.find(v => v === raw)
  if (value === undefined) return `${key} takes: ${f.values.map(v => (v === true ? 'on' : v === false ? 'off' : v)).join(' | ')}`
  await applyOptions($, { [key]: value })
  return `Set ${key} to ${value === true ? 'on' : value === false ? 'off' : value}.`
}

// Which project this is (the git repo, else the folder), and the terminal tab it runs in.
async function identify($: EngineInterface): Promise<void> {
  const cwd = await $.session.cwd()
  const top = (await sh($, 'git -C "$1" rev-parse --show-toplevel 2>/dev/null', [cwd])).stdout.trim()
  const root = top || cwd
  const name = root.split('/').filter(Boolean).pop() ?? 'claude'
  const sub = top && cwd.startsWith(`${top}/`) ? cwd.slice(top.length + 1) : ''
  const title = sub ? `${name} · ${sub}` : name
  const look = settings.projects?.[name] ?? {}
  const term = (await $.env.get('TERM_PROGRAM')) ?? ''
  const bundleId = await $.env.get('__CFBundleIdentifier')
  const ttyName = (await sh($, FIND_TTY)).stdout.trim().split('\n')[0]
  const tty = /^ttys\d+$/.test(ttyName) ? `/dev/${ttyName}` : undefined
  const id = await $.session.id()
  me = {
    key: tty ? ttyName : `session-${id.slice(0, 8)}`,
    tty,
    bundleId,
    app: term,
    title,
    color: look.color ?? PALETTE[hash(name) % PALETTE.length],
    dish: look.dish ?? DISHES[hash(name) % DISHES.length],
  }
}

async function wake($: EngineInterface): Promise<void> {
  if (!(await $.fs.exists(`${appPath()}/Contents/MacOS/OrderUp`))) return
  await $.process.run(['/usr/bin/open', '-g', '-a', appPath()], { timeoutMs: 10000 })
}

async function heartbeat($: EngineInterface, next?: typeof state, activity?: string): Promise<void> {
  if (!me || !isOn) return
  const now = await $.clock.now()
  if (next && next !== state) {
    state = next
    stateSince = now
  }
  await $.fs.write(`${base}/sessions/${me.key}.json`, JSON.stringify({ ...me, state, since: stateSince, activity, updatedAt: now }))
}

async function summaryOf($: EngineInterface, prompt: string, answer: string): Promise<string | undefined> {
  if (settings.summary === 'off') return undefined
  if (settings.summary === 'prompt') return short(prompt.split('\n')[0], 80) || undefined
  const r = await $.model.complete({
    model: 'haiku',
    system: 'Say in at most 8 words what the assistant got done, past tense, sentence case, no period. Reply with only that.',
    prompt: `The request:\n${prompt.slice(0, 1200)}\n\nThe reply:\n${answer.slice(-1500)}`,
    maxTokens: 40,
    effort: 'low',
    timeoutMs: 15000,
  })
  return r.isAnswered ? short(r.text.split('\n')[0].replace(/^["']|["'.]$/g, ''), 80) : short(prompt, 80)
}

async function order($: EngineInterface, kind: 'done' | 'burnt' | 'needs', summary?: string, bill?: string, isTest = false): Promise<void> {
  if (!me) return
  const at = (await $.clock.now()) / 1000
  await $.fs.write(
    `${base}/queue/${me.key}.json`,
    JSON.stringify({ tty: me.tty, bundleId: me.bundleId, app: me.app, title: me.title, color: me.color, dish: me.dish, summary, bill, kind, at, isTest }),
  )
  await wake($)
}

// A login item (a LaunchAgent that opens the app) while stayOpen is on; removed otherwise.
async function startAtLogin($: EngineInterface, on: boolean): Promise<void> {
  const home = (await $.env.get('HOME')) ?? ''
  const plist = `${home}/${LOGIN_AGENT}`
  if (!on) {
    await $.process.run(['/bin/rm', '-f', plist], { timeoutMs: 5000 })
    return
  }
  await $.fs.write(
    plist,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.order-up.chef</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>${appPath()}</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
`,
  )
}

// The setup interview: checks the Mac, asks how the chef should behave, builds the
// app, and serves a test order.
async function setup($: EngineInterface): Promise<string> {
  const notes: string[] = []
  if ((await sh($, 'uname -s')).stdout.trim() !== 'Darwin') return 'order-up runs on macOS only (it draws a native window).'
  if ((await sh($, 'xcode-select -p >/dev/null 2>&1 && command -v swiftc')).exitCode !== 0) {
    return 'order-up builds its small chef app with Swift, which comes with Apple\'s Command Line Tools. Run `xcode-select --install` in a terminal, wait for it to finish, then run /order-up setup again.'
  }
  const ask = (q: string, choices: string[], header: string) => $.ui.ask(q, { options: choices, header })
  const want: Record<string, string | boolean> = {}

  const when = await ask('When should the chef pop up?', ['Turns over 30s (Recommended)', 'Turns over 2 min', 'Every finished turn'], 'When')
  want.after = when.startsWith('Every') ? 'every turn' : when.includes('2 min') ? '2 min' : '30s'
  const what = await ask('What should each order say?', ['Your prompt, shortened (free)', 'A Haiku summary (~$0.001/turn)', 'Nothing, just the project'], 'Summary')
  want.summary = what.startsWith('A Haiku') ? 'haiku summary' : what.startsWith('Nothing') ? 'nothing' : 'your prompt'
  const needs = await ask('Also pop up when a session needs you (a question or a permission prompt)?', ['Yes (Recommended)', 'No'], 'Needs you')
  want.needsYou = !needs.startsWith('No')
  const corner = await ask('Where on the screen should the chef stand?', ['Bottom right (Recommended)', 'Bottom left', 'Top right'], 'Corner')
  want.corner = corner.startsWith('Bottom left') ? 'bottom left' : corner.startsWith('Top') ? 'top right' : 'bottom right'
  const sound = await ask('Ring a bell when an order is up?', ['Yes (Recommended)', 'No sound'], 'Sound')
  want.sound = !sound.startsWith('No')
  const bar = await ask('Put a tiny chef in the menu bar (click it to call the chef out and see every session)?', ['Yes (Recommended)', 'No'], 'Menu bar')
  want.menubar = !bar.startsWith('No')
  want.alwaysOn = false
  if (want.menubar) {
    const stay = await ask(
      'Keep the chef in the menu bar even when no Claude session is running (it starts at login, and a click calls it out any time)?',
      ['Only while Claude runs (Recommended)', 'Always, and start at login'],
      'Always on',
    )
    want.alwaysOn = stay.startsWith('Always')
  }
  // This setup goes on with the new answers; the options are written last.
  settings = { ...fromOptions({ ...options, ...want }), projects: settings.projects }
  await writeSettings($)

  const built = await sh($, 'sh "$1/helper/build.sh" "$2"', [$.plugin.root, appPath()], 180000)
  if (built.exitCode !== 0) return `Settings saved, but the chef app did not build:\n${built.stderr.trim().slice(-800)}`
  notes.push('Built the chef app.')
  await startAtLogin($, settings.stayOpen)
  if (settings.stayOpen) notes.push('The chef now lives in your menu bar and starts at login (right-click it → Quit to close it until the next Claude session).')

  await identify($)
  if (me?.app === 'Apple_Terminal' || me?.app === 'iTerm.app') {
    notes.push(`The first time you click an order, macOS asks to let OrderUp control ${me.app === 'iTerm.app' ? 'iTerm' : 'Terminal'}: allow it, so a click can bring the right tab forward.`)
  } else if (me?.bundleId) {
    notes.push('In this terminal a click brings its window forward (tab-exact jumping needs Terminal.app or iTerm2).')
  } else {
    notes.push('This terminal does not say which app it is, so a click cannot bring it forward; the chef still tells you what finished.')
  }
  await order($, 'done', 'Setup complete: this is a test order', `${span(1000 * 42)} · $0.12 · 2 files · 3 cmds`, true)
  const after = settings.afterSec ? `turns over ${settings.afterSec}s` : 'every turn'
  return [
    '🍳 order-up is set up. A test order is on your screen now (click it or ✕).',
    `The chef will pop up for ${after} that finish in a tab you are not looking at${settings.needs ? ', and when a session needs you' : ''}.`,
    ...notes,
    'Change anything later with /order-up setup, /order-up set (see /order-up config), or /config → order-up. A project\'s own color and dish go in ~/.claude/order-up/settings.json under "projects".',
  ].join('\n')
}

async function setupThenSave($: EngineInterface): Promise<string> {
  const text = await setup($)
  // Last: writing the options reloads the mod; a load finishes any left over.
  const want = settingsToOptions(settings)
  void applyOptions($, want).catch(() => {})
  return text
}

function settingsToOptions(x: Settings): Record<string, string | boolean> {
  const after = Object.entries(AFTER).find(([, n]) => n === x.afterSec)?.[0] ?? '30s'
  return {
    after,
    summary: x.summary === 'haiku' ? 'haiku summary' : x.summary === 'off' ? 'nothing' : 'your prompt',
    needsYou: x.needs,
    corner: x.corner.replace('-', ' '),
    sound: x.sound,
    menubar: x.menubar,
    alwaysOn: x.stayOpen,
  }
}

export const register: Register = (on, opts) => {
  options = opts

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'order-up',
      description: 'The order-up chef: "setup" asks how it should behave and builds it; "config" shows the settings; "set <name> <value>" changes one; "test"; "on"/"off"',
      argumentHint: '[setup|config|set <name> <value>|test|on|off|status]',
    })
    try {
      base = `${(await $.env.get('HOME')) ?? ''}/.claude/order-up`
      isOn = (await $.store.get(STORE_ON)) !== false
      await loadSettings($)
      await identify($)
      const isBuilt = await $.fs.exists(`${appPath()}/Contents/MacOS/OrderUp`)
      if (!isBuilt && (await $.store.get(STORE_TOLD)) !== true) {
        await $.store.set(STORE_TOLD, true)
        $.ui.toast('🍳 order-up is installed. Run /order-up setup to build the chef and choose how it behaves (2 minutes).', { timeoutMs: 15000 })
      }
      if (isBuilt) {
        // The app reads its copy of the options; the login item follows "alwaysOn".
        await writeSettings($)
        await startAtLogin($, settings.stayOpen && settings.menubar)
      }
      void finishPending($).catch(() => {})
      if (isOn) {
        await heartbeat($, 'idle')
        if (settings.menubar) await wake($)
      }
      // Stay on the kitchen board: a session silent for three minutes counts as gone.
      $.clock.every(60000, () => void heartbeat($).catch(() => {}))
    } catch {
      // no tab, no HOME, a -p run: the chef sits this session out
    }
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (me) await $.process.run(['/bin/rm', '-f', `${base}/sessions/${me.key}.json`], { timeoutMs: 5000 }).catch(() => {})
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (isOn && !e.isMeta && !e.command) {
      const usage = await $.session.usage().catch(() => undefined)
      turn = { at: await $.clock.now(), usd: usage?.cost?.usd ?? 0, prompt: e.text, files: new Set(), commands: 0, lastFailed: false }
      void heartbeat($, 'cooking', short(e.text.split('\n')[0], 80)).catch(() => {})
    }
    return next(e)
  })

  // What the turn touched, for the bill; a failing last command burns the dish.
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (!turn || e.agentId !== undefined) return ran
    const args = e as unknown as { file_path?: unknown; notebook_path?: unknown }
    if (['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(e.tool)) {
      const file = args.file_path ?? args.notebook_path
      if (typeof file === 'string' && !ran.isError) turn.files.add(file)
    }
    if (e.tool === 'Bash') {
      turn.commands++
      turn.lastFailed = ran.isError === true
    }
    return ran
  })

  on('turn.complete', async ($, e, next) => {
    if (!isOn || e.agentId !== undefined || !turn) return next(e)
    const t = turn
    turn = null
    if (e.isAborted) {
      void heartbeat($, 'idle').catch(() => {})
      return next(e)
    }
    void (async () => {
      const burnt = e.reason === 'error' || t.lastFailed
      if (e.durationMs >= settings.afterSec * 1000) {
        const usage = await $.session.usage().catch(() => undefined)
        const usd = Math.max(0, (usage?.cost?.usd ?? t.usd) - t.usd)
        const parts = [span(e.durationMs)]
        if (usage?.cost) parts.push(`$${usd.toFixed(2)}`)
        if (t.files.size) parts.push(`${t.files.size} file${t.files.size === 1 ? '' : 's'}`)
        if (t.commands) parts.push(`${t.commands} cmd${t.commands === 1 ? '' : 's'}`)
        await order($, burnt ? 'burnt' : 'done', await summaryOf($, t.prompt, e.answer), parts.join(' · '))
      }
      await heartbeat($, 'ready')
    })().catch(() => {})
    return next(e)
  })

  // A question waiting on you (Claude's, or another mod's) or a permission prompt.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (isOn && settings.needs) {
      const q = e.questions[0]?.question ?? 'a question'
      void order($, 'needs', `asks: ${short(q, 70)}`).catch(() => {})
      void heartbeat($, 'needs').catch(() => {})
    }
    const answered = await next(e)
    void heartbeat($, 'cooking').catch(() => {})
    return answered
  })

  on('classic.Notification', async ($, e, next) => {
    if (isOn && settings.needs && (e.notification_type === 'permission_prompt' || e.notification_type === 'elicitation_dialog')) {
      void order($, 'needs', short(e.notification_type === 'elicitation_dialog' ? 'waiting for your answer' : e.message, 80)).catch(() => {})
      void heartbeat($, 'needs').catch(() => {})
    }
    return next(e)
  })

  on('command.run', { command: 'order-up' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === 'setup') return { text: await setupThenSave($) }
    if (arg === 'config') {
      return { text: `order-up settings:\n${describe()}\nChange one with /order-up set <name> <value> (e.g. /order-up set corner top right), all of them with /order-up setup, or in /config → order-up.` }
    }
    if (arg.startsWith('set ') || arg === 'set') return { text: await setOne($, e.args.trim().slice(3)) }
    if (arg === 'test') {
      await order($, 'done', 'A test order from /order-up test', `${span(1000 * 95)} · $0.21 · 1 file · 2 cmds`, true)
      return { text: (await $.fs.exists(`${appPath()}/Contents/MacOS/OrderUp`)) ? 'Test order served.' : 'The chef app is not built yet: run /order-up setup.' }
    }
    if (arg === 'on' || arg === 'off') {
      isOn = arg === 'on'
      await $.store.set(STORE_ON, isOn)
      return { text: isOn ? 'order-up on.' : 'order-up off: no more orders.' }
    }
    const built = await $.fs.exists(`${appPath()}/Contents/MacOS/OrderUp`)
    return {
      text: [
        `order-up is ${isOn ? 'on' : 'off'}${built ? '' : ' (the chef app is not built: run /order-up setup)'}.`,
        `This session: ${me?.title ?? '?'} in ${me?.app || 'an unknown terminal'}${me?.tty ? ` (${me.tty})` : ''}.`,
        `Orders for ${settings.afterSec ? `turns over ${settings.afterSec}s` : 'every turn'}; summary: ${settings.summary}; needs you: ${settings.needs ? 'on' : 'off'}; ${settings.corner}; sound ${settings.sound ? 'on' : 'off'}; menu bar ${settings.menubar ? (settings.stayOpen ? 'always, from login' : 'while Claude runs') : 'off'}.`,
        'Usage: /order-up [setup|test|on|off|status]',
      ].join('\n'),
    }
  })
}
