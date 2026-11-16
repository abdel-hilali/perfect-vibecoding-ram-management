#!/usr/bin/env bash
# tests/run.sh: the tests of the RAM plugin: ram.sh, the hooks, the manifests and the skill. Run: bash tests/run.sh
#
# Safe beside real work. Every case uses its own state, log and config folders in a temp dir, and the whole run has
# RAM_MIN_STOP_MB=1000000 (no real process is that big), RAM_STOP_DAEMONS=0 (no Gradle or Kotlin daemon) and
# RAM_NOTIFY=0: a forced critical level can stop only the test's own queued job. The plugin option that starts the
# watchdog is off, and nothing here starts, stops or installs the real watchdog or its service.
# Needs bash and Node 18 or newer. The cap cases need Linux with a systemd user session and skip elsewhere.
set -u
if [ $# -gt 0 ]; then echo "usage: bash tests/run.sh   (no arguments: it runs every case)" >&2; exit 2; fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RAM="$ROOT/skills/ram/scripts/ram.sh"
HOOK="$ROOT/hooks/ram-hook.mjs"
FIX="$ROOT/tests/fixtures"

# Nothing from the caller's shell: its RAM_* settings or plugin options would change what the cases see, and the
# session-start cases would write to its real CLAUDE_ENV_FILE.
for v in $(env | sed -n 's/^\(RAM_[A-Z_]*\)=.*/\1/p; s/^\(CLAUDE_PLUGIN_OPTION_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_ENV_FILE
T=$(mktemp -d "${TMPDIR:-/tmp}/ram-tests.XXXXXX") || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
export RAM_STATE_DIR="$T/state" RAM_LOG_DIR="$T/log" RAM_CONFIG="$T/ram.env" TMPDIR="$T/tmp"
export RAM_MIN_STOP_MB=1000000 RAM_STOP_DAEMONS=0 RAM_NOTIFY=0 RAM_HEAVY_MIN_MB=0 RAM_WAIT_S=60
export CLAUDE_PLUGIN_OPTION_WATCHDOG=false
mkdir -p "$TMPDIR" "$T/work" "$T/hooklog"
cd "$T/work" || exit 1

pass=0 fail=0 skip=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
no() { fail=$((fail + 1)); echo "FAIL $1"; if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 6 | sed 's/^/     /'; fi; }
skipped() { skip=$((skip + 1)); echo "skip $1"; }
has() { case $1 in *"$2"*) return 0 ;; esac; return 1; }
# hook MODE JSON NAME=VALUE...: runs the hook with extra environment; returns the hook's exit code.
hook() { local mode=$1 json=$2; shift 2; printf '%s' "$json" | env "$@" node "$HOOK" "$mode"; }
HL="RAM_LOG_DIR=$T/hooklog" # an events.log with no stop in it
SYSTEMD=0
if [ "$(uname -s)" = Linux ] && command -v systemd-run >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  SYSTEMD=1
fi
TO=$(command -v timeout || command -v gtimeout || true)

# ---------------------------------------------------------------- files

echo "== files"
if bash -n "$RAM"; then ok "bash -n ram.sh"; else no "bash -n ram.sh"; fi
if bash -n "$ROOT/tests/run.sh"; then ok "bash -n tests/run.sh"; else no "bash -n tests/run.sh"; fi
if node --check "$HOOK"; then ok "node --check ram-hook.mjs"; else no "node --check ram-hook.mjs"; fi
for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$ROOT/$j" 2>/dev/null; then
    ok "valid JSON: $j"
  else no "valid JSON: $j"; fi
done
OUT=$(node -e '
  const fs = require("fs"), r = process.argv[1], e = [];
  const p = JSON.parse(fs.readFileSync(r + "/.claude-plugin/plugin.json", "utf8"));
  const m = JSON.parse(fs.readFileSync(r + "/.claude-plugin/marketplace.json", "utf8"));
  const h = JSON.parse(fs.readFileSync(r + "/hooks/hooks.json", "utf8"));
  if (p.name !== "perfect-vibecoding-ram-management" || m.plugins[0].name !== p.name) e.push("names");
  for (const k of ["watchdog", "stop_jobs"]) {
    const o = (p.userConfig || {})[k] || {};
    if (o.type !== "boolean" || o.default !== true) e.push("userConfig." + k);
  }
  const pre = (h.hooks.PreToolUse || []).map((x) => x.matcher).join(",");
  if (pre !== "Agent|Task|Workflow,Bash") e.push("PreToolUse matchers: " + pre);
  const all = JSON.stringify(h);
  for (const k of ["session-start", "pre-agent", "pre-bash"]) if (!all.includes("ram-hook.mjs\",\"" + k)) e.push("no " + k);
  if (!h.hooks.SessionStart) e.push("no SessionStart");
  console.log(e.join("; "));' "$ROOT" 2>&1)
if [ -z "$OUT" ]; then ok "plugin.json, marketplace.json and hooks.json say what the brief asks"; else no "manifests" "$OUT"; fi
OUT=$(node -e '
  const t = require("fs").readFileSync(process.argv[1], "utf8"), e = [];
  const m = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(t);
  if (!m) { console.log("no frontmatter"); process.exit(0); }
  const get = (k) => ((new RegExp("^" + k + ": (.*)$", "m").exec(m[1]) || [])[1] || "").trim().replace(/^"(.*)"$/, "$1");
  if (get("name") !== "ram") e.push("name is " + get("name"));
  const d = get("description");
  if (!d || d.length > 600) e.push("description has " + d.length + " characters");
  if (!/Use when/.test(d)) e.push("the description has no \"Use when\"");
  const n = m[2].split("\n").length;
  if (n > 150) e.push("the body has " + n + " lines");
  if (!/^In Claude Code:/m.test(m[2])) e.push("no closing \"In Claude Code:\" paragraph");
  if (!m[2].includes("${CLAUDE_SKILL_DIR}/scripts/ram.sh")) e.push("no ${CLAUDE_SKILL_DIR}/scripts/ram.sh");
  console.log(e.join("; "));' "$ROOT/skills/ram/SKILL.md" 2>&1)
if [ -z "$OUT" ]; then ok "SKILL.md frontmatter (name ram, a description with Use when) and its closing paragraph"; else no "SKILL.md" "$OUT"; fi
for f in costs.md freeze.md; do
  n=$(wc -c <"$ROOT/skills/ram/$f" 2>/dev/null | tr -d ' ')
  if [ "${n:-0}" -ge 3000 ] && [ "${n:-0}" -le 6144 ]; then ok "skills/ram/$f is $n bytes (3 to 6 KB)"; else no "skills/ram/$f is ${n:-no} bytes (3 to 6 KB)"; fi
done

# ---------------------------------------------------------------- ram.sh

echo "== ram.sh"
OUT=$(bash "$RAM" status 2>&1)
code=$?
if [ "$code" = 0 ] && has "$OUT" "RAM:" && has "$OUT" "watchdog: NOT running" && has "$OUT" "queue:"; then
  ok "status prints the memory, the watchdog (not running in this test folder) and the queue"
else no "status (exit $code)" "$OUT"; fi

bash "$RAM" run --no-cap -- bash -c 'exit 3' 2>/dev/null
code=$?
if [ "$code" = 3 ]; then ok "run passes the exit code through (3)"; else no "run exit code: $code, not 3"; fi
OUT=$(bash "$RAM" run --no-cap --name label-check -- true 2>&1)
code=$?
if [ "$code" = 0 ] && has "$OUT" "'label-check' exit 0"; then ok "run reports the label and exit 0"; else no "run report (exit $code)" "$OUT"; fi

OUT=$(bash "$RAM" run --need 99999999 --wait 0 -- true 2>&1)
code=$?
if [ "$code" = 75 ] && has "$OUT" "gave up"; then ok "run gives up with exit 75 when the memory never comes"; else no "give-up (exit $code)" "$OUT"; fi

# A build gets the build's cap, any other job the per-job cap. Each command is only text after ':'.
bad=""
while IFS='|' read -r want cmd; do
  OUT=$(RAM_BUILD_MAX_MB=1111 RAM_JOB_MAX_MB=2222 bash "$RAM" run --no-cap --need 0 --wait 0 -- bash -c ": $cmd" 2>&1)
  if [ "$want" = build ]; then c="(cap 1.1 GB,"; else c="(cap 2.2 GB,"; fi
  has "$OUT" "$c" || bad="$bad${bad:+; }$want, got $(printf '%s' "$OUT" | grep -o '(cap [^,]*' | head -n 1): $cmd"
done <<'EOF'
build|flutter drive --target=test_driver/app.dart
build|flutter test integration_test/app_test.dart
build|flutter build apk
build|docker build .
build|/opt/flutter/bin/flutter build apk
build|/opt/flutter/bin/flutter test integration_test/app_test.dart
job|flutter test test/widget_test.dart
job|/opt/flutter/bin/flutter test test/widget_test.dart
EOF
if [ -z "$bad" ]; then
  ok "run: a build, flutter drive and integration_test get the build's cap, by a full path too; a unit test does not"
else no "builds and jobs" "$bad"; fi

# A small machine (faked: a reserve bigger than the RAM) never frees 4 GB: there a build waits for what the machine
# can free, and says that it may freeze. --need still wins; a reserve of 0 (a big machine) keeps 4 GB. This shell
# holds slot 1, so each build gives up at once, and its last line names what it waited for.
if command -v flock >/dev/null 2>&1; then
  exec 7>"$RAM_STATE_DIR/slots/slot.1"
  flock -n 7
  bad=""
  while IFS='|' read -r vars opt want warn; do
    # shellcheck disable=SC2086
    OUT=$(env $vars bash "$RAM" run --no-cap $opt --wait 0 -- bash -c ': flutter build apk' 2>&1)
    w=no
    has "$OUT" "may freeze it" && w=yes
    has "$OUT" "$want" && [ "$w" = "$warn" ] || bad="$bad${bad:+; }$vars $opt: $(printf '%s' "$OUT" | tr '\n' ' ')"
  done <<'EOF'
RAM_RESERVE_MB=999999 RAM_HEAVY_MIN_MB=1234||needs 1.2 GB|yes
RAM_RESERVE_MB=999999|--need 3333|needs 3.3 GB|no
RAM_RESERVE_MB=0||needs 3.9 GB|no
EOF
  exec 7>&-
  if [ -z "$bad" ]; then
    ok "run: on a small machine a build waits for what it can free, not 4 GB, with a warning; --need wins"
  else no "the build wait on a small machine" "$bad"; fi
else skipped "the build wait on a small machine (needs flock)"; fi

if [ "$(RAM_WARN_MB=0 bash "$RAM" check heavy)" = ok ]; then ok "check heavy: ok with room"; else no "check heavy: ok with room"; fi
OUT=$(RAM_WARN_MB=99999999 bash "$RAM" check heavy)
if has "$OUT" "deny only" && has "$OUT" " run -- <the same command>"; then ok "check heavy: deny under the warn level, naming the queue command"; else no "check heavy: deny" "$OUT"; fi
if [ "$(RAM_AGENT_MIN_MB=0 bash "$RAM" check agent)" = ok ]; then ok "check agent: ok with room"; else no "check agent: ok with room"; fi
OUT=$(RAM_AGENT_MIN_MB=99999999 bash "$RAM" check agent)
case $OUT in "deny "*"a new agent needs"*) ok "check agent: deny when free memory is below what an agent needs" ;; *) no "check agent: deny" "$OUT" ;; esac
L1=$(RAM_WARN_MB=0 RAM_CRIT_MB=0 bash "$RAM" check level)
L2=$(RAM_WARN_MB=99999999 RAM_CRIT_MB=0 RAM_PSI_CRIT=1000 bash "$RAM" check level)
L3=$(RAM_CRIT_MB=99999999 bash "$RAM" check level)
case "$L1|$L2|$L3" in
  "ok "*"|low "*"|critical "*) ok "check level: ok, low and critical" ;;
  *) no "check level" "$L1 | $L2 | $L3" ;;
