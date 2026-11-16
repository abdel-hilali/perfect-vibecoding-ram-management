#!/usr/bin/env node
// ram-hook.mjs: the hooks of perfect-vibecoding-ram-management. Node 18 ESM, no dependencies.
// It never throws, always exits 0 and prints nothing when all is fine: a bug here must never block work.
//
//   node ram-hook.mjs session-start   starts the watchdog (detached) unless the "watchdog" option is off; gives
//                                     Claude one or two lines only when memory is low or critical, or when the
//                                     watchdog stopped something in the last 6 hours; writes RAM_SH (this
//                                     plugin's ram.sh) to CLAUDE_ENV_FILE for the session's Bash commands
//   node ram-hook.mjs pre-agent       refuses a new agent or workflow when free memory is below what one needs
//   node ram-hook.mjs pre-bash        refuses an unqueued heavy command (tests, builds, analyzers, emulators) when
//                                     memory is low or a queued job runs (a long-lived one gets no "queue it");
//                                     tells Claude once about each job the watchdog stopped
//   node ram-hook.mjs classify        for the tests: one JSON string (a command) per line in,
//                                     heavy|long|queued|queued-long|light out (long: heavy and long-lived, like an
//                                     emulator; queued-long: one wrapped in ram.sh run, always refused)
//
// No process scan here: ram.sh reads the memory (check heavy|agent|level) and this file reads two small files.
// The per-session state (when this session last heard of a stop) lives in os.tmpdir(). On Windows it does
// nothing: ram.sh needs Linux or macOS (WSL counts as Linux).

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RAM_SH = path.join(HERE, '..', 'skills', 'ram', 'scripts', 'ram.sh');
const SIX_HOURS_S = 6 * 3600;
const MAX_NOTICES = 3;

// A boolean plugin option arrives as CLAUDE_PLUGIN_OPTION_<NAME>; it is off only when it says so.
const isOff = (v) => /^(false|0|no|off)$/i.test(String(v ?? '').trim());
const size = (mb) => (Number(mb) >= 1024 ? `${(Number(mb) / 1024).toFixed(1)} GB` : `${Number(mb)} MB`);
const clip = (s) => (s.length > 80 ? `${s.slice(0, 77)}...` : s);
const deny = (reason) => ({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
});