esac

# A fake Gradle daemon: a process named java whose command line says GradleDaemon. With RAM_STOP_DAEMONS=0, free
# and the watchdog must leave it alone, as they must leave the real daemons of the agents working beside the tests.
FAKE=""
if ln -s "$(command -v bash)" "$T/java" 2>/dev/null; then
  "$T/java" -c 'while :; do sleep 1; done' GradleDaemon &
  FAKE=$!
  sleep 0.3
  c=$(ps -o comm= -p "$FAKE" 2>/dev/null)
  if [ "${c##*/}" != java ] || ! has "$(ps -o args= -p "$FAKE" 2>/dev/null)" GradleDaemon; then kill "$FAKE" 2>/dev/null; FAKE=""; fi
fi
if [ -z "$FAKE" ]; then skipped "the fake Gradle daemon (ps does not show it as java)"
elif has "$(bash "$RAM" doctor "$T/work" 2>&1)" "build daemons hold"; then ok "ram.sh sees the fake Gradle daemon (doctor counts it)"
else no "ram.sh does not see the fake Gradle daemon, so the two cases below prove nothing"; fi
OUT=$(bash "$RAM" free --dry-run 2>&1)
code=$?
if [ "$code" = 0 ] && ! has "$OUT" "Gradle daemon" && ! has "$OUT" "Kotlin daemon"; then
  ok "free --dry-run lists no build daemon when RAM_STOP_DAEMONS=0${FAKE:+, a fake one running}"
else no "free --dry-run (exit $code)" "$OUT"; fi

echo "== the fixes in ram.sh"
echo 'RAM_SLOTS=1' >"$RAM_CONFIG"
A=$(bash "$RAM" status 2>&1 | grep -o 'queue: [0-9]* slots')
B=$(RAM_SLOTS=3 bash "$RAM" status 2>&1 | grep -o 'queue: [0-9]* slots')
rm -f "$RAM_CONFIG"
if [ "$A" = "queue: 1 slots" ] && [ "$B" = "queue: 3 slots" ]; then ok "fix 1: ram.env applies, and the environment wins over it"; else no "fix 1" "file: $A; env: $B"; fi

OUT=$(RAM_RESERVE_MB=999999 bash "$RAM" status 2>&1)
code=$?
if [ "$code" = 0 ] && has "$OUT" "queue:"; then ok "fix 2: a reserve bigger than the RAM (a small machine) no longer stops every command"; else no "fix 2 (exit $code)" "$OUT"; fi

OUT=$(sed -n '/for v in RAM_CONFIG RAM_STATE_DIR/,/; do$/p' "$RAM")
if has "$OUT" RAM_MIN_STOP_MB && has "$OUT" RAM_PSI_CRIT && has "$OUT" RAM_STOP_DAEMONS; then
  ok "fix 4: watch --start passes RAM_MIN_STOP_MB, RAM_PSI_CRIT and RAM_STOP_DAEMONS to the service"