// Runs ram.sh and returns its first output line, or '' when it cannot run (no bash, a timeout).
function ram(args, env) {
  const r = spawnSync('bash', [RAM_SH, ...args], {
    env, encoding: 'utf8', timeout: 7000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (r.error || typeof r.stdout !== 'string') return '';
  return r.stdout.split('\n')[0].trim();
}

// ---------------------------------------------------------------- which Bash commands are heavy

// Words that run the next word: "timeout 600 flutter test" is "flutter test". Shell keywords count too.
const WRAPPERS = new Set(['sudo', 'env', 'time', 'nice', 'ionice', 'nohup', 'exec', 'command', 'builtin', 'timeout',
  'gtimeout', 'xvfb-run', 'stdbuf', 'caffeinate', 'xargs', 'fvm', 'npx', 'pnpx', 'bunx', 'then', 'do', 'else',
  'if', 'elif', 'while', 'until', '{', '!', '--']);
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;
const WRAPPER_ARG = /^(-|\d[\d.]*[smhd]?$)/; // what a wrapper takes before its command: -n 10, --kill-after=30, 600
const INFO = ['--version', '-v', '--help', '-h'];
const SCRIPT = /^(build|test|e2e|verify)([:._-][\w:.-]*)?$/; // npm run build, pnpm test:unit, yarn e2e
// Package-manager commands that run no script: "npm install vitest" installs, it does not test.
const PM_OWN = new Set(['install', 'i', 'add', 'remove', 'rm', 'uninstall', 'ci', 'update', 'up', 'upgrade', 'link',
  'unlink', 'publish', 'pack', 'init', 'create', 'outdated', 'ls', 'list', 'why', 'audit', 'config', 'view', 'info',
  'cache', 'prune', 'dedupe', 'login', 'logout', 'whoami', 'set', 'get', 'store', 'import', 'patch', 'version']);
const PM_VALUE_FLAGS = new Set(['--filter', '-F', '--prefix', '-C', '--dir', '--cwd', '-w', '--workspace']);
// Already queued: ram.sh run, a kit's queued tool (q-test.sh, q-build.sh, ...) or its verify.sh.
const QUEUED = /(^|[\s/'"=;&|(])(ram\.sh['"]?\s+run\b|q-[\w.-]+\.sh\b|verify\.sh\b)/;

const base = (w) => w.slice(w.lastIndexOf('/') + 1);
const asks = (a, ...flags) => a.some((x) => flags.includes(x));
// An emulator or "flutter run" lives for hours. Queued, it would hold a slot and the folder lock all that time and
// block every test and build of the app, so the deny for it must not say "queue it".
const LONG = 'long';
const LONG_ADVICE = "A long-lived job (an emulator, flutter run): never queue it with ram.sh run (it would hold a slot "
  + `and the folder lock for its whole life). Wait until 'bash ${RAM_SH} check heavy' prints ok, then start it `
  + 'detached (an emulator from outside the project folder).';

// True when the words of one simple command start something heavy; LONG when that something is long-lived.
function heavyWords(w) {
  let i = 0;
  for (;;) {
    while (i < w.length && ASSIGN.test(w[i])) i++;
    if (i < w.length && WRAPPERS.has(base(w[i]))) {
      i++;
      while (i < w.length && (WRAPPER_ARG.test(w[i]) || ASSIGN.test(w[i]))) i++;
      continue;
    }
    break;
  }
  if (i >= w.length) return false;
  const c = base(w[i]);
  const a = w.slice(i + 1);
  const [s1, s2] = a.filter((x) => !x.startsWith('-'));
  if (a.some((x) => /(^|[/:])build_runner(:|$)/.test(x))) return true; // dart run build_runner build
  switch (c) {
    case 'flutter': // "flutter test --help" only prints text; "-v" is verbose here, so it stays heavy
      if (asks(a, '--help', '-h')) return false;
      if (s1 === 'run' || (s1 === 'emulators' && asks(a, '--launch'))) return LONG;
      return ['test', 'build', 'analyze', 'drive', 'install'].includes(s1);
    case 'dart':
      return !asks(a, '--help', '-h') && ['test', 'analyze', 'compile'].includes(s1);
    case 'gradle': case 'gradlew': case 'mvn': case 'mvnw':
      return !asks(a, '--stop', '--status', ...INFO); // "gradlew --stop" frees memory
    case 'emulator':
      return asks(a, '-avd') || a.some((x) => x.startsWith('@')) ? LONG : false;
    case 'xcodebuild':
      return !a.some((x) => /^-(version|help|usage|showsdks|list|showdestinations)$/.test(x));
    case 'pod':
      return s1 === 'install' || s1 === 'update';
    case 'next':
      return s1 === 'build';
    case 'vitest': case 'jest':
      return !asks(a, ...INFO);
    case 'playwright':
      return s1 === 'test';
    case 'tsc':
      return !asks(a, ...INFO, '--init');
    case 'docker': case 'podman':
      return s1 === 'build' || (['buildx', 'builder', 'image', 'compose'].includes(s1) && s2 === 'build')
        || (s1 === 'compose' && asks(a, '--build'));
    case 'cargo':
      return ['build', 'b', 'test', 't'].includes(s1);
    case 'go':
      return s1 === 'build' || s1 === 'test';
    case 'npm': case 'pnpm': case 'yarn': case 'bun':
      return heavyScript(a);
    default:
      return false;
  }
}

// npm, pnpm, yarn and bun: "run build", "test", "test:e2e", or a heavy tool they start ("pnpm exec vitest").
function heavyScript(a) {
  let run = false;
  for (let j = 0; j < a.length; j++) {
    const x = a[j];
    if (PM_VALUE_FLAGS.has(x)) { j++; continue; }
    if (x.startsWith('-')) continue;
    if (x === 'run' || x === 'run-script') { run = true; continue; }
    if (x === 'workspace') { j++; continue; } // yarn workspace web build
    if (x === 'exec' || x === 'x' || x === 'dlx') return heavyWords(a.slice(j + 1));
    if (SCRIPT.test(x)) return true;
    if (run || PM_OWN.has(x)) return false;
    return heavyWords(a.slice(j)); // yarn vitest, pnpm tsc --noEmit
  }
  return false;
}

// A here-document body is text, not commands: an agent that writes a README with "flutter test" in it runs nothing.
function dropHeredocs(s) {
  return s.replace(/(?<!<)<<(?!<)-?\s*(['"]?)([A-Za-z_][\w.-]*)\1[^\n]*\n(?:(?:[\s\S]*?\n)??[ \t]*\2[ \t]*(?=\n|$)|[\s\S]*$)/g,
    (m) => m.slice(0, m.indexOf('\n')));
}

// The simple commands of a shell line, as word lists. Quoted text is blanked first, so
// `git commit -m "flutter test"` is light; the body of `bash -c '...'` is a command line of its own.
function commandsOf(line, depth = 0) {
  const out = [];
  if (depth < 3) {
    const shc = /\b(?:ba|z|da)?sh\s+(?:-\w+\s+)*-\w*c\s+(?:'([^']*)'|"((?:[^"\\]|\\.)*)")/g;
    for (const m of line.matchAll(shc)) out.push(...commandsOf(m[1] ?? m[2].replace(/\\(.)/g, '$1'), depth + 1));
  }
  const flat = line.replace(/'[^']*'|"(?:[^"\\]|\\.)*"/g, "''").replace(/(^|\s)#[^\n]*/g, '$1');
  for (const seg of flat.split(/&&|\|\||[;|&\n()`]|\$\(/)) {
    const w = seg.trim().split(/\s+/).filter(Boolean);
    if (w.length) out.push(w);
  }
  return out;
}

// "ram.sh run -- flutter run": queued, a long-lived job would hold a slot and the folder lock for its whole life.
const QUEUED_LONG = 'queued-long';
const QUEUED_RUN = /ram\.sh['"]?\s+run\b[^;&|\n]*?\s--\s+([^;&|\n]+)/g;
const wrapsLong = (c) => [...c.matchAll(QUEUED_RUN)].some((m) => commandsOf(m[1]).some((w) => heavyWords(w) === LONG));

function classify(cmd) {
  const c = dropHeredocs(String(cmd));
  if (QUEUED.test(c)) return wrapsLong(c) ? QUEUED_LONG : 'queued';
  const kinds = commandsOf(c).map(heavyWords);
  if (kinds.includes(LONG)) return 'long'; // "flutter test && flutter run": the run must not be queued either
  return kinds.some(Boolean) ? 'heavy' : 'light';
}

// ---------------------------------------------------------------- the watchdog's STOP lines

// RAM_LOG_DIR: the environment, else a plain line of ram.env, else ram.sh's default (the same order as ram.sh).
function logDir(env) {
  const home = env.HOME || os.homedir();
  if (env.RAM_LOG_DIR) return env.RAM_LOG_DIR;
  return configValue(env, home, 'RAM_LOG_DIR')
    || path.join(env.XDG_STATE_HOME || path.join(home, '.local', 'state'), 'perfect-vibecoding-ram');
}

// A plain NAME=value line of ram.env, with $HOME and a leading ~ expanded. Anything cleverer is left to ram.sh.
function configValue(env, home, name) {
  const file = env.RAM_CONFIG || path.join(env.XDG_CONFIG_HOME || path.join(home, '.config'), 'perfect-vibecoding-ram', 'ram.env');
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return ''; }
  let v = '';
  for (const line of text.split('\n')) {
    const m = new RegExp(`^\\s*(?:export\\s+)?${name}=(.*)$`).exec(line);
    if (m) v = m[1].replace(/\s+#.*$/, '').trim().replace(/^(['"])(.*)\1$/, '$2');
  }
  v = v.replace(/^~(?=\/|$)/, home).replace(/\$\{HOME\}|\$HOME\b/g, home);
  return v.includes('$') ? '' : v;
}

// The STOP lines of events.log newer than `since` (epoch seconds): ram.sh writes the epoch first for this.
function stopsSince(env, since) {
  const file = path.join(logDir(env), 'events.log');
  let fd;
  try {
    const st = fs.statSync(file);
    if (st.mtimeMs / 1000 < since) return []; // nothing written since: no need to read it
    const len = Math.min(st.size, 65536);
    const buf = Buffer.alloc(len);
    fd = fs.openSync(file, 'r');
    fs.readSync(fd, buf, 0, len, st.size - len);
    const lines = buf.toString('utf8').split('\n');
    if (len < st.size) lines.shift(); // the first line may be cut
    const out = [];
    for (const line of lines) {
      const m = /^(\d+) \S+ (\S+) STOP \S+ what='(.*)'(?: rss=\d+MB)? free=(\d+)MB/.exec(line);
      if (m && Number(m[1]) > since) out.push({ t: Number(m[1]), time: m[2], what: m[3], free: Number(m[4]) });
    }
    return out;
  } catch {
    return [];
  } finally {
    if (fd !== undefined) try { fs.closeSync(fd); } catch { /* closed already */ }
  }
}

// The state folder, only when it is a real folder of this user: never write through someone else's /tmp entry.
function ownDir(create) {
  const dir = path.join(os.tmpdir(), `perfect-vibecoding-ram-hook-${typeof process.getuid === 'function' ? process.getuid() : 'user'}`);
  try {
    if (create) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const st = fs.lstatSync(dir);
    if (!st.isDirectory() || (typeof process.getuid === 'function' && st.uid !== process.getuid())) return null;
    return dir;
  } catch {
    return null;
  }
}

const sessionKey = (input) => String(input?.session_id || 'no-session').replace(/[^\w-]/g, '_').slice(0, 100);

function readLast(input) {
  const dir = ownDir(false);
  if (!dir) return null;
  try {
    const n = Number(fs.readFileSync(path.join(dir, sessionKey(input)), 'utf8').trim());
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch {
    return null;
  }
}

function saveLast(input, t) {
  const dir = ownDir(true);
  if (!dir) return false;
  try { fs.writeFileSync(path.join(dir, sessionKey(input)), String(t)); return true; } catch { return false; }
}

function pruneState(now) {
  const dir = ownDir(false);
  if (!dir) return;
  try {
    for (const f of fs.readdirSync(dir)) {
      const p = path.join(dir, f);
      try { if (now - fs.statSync(p).mtimeMs / 1000 > 7 * 86400) fs.unlinkSync(p); } catch { /* gone already */ }
    }
  } catch { /* nothing to prune */ }
}

// The stops this session has not heard of, at most 3, marked as told. A session with no state hears of the last
// 6 hours. A notice that cannot be marked as told is not given: it would repeat before every command.
function takeNotices(input, env) {
  const now = Math.floor(Date.now() / 1000);
  const stops = stopsSince(env, readLast(input) ?? now - SIX_HOURS_S);
  if (!stops.length || !saveLast(input, stops[stops.length - 1].t)) return '';
  const shown = stops.slice(-MAX_NOTICES).map((s) => `'${clip(s.what)}' at ${s.time.slice(0, 5)} (${size(s.free)} free)`);
  const more = stops.length > MAX_NOTICES ? ` and ${stops.length - MAX_NOTICES} earlier` : '';
  return `RAM watchdog: the memory ran out, so it stopped ${shown.join('; ')}${more}. Tell the owner. Rerun a stopped `
    + `job only through the queue, once 'bash ${RAM_SH} status' shows room: bash ${RAM_SH} run -- <command>`;
}

// ---------------------------------------------------------------- the three hooks

// Other kits' tools (the Flutter kit's lib.sh) look for ram.sh in RAM_SH first, before a slow plugin-cache search.
// Claude Code runs the lines of CLAUDE_ENV_FILE before each Bash command. Written once: a resumed or compacted
// session runs this hook again. A RAM_SH the owner set (a path, or off) wins, so it is left alone.
function exportRamSh(env) {
  if (!env.CLAUDE_ENV_FILE || env.RAM_SH) return;
  const line = `export RAM_SH='${RAM_SH.replace(/'/g, "'\\''")}'`;
  try {
    let text = '';
    try { text = fs.readFileSync(env.CLAUDE_ENV_FILE, 'utf8'); } catch { /* not written yet */ }
    if (text.split('\n').includes(line)) return;
    fs.appendFileSync(env.CLAUDE_ENV_FILE, `${text && !text.endsWith('\n') ? '\n' : ''}${line}\n`);
  } catch { /* the session works without it: the tools search for ram.sh */ }
}

function sessionStart(input, env) {
  exportRamSh(env);
  if (!isOff(env.CLAUDE_PLUGIN_OPTION_WATCHDOG)) {
    // Detached: "watch --start" waits up to 5 s for the new watchdog, and the session must not wait for it.
    const e = { ...env };
    if (isOff(env.CLAUDE_PLUGIN_OPTION_STOP_JOBS)) e.RAM_KILL = '0';
    try {
      const c = spawn('bash', [RAM_SH, 'watch', '--start'], { env: e, detached: true, stdio: 'ignore' });
      c.on('error', () => {});
      c.unref();
    } catch { /* no bash: nothing to start */ }
  }
  const now = Math.floor(Date.now() / 1000);
  const lines = [];
  const [level, free, warn] = ram(['check', 'level'], env).split(/\s+/);
  if (level === 'low') {
    lines.push(`RAM is low: ${size(free)} free. Below ${size(warn)} the RAM hooks refuse new agents and unqueued heavy `
      + `commands. Run heavy jobs one at a time through bash ${RAM_SH} run -- <command>, and start no extra agent.`);
  } else if (level === 'critical') {
    lines.push(`RAM is critical: ${size(free)} free. Start no agent and no heavy job, and ask the owner to close what `
      + `they do not use. 'bash ${RAM_SH} status' shows who uses the memory.`);
  }
  const stops = stopsSince(env, now - SIX_HOURS_S);
  if (stops.length) {
    const s = stops[stops.length - 1];
    lines.push(`The RAM watchdog stopped ${stops.length === 1 ? 'a job' : `${stops.length} jobs`} in the last 6 hours `
      + `(the last: '${clip(s.what)}' at ${s.time.slice(0, 5)}). Run heavy work through the queue; what used the `
      + `memory: bash ${RAM_SH} last`);
  }
  saveLast(input, stops.length ? stops[stops.length - 1].t : now); // these stops are told: pre-bash skips them
  pruneState(now);
  return lines.length ? { hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: lines.join('\n') } } : null;
}

function preAgent(env) {
  const out = ram(['check', 'agent'], env);
  return out.startsWith('deny ') ? deny(`RAM guard: ${out.slice(5)}`) : null;
}

function preBash(input, env) {
  const cmd = String(input?.tool_input?.command ?? '');
  const notes = takeNotices(input, env);
  const kind = cmd ? classify(cmd) : 'light';
  // Refused even with room: the queue would stay blocked for every test and build until the job ends.
  if (kind === QUEUED_LONG) return deny(`RAM guard: ${LONG_ADVICE}${notes ? `\n${notes}` : ''}`);
  if (kind === 'heavy' || kind === LONG) {
    const out = ram(['check', 'heavy'], env);
    if (out.startsWith('deny ')) {
      // ram.sh's reason ends with "Queue it: ...": a long-lived job keeps only the why, then its own advice.
      const why = kind === LONG ? `${out.slice(5).split(' Queue it: ')[0]} ${LONG_ADVICE}` : out.slice(5);
      return deny(`RAM guard: ${why}${notes ? `\n${notes}` : ''}`);
    }
  }
  return notes ? { hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: notes } } : null;
}

function decide(mode, input, env) {
  if (mode === 'session-start') return sessionStart(input, env);
  if (mode === 'pre-agent') return preAgent(env);
  if (mode === 'pre-bash') return preBash(input, env);
  return null;
}

// ---------------------------------------------------------------- main

const MODES = ['session-start', 'pre-agent', 'pre-bash', 'classify'];
const USAGE = "usage: echo '<hook JSON>' | node ram-hook.mjs session-start|pre-agent|pre-bash   (a Claude Code hook; "
  + 'classify reads one command per line, for the tests)';
const mode = process.argv[2] || '';
process.on('uncaughtException', () => { process.exitCode = 0; });
if (process.platform !== 'win32' && !MODES.includes(mode)) {
  // A wrong call is a setup mistake, not a reason to block work: say how to call it, and still exit 0.
  process.stderr.write(`${USAGE}\n`);
} else if (process.platform !== 'win32') {
  let input = '';
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    try {
      if (mode === 'classify') {
        const lines = input.split('\n').filter((l) => l.trim());
        const words = lines.map((l) => { let c = l; try { c = JSON.parse(l); } catch { /* a raw line */ } return classify(c); });
        process.stdout.write(words.join('\n') + (words.length ? '\n' : ''));
      } else {
        const out = decide(mode, input.trim() ? JSON.parse(input) : {}, process.env);
        if (out) process.stdout.write(JSON.stringify(out));
      }
    } catch {
      // Print nothing: a bug in this hook must never block or break a command.
    }
    process.exitCode = 0;
  };
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (d) => { input += d; });
  process.stdin.on('end', finish);
  process.stdin.on('error', finish);
  // A caller that never closes stdin must not hang the session.
  setTimeout(() => { finish(); process.exit(0); }, 4000).unref();
}