else no "fix 4" "$OUT"; fi

if [ -d /proc/self/fd ]; then
  # A build (--alone) holds one lock fd per slot from 21 up; the job must get none of them.
  OUT=$(RAM_SLOTS=6 bash "$RAM" run --no-cap --alone -- bash -c 'ls /proc/$$/fd' 2>/dev/null)
  leak=$(printf '%s\n' "$OUT" | grep -E '^2[1-6]$' | tr '\n' ' ')
  if [ -n "$OUT" ] && [ -z "$leak" ]; then ok "fix 5: a build with 6 slots gets none of the slot locks"; else no "fix 5: the job holds fds ${leak:-?}" "$OUT"; fi
  if [ "$SYSTEMD" = 1 ]; then
    OUT=$(RAM_SLOTS=6 bash "$RAM" run --alone -- bash -c 'ls /proc/$$/fd' 2>/dev/null)
    leak=$(printf '%s\n' "$OUT" | grep -E '^2[1-6]$' | tr '\n' ' ')
    if [ -n "$OUT" ] && [ -z "$leak" ]; then ok "fix 5: the same inside a capped scope"; else no "fix 5 (scope): the job holds fds ${leak:-?}" "$OUT"; fi
  fi
else skipped "fix 5 (needs /proc)"; fi

if [ "$SYSTEMD" = 1 ]; then
  bash "$RAM" run -- bash -c 'exit 4' 2>/dev/null
  code=$?
  if [ "$code" = 4 ]; then ok "run passes the exit code through a capped scope (4)"; else no "capped exit code: $code, not 4"; fi
  OUT=$(bash "$RAM" run -- bash -c 'f=kept; echo "arg=$1 var=${f} pid=$$"' sh one 2>/dev/null)
  case $OUT in
    "arg=one var=kept pid="[0-9]*) ok "fix 6: a capped job gets \$1, \${f} and \$\$ as typed (systemd-run does not expand them)" ;;
    *) no "fix 6: systemd-run changed the command" "$OUT" ;;
  esac
  # Grows 8 MB every 20 ms and ends by itself at 400 MB, so a cap that failed could never fill the machine.
  OUT=$(RAM_JOB_SWAP_MB=0 bash "$RAM" run --max 150 --name cap-check -- node -e '
    const a = []; let n = 0;
    const t = setInterval(() => { if (n++ < 50) a.push(Buffer.alloc(8 << 20, 1)); else { clearInterval(t); process.exit(0); } }, 20);' 2>&1)
  code=$?
  if [ "$code" = 137 ] && has "$OUT" "'cap-check' exit 137"; then
    ok "the 150 MB cap stops only the job: exit 137, and ram.sh lived to report it"
  else no "the cap (exit $code)" "$OUT"; fi
  # fix 7: a job that jumps past its cap between two samples used to end with no word about the cap.
  if has "$OUT" "over its cap" || has "$OUT" "most likely at its cap"; then
    ok "fix 7: a job killed at its cap always gets the cap hint, even between two samples"
  else no "fix 7: no cap hint" "$OUT"; fi
  # fix 7 alone: a SIGKILL that the sampler never saw (here the job kills itself at once) still gets the hint.
  OUT=$(bash "$RAM" run --name sigkill-check -- bash -c 'kill -9 $$' 2>&1)
  code=$?
  if [ "$code" = 137 ] && has "$OUT" "most likely at its cap"; then ok "fix 7: a SIGKILL that left no peak and no kill count gets the cap hint"
  else no "fix 7 alone (exit $code)" "$OUT"; fi
else skipped "the cap cases (no systemd user session)"; fi

# ---------------------------------------------------------------- the hook

echo "== the hook"
cut -f2- "$FIX/commands.txt" | node "$HOOK" classify >"$T/got"
n=$(wc -l <"$FIX/commands.txt" | tr -d ' ')
MIS=$(paste "$T/got" "$FIX/commands.txt" | awk -F'\t' '$1 != $2 { print "got " $1 " for " $3 }')
if [ -z "$MIS" ] && [ "$(wc -l <"$T/got" | tr -d ' ')" = "$n" ]; then
  ok "classify: $n commands sorted into heavy, long, queued, queued-long and light"
else no "classify" "$MIS"; fi

J_LS='{"session_id":"s-ls","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
J_HEAVY='{"session_id":"s-heavy","tool_name":"Bash","tool_input":{"command":"flutter test"}}'
J_QUEUED='{"session_id":"s-queued","tool_name":"Bash","tool_input":{"command":"bash /opt/kit/skills/ram/scripts/ram.sh run -- flutter test"}}'
OUT=$(hook pre-bash "$J_HEAVY" "$HL" RAM_WARN_MB=99999999)
code=$?
if [ "$code" = 0 ] && has "$OUT" '"permissionDecision":"deny"' && has "$OUT" 'run -- <the same command>'; then
  ok "pre-bash: denies an unqueued heavy command under forced low memory"
else no "pre-bash deny (exit $code)" "$OUT"; fi
OUT=$(hook pre-bash "$J_HEAVY" "$HL" RAM_WARN_MB=0)
if [ -z "$OUT" ]; then ok "pre-bash: silent for a heavy command when memory is fine and the queue is empty"; else no "pre-bash heavy with room" "$OUT"; fi
# Queued, a long-lived job would hold a slot and the folder lock for hours: its deny must not say "queue it".
J_LONG='{"session_id":"s-long","tool_input":{"command":"flutter run -d emulator-5554"}}'
OUT=$(hook pre-bash "$J_LONG" "$HL" RAM_WARN_MB=99999999)
if has "$OUT" '"deny"' && has "$OUT" "RAM guard: only " && has "$OUT" "never queue it with ram.sh run" \
  && has "$OUT" "check heavy' prints ok, then start it detached" && ! has "$OUT" "Queue it"; then
  ok "pre-bash: a long-lived command (flutter run) gets a deny that says start it detached later, not queue it"
else no "pre-bash long-lived deny" "$OUT"; fi
OUT=$(hook pre-bash "$J_QUEUED" "$HL" RAM_WARN_MB=99999999)
if [ -z "$OUT" ]; then ok "pre-bash: allows a queued command under forced low memory"; else no "pre-bash queued" "$OUT"; fi
J_QLONG='{"session_id":"s-qlong","tool_input":{"command":"bash /opt/kit/skills/ram/scripts/ram.sh run -- flutter run -d emulator-5554"}}'
OUT=$(hook pre-bash "$J_QLONG" "$HL" RAM_WARN_MB=0)
if has "$OUT" '"deny"' && has "$OUT" "never queue it with ram.sh run" && ! has "$OUT" "Queue it"; then
  ok "pre-bash: refuses a long-lived job queued with ram.sh run, even with room, and says start it detached"
else no "pre-bash queued long-lived" "$OUT"; fi
OUT=$(hook pre-bash "$J_LS" "$HL" RAM_WARN_MB=99999999)
if [ -z "$OUT" ]; then ok "pre-bash: silent for ls"; else no "pre-bash ls" "$OUT"; fi

mkdir -p "$T/stoplog" "$T/stoplog5"
echo "$(date +%s) $(date '+%F %T') STOP job=1-2 what='flutter test notice-check' free=640MB why=critical" >>"$T/stoplog/events.log"
J_N='{"session_id":"s-notice","tool_name":"Bash","tool_input":{"command":"ls"}}'
O1=$(hook pre-bash "$J_N" RAM_LOG_DIR="$T/stoplog")
O2=$(hook pre-bash "$J_N" RAM_LOG_DIR="$T/stoplog")
if has "$O1" '"additionalContext"' && has "$O1" "notice-check" && [ -z "$O2" ]; then ok "pre-bash: a STOP notice is shown once"; else no "STOP notice once" "first: $O1 / second: $O2"; fi
OUT=$(hook pre-bash '{"session_id":"s-notice2","tool_input":{"command":"flutter test"}}' RAM_LOG_DIR="$T/stoplog" RAM_WARN_MB=99999999)
if has "$OUT" '"deny"' && has "$OUT" "notice-check"; then ok "pre-bash: a deny carries the STOP notice too"; else no "deny with notice" "$OUT"; fi
for i in 1 2 3 4 5; do
  echo "$(date +%s) $(date '+%F %T') STOP pid=$((1000 + i)) what='node worker-$i' rss=900MB free=500MB why=critical" >>"$T/stoplog5/events.log"
done
OUT=$(hook pre-bash '{"session_id":"s-five","tool_input":{"command":"ls"}}' RAM_LOG_DIR="$T/stoplog5")
if has "$OUT" "worker-5" && has "$OUT" "worker-3" && ! has "$OUT" "worker-2" && has "$OUT" "and 2 earlier"; then
  ok "pre-bash: at most 3 STOP notices, the newest"
else no "at most 3 notices" "$OUT"; fi

J_A='{"session_id":"s-agent","tool_name":"Task","tool_input":{"description":"x","prompt":"y"}}'
OUT=$(hook pre-agent "$J_A" "$HL" RAM_AGENT_MIN_MB=99999999)
if has "$OUT" '"permissionDecision":"deny"' && has "$OUT" "a new agent needs"; then ok "pre-agent: denies a new agent under forced low memory"; else no "pre-agent deny" "$OUT"; fi
OUT=$(hook pre-agent "$J_A" "$HL" RAM_AGENT_MIN_MB=0)
if [ -z "$OUT" ]; then ok "pre-agent: silent when there is room"; else no "pre-agent with room" "$OUT"; fi

J_S='{"session_id":"s-start","hook_event_name":"SessionStart","source":"startup"}'
OUT=$(hook session-start "$J_S" "$HL" RAM_WARN_MB=0 RAM_CRIT_MB=0)
code=$?
if [ "$code" = 0 ] && [ -z "$OUT" ] && [ ! -e "$RAM_STATE_DIR/watch.pid" ]; then
  ok "session-start: silent when all is fine, and no watchdog started (option off)"
else no "session-start silence (exit $code)" "$OUT"; fi
OUT=$(hook session-start "$J_S" "$HL" RAM_WARN_MB=99999999 RAM_CRIT_MB=0 RAM_PSI_CRIT=1000)
if has "$OUT" '"SessionStart"' && has "$OUT" "RAM is low"; then ok "session-start: one line when memory is low"; else no "session-start low" "$OUT"; fi
OUT=$(hook session-start "$J_S" "$HL" RAM_CRIT_MB=99999999)
if has "$OUT" "RAM is critical"; then ok "session-start: one line when memory is critical"; else no "session-start critical" "$OUT"; fi
OUT=$(hook session-start '{"session_id":"s-start2"}' RAM_LOG_DIR="$T/stoplog" RAM_WARN_MB=0 RAM_CRIT_MB=0)
O2=$(hook pre-bash '{"session_id":"s-start2","tool_input":{"command":"ls"}}' RAM_LOG_DIR="$T/stoplog")
if has "$OUT" "stopped a job in the last 6 hours" && [ -z "$O2" ]; then ok "session-start: tells of a recent stop, and pre-bash does not repeat it"; else no "session-start stop" "$OUT / $O2"; fi
# CLAUDE_ENV_FILE: the hook runs again on resume and compaction, so the line must not repeat; an owner's RAM_SH wins.
EF="$T/session.env"
echo 'export OTHER=kept' >"$EF"
for s in s-env s-env; do hook session-start "{\"session_id\":\"$s\"}" "$HL" CLAUDE_ENV_FILE="$EF" >/dev/null; done
hook session-start '{"session_id":"s-env-off"}' "$HL" CLAUDE_ENV_FILE="$T/off.env" RAM_SH=off >/dev/null
GOT=$(bash -c '. "$1" && echo "$OTHER $RAM_SH"' _ "$EF")
if [ "$(grep -c RAM_SH "$EF")" = 1 ] && [ "$GOT" = "kept $(cd "$ROOT" && pwd -P)/skills/ram/scripts/ram.sh" ] \
  && [ ! -e "$T/off.env" ]; then
  ok "session-start: adds export RAM_SH=<this ram.sh> to CLAUDE_ENV_FILE once, and leaves an owner's RAM_SH alone"
else no "session-start and CLAUDE_ENV_FILE" "got: $GOT / $(cat "$EF") / off.env: $(cat "$T/off.env" 2>&1)"; fi
# The watchdog option on: a fake bash first on PATH writes down the start call instead of running it. Fake
# systemd-run and systemctl catch the call too if the fake bash ever missed it, so nothing real can start.
FB="$T/fakebin"
mkdir -p "$FB"
RB=$(command -v bash)
printf '#!%s\nif [ "${2:-}" = watch ]; then echo "$* RAM_KILL=${RAM_KILL:-unset}" >>"%s"; exit 0; fi\nexec "%s" "$@"\n' \
  "$RB" "$T/start.rec" "$RB" >"$FB/bash"
printf '#!/bin/sh\necho "$*" >>"%s"\nexit 0\n' "$T/sd.rec" >"$FB/systemd-run"
cp "$FB/systemd-run" "$FB/systemctl"
chmod +x "$FB/bash" "$FB/systemd-run" "$FB/systemctl"
OUT=$(hook session-start '{"session_id":"s-on"}' "$HL" RAM_WARN_MB=0 RAM_CRIT_MB=0 PATH="$FB:$PATH" CLAUDE_PLUGIN_OPTION_WATCHDOG=true)
O2=$(hook session-start '{"session_id":"s-on2"}' "$HL" RAM_WARN_MB=0 RAM_CRIT_MB=0 PATH="$FB:$PATH" CLAUDE_PLUGIN_OPTION_WATCHDOG=true CLAUDE_PLUGIN_OPTION_STOP_JOBS=false)
n=0
while [ "$n" -lt 30 ] && [ "$(cat "$T/start.rec" 2>/dev/null | wc -l | tr -d ' ')" -lt 2 ]; do sleep 0.1; n=$((n + 1)); done
REC=$(cat "$T/start.rec" 2>/dev/null)
if [ -z "$OUT$O2" ] && has "$REC" "ram.sh watch --start RAM_KILL=unset" && has "$REC" "ram.sh watch --start RAM_KILL=0" && [ ! -e "$T/sd.rec" ]; then
  ok "session-start: the watchdog option on starts it (detached, silent); stop_jobs off passes RAM_KILL=0"
else no "session-start with the watchdog option on" "out: $OUT$O2 / start calls: $REC / systemd: $(cat "$T/sd.rec" 2>/dev/null)"; fi

OUT=$(printf 'not json' | node "$HOOK" pre-bash)
c1=$?
O2=$(printf '{}' | node "$HOOK" no-such-mode 2>"$T/usage.err")
c2=$?
if [ "$c1" = 0 ] && [ -z "$OUT" ] && [ "$c2" = 0 ] && [ -z "$O2" ] && grep -q '^usage: ' "$T/usage.err"; then
  ok "the hook stays silent and exits 0 on bad input; an unknown mode gets the usage line on stderr, exit 0"
else no "bad input" "$c1 $OUT / $c2 $O2 / $(cat "$T/usage.err")"; fi
MS=$(node -e '
  const { spawnSync } = require("child_process"), t = (j) => { const t0 = Date.now();
    for (let i = 0; i < 5; i++) spawnSync(process.execPath, [process.argv[1], "pre-bash"], { input: j, env: { ...process.env, RAM_WARN_MB: "0" } });
    return Math.round((Date.now() - t0) / 5); };
  console.log(t(process.argv[2]) + " " + t(process.argv[3]));' "$HOOK" "$J_LS" "$J_HEAVY")
set -- $MS
if [ "${1:-9999}" -lt 1500 ] && [ "${2:-9999}" -lt 3000 ]; then ok "pre-bash takes about ${1} ms for ls and ${2} ms for a heavy command (it asks ram.sh)"; else no "pre-bash is slow: $MS ms"; fi

# ---------------------------------------------------------------- doctor

echo "== doctor"
mkdir -p "$T/app/android" "$T/app/.claude/worktrees/one" "$T/app/.claude/worktrees/two"
GP="$T/app/android/gradle.properties"
cp "$FIX/gradle-template.properties" "$GP"
: >"$T/app/pubspec.yaml"
OUT=$(bash "$RAM" doctor "$T/app" 2>&1)
if has "$OUT" "WARN android/gradle.properties gives Gradle -Xmx8G" && has "$OUT" "WARN no kotlin.daemon.jvmargs" \
  && has "$OUT" "WARN 2 worktrees" && cmp -s "$GP" "$FIX/gradle-template.properties"; then
  ok "doctor flags the 8 GB heap, the Kotlin daemon and 2 worktrees, and changes nothing"
else no "doctor flags" "$OUT"; fi
bash "$RAM" doctor "$T/app" --fix >/dev/null 2>&1
BAK=$(ls "$GP".bak-* 2>/dev/null | head -n 1)
if grep -qx 'org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g -XX:ReservedCodeCacheSize=512m -XX:+HeapDumpOnOutOfMemoryError' "$GP" \
  && grep -qx 'kotlin.daemon.jvmargs=-Xmx1g' "$GP" && grep -qx 'org.gradle.daemon.idletimeout=900000' "$GP" \
  && grep -qx 'android.useAndroidX=true' "$GP" && [ -n "$BAK" ] && cmp -s "$BAK" "$FIX/gradle-template.properties"; then
  ok "doctor --fix rewrites gradle.properties and keeps the old one as a backup"
else no "doctor --fix" "$(cat "$GP")"; fi
OUT=$(bash "$RAM" doctor "$T/app" 2>&1)
if has "$OUT" "ok   Gradle heap: -Xmx3g" && ! has "$OUT" "WARN no kotlin"; then ok "doctor is content after the fix"; else no "doctor after the fix" "$OUT"; fi
mkdir -p "$T/small/android"
SP="$T/small/android/gradle.properties"
cp "$FIX/gradle-small.properties" "$SP"
bash "$RAM" doctor "$T/small" --fix >/dev/null 2>&1
if grep -qx 'org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=512m' "$SP" && grep -qx 'kotlin.daemon.jvmargs=-Xmx1g' "$SP"; then
  ok "fix 3: doctor --fix keeps a smaller heap (-Xmx2g, 512m) and adds only the missing lines"
else no "fix 3" "$(cat "$SP")"; fi
# A JVM whose -Xms is bigger than its -Xmx does not start. Each row puts its jvmargs into a copy of the fixture.
mkdir -p "$T/xms/android"
XP="$T/xms/android/gradle.properties"
bad=""
while IFS='|' read -r before after; do
  sed "s/^org\.gradle\.jvmargs=.*/org.gradle.jvmargs=$before/" "$FIX/gradle-xms.properties" >"$XP"
  bash "$RAM" doctor "$T/xms" --fix >/dev/null 2>&1
  grep -qx -- "org.gradle.jvmargs=$after" "$XP" || bad="$bad${bad:+; }$before gave $(grep jvmargs "$XP")"
done <<'EOF'
-Xms4g -Xmx8G -XX:MaxMetaspaceSize=4G -Dfile.encoding=UTF-8|-Xms3g -Xmx3g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8
-Xms512m -Xmx8G|-Xms512m -Xmx3g
-Xms4096m -Dfile.encoding=UTF-8|-Xmx3g -Xms3g -Dfile.encoding=UTF-8
EOF
if [ -z "$bad" ]; then ok "doctor --fix brings a bigger -Xms down to the new -Xmx3g, and keeps a smaller one"
else no "doctor --fix and -Xms" "$bad"; fi

# ---------------------------------------------------------------- the watchdog

if [ -n "$TO" ]; then
  echo "== the watchdog (about 10 s)"
  bash "$RAM" run --no-cap --name wd-victim -- sleep 60 2>"$T/victim.err" &
  VPID=$!
  n=0
  while [ "$n" -lt 50 ] && [ -z "$(ls "$RAM_STATE_DIR/jobs" 2>/dev/null)" ]; do sleep 0.1; n=$((n + 1)); done
  OUT=$(RAM_WARN_MB=0 bash "$RAM" check heavy)
  if has "$OUT" "another heavy job runs in the queue (wd-victim)"; then ok "check heavy: deny while a queued job runs, naming it"; else no "check heavy with a job" "$OUT"; fi
  OUT=$(bash "$RAM" jobs)
  if has "$OUT" "wd-victim"; then ok "jobs lists the queued job"; else no "jobs" "$OUT"; fi
  OUT=$(bash "$RAM" run --no-cap --wait 0 -- true 2>&1)
  code=$?
  if [ "$code" = 75 ] && has "$OUT" "another queued job ran in this folder"; then ok "run: one job per folder (a second one gives up with 75)"; else no "folder lock (exit $code)" "$OUT"; fi
  RAM_CRIT_MB=99999999 RAM_INTERVAL_S=1 "$TO" 8 bash "$RAM" watch --foreground >"$T/wd.out" 2>&1
  wait "$VPID"
  vcode=$?
  EV=$(cat "$RAM_LOG_DIR/events.log" 2>/dev/null)
  if has "$EV" "STOP job=" && has "$EV" "what='wd-victim'" && has "$(cat "$T/victim.err")" "stopped by the RAM watchdog" && [ "$vcode" != 0 ]; then
    ok "the watchdog at a forced critical level stops the queued job and logs it (the job ended with $vcode)"
  else no "the watchdog stop (job exit $vcode)" "$EV"; fi
  if ! has "$EV" "STOP pid="; then ok "the watchdog stopped nothing else"; else no "the watchdog stopped a process" "$(grep 'STOP pid=' "$RAM_LOG_DIR/events.log")"; fi
  if [ -n "$FAKE" ]; then
    if kill -0 "$FAKE" 2>/dev/null; then ok "the watchdog at a forced critical level left the fake Gradle daemon alone"; else no "the watchdog stopped the fake Gradle daemon"; fi
  fi
  OUT=$(bash "$RAM" last 2>&1)
  if has "$OUT" "snapshot:" && has "$OUT" "free="; then ok "last prints the snapshot the watchdog wrote"; else no "last" "$OUT"; fi
else skipped "the watchdog cases (no timeout command)"; fi
[ -z "$FAKE" ] || kill "$FAKE" 2>/dev/null

echo "passed $pass, failed $fail, skipped $skip ($SECONDS s)"
[ "$fail" = 0 ]
