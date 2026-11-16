#!/usr/bin/env bash
# ram.sh: keeps one machine alive while AI agents, builds and tests share its memory.
#
# usage:
#   ram.sh status                     free memory, pressure, who uses it, the watchdog, the queue
#   ram.sh run [options] -- CMD...    runs a heavy command in the machine-wide queue, under a memory cap
#   ram.sh free [--dry-run] [--all]   stops what is safe to stop: idle build daemons, orphaned test runners
#   ram.sh watch --start | --stop | --status | --foreground
#   ram.sh jobs                       the jobs the queue runs now
#   ram.sh last                       what used the memory just before the last reboot or freeze
#   ram.sh doctor [DIR] [--fix]       settings that make this machine or a project use too much memory
#   ram.sh check heavy|agent|level    for the hooks: "ok" or "deny <reason>"; level: "ok|low|critical FREE WARN CRIT"
#   ram.sh install-service            (Linux) starts the watchdog at every login, as a systemd user service
#   ram.sh uninstall-service
#
# run options: --need MB (free memory to wait for) · --max MB (the memory cap) · --alone (wait until no
# other queued job runs; builds do this by default) · --name LABEL · --timeout SECONDS · --wait SECONDS
# (give up after waiting this long) · --no-cap
#
# Settings come from the environment, then from the owner's file
# ~/.config/perfect-vibecoding-ram/ram.env (shell syntax, for example RAM_SLOTS=1). See the defaults below.
#
# Why the watchdog exists: on a desktop with zram swap, a full memory freezes the screen for minutes long
# before the kernel or systemd-oomd kills anything, and systemd-oomd then kills a whole app group (the editor
# with every AI session in it). The watchdog acts earlier and smaller: it stops the newest AI-started job.
set -u

RAM_SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
RAM_CONFIG="${RAM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/perfect-vibecoding-ram/ram.env}"
# Every setting the environment or ram.env may give.
RAM_SETTINGS="RAM_WARN_MB RAM_CRIT_MB RAM_HEAVY_MIN_MB RAM_AGENT_MIN_MB RAM_RESERVE_MB RAM_SLOTS RAM_JOB_MAX_MB
  RAM_BUILD_MAX_MB RAM_JOB_SWAP_MB RAM_KILL RAM_INTERVAL_S RAM_WAIT_S RAM_PSI_CRIT RAM_PROTECT RAM_NOTIFY
  RAM_MIN_STOP_MB RAM_STOP_DAEMONS RAM_STATE_DIR RAM_LOG_DIR"
if [ -r "$RAM_CONFIG" ]; then
  # The environment wins over the file: a one-off "RAM_KILL=0 ram.sh watch --start", or the plugin option that
  # passes it, must work even when ram.env sets the same name.
  ram_env_set=""
  for v in $RAM_SETTINGS; do
    if [ -n "${!v+x}" ]; then ram_env_set="$ram_env_set $v"; printf -v "RAM_ENV_$v" '%s' "${!v}"; fi
  done
  # shellcheck disable=SC1090
  . "$RAM_CONFIG"
  for v in $ram_env_set; do w="RAM_ENV_$v"; printf -v "$v" '%s' "${!w}"; done
fi

OS="$(uname -s)"
UIDN="$(id -u)"
STATE_DIR="${RAM_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/perfect-vibecoding-ram-$UIDN}"
LOG_DIR="${RAM_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/perfect-vibecoding-ram}"
EVENTS="$LOG_DIR/events.log"   # one line per level change and per stopped job; survives a reboot
SNAPS="$LOG_DIR/snapshots.log" # the biggest processes every few minutes; tells what ate the memory before a freeze
(umask 077 && mkdir -p "$STATE_DIR/jobs" "$STATE_DIR/slots" "$LOG_DIR") || {
  echo "ram: cannot create $STATE_DIR or $LOG_DIR" >&2
  exit 2
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- memory readings

MEM_TOTAL_MB=0 MEM_AVAIL_MB=0 SWAP_TOTAL_MB=0 SWAP_FREE_MB=0 PSI_SOME=0 PSI_FULL=0

# Reads /proc with bash builtins only: the watchdog calls this every 2 seconds and must not fork.
read_mem() {
  if [ -r /proc/meminfo ]; then
    local k v _
    while read -r k v _; do
      case $k in
        MemTotal:) MEM_TOTAL_MB=$((v / 1024)) ;;
        MemAvailable:) MEM_AVAIL_MB=$((v / 1024)) ;;
        SwapTotal:) SWAP_TOTAL_MB=$((v / 1024)) ;;
        SwapFree:) SWAP_FREE_MB=$((v / 1024)) ;;
      esac
    done </proc/meminfo
  elif [ "$OS" = Darwin ]; then
    MEM_TOTAL_MB=$(($(sysctl -n hw.memsize) / 1048576))
    # Free, inactive, speculative and purgeable pages: what macOS can hand out without swapping.
    MEM_AVAIL_MB=$(vm_stat | awk '/page size of/ {ps = $8}
      /Pages (free|inactive|speculative|purgeable)/ {gsub(/\./, "", $NF); n += $NF}
      END {print int(n * ps / 1048576)}')
    # "total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)"
    set -- $(sysctl -n vm.swapusage 2>/dev/null | tr -d 'M')
    SWAP_TOTAL_MB=${3%.*}
    SWAP_FREE_MB=${9%.*}
  fi
}

# Memory pressure (Linux PSI): the share of the last 10 s in which tasks stalled waiting for memory.
read_psi() {
  [ -r /proc/pressure/memory ] || return 0
  local kind a _
  while read -r kind a _; do
    a=${a#avg10=}
    a=${a%%.*}
    case $kind in
      some) PSI_SOME=$a ;;
      full) PSI_FULL=$a ;;
    esac
  done </proc/pressure/memory
}

read_mem
T=$MEM_TOTAL_MB
max2() { if [ "$1" -gt "$2" ]; then echo "$1"; else echo "$2"; fi; }

# ---------------------------------------------------------------- settings (defaults scale with the RAM)

: "${RAM_WARN_MB:=$(max2 $((T * 15 / 100)) 2000)}"      # below: the hooks refuse new agents and unqueued heavy jobs
: "${RAM_CRIT_MB:=$(max2 $((T * 7 / 100)) 900)}"        # below: the watchdog stops AI-started jobs, newest first
: "${RAM_HEAVY_MIN_MB:=$(max2 $((T * 20 / 100)) 1500)}" # a queued heavy job starts only with this much free
: "${RAM_AGENT_MIN_MB:=$(max2 $((T * 16 / 100)) 1500)}" # a new agent or workflow starts only with this much free
: "${RAM_RESERVE_MB:=$(max2 $((T * 30 / 100)) 4096)}"   # kept for the desktop, the editor and the AI sessions
if [ -z "${RAM_SLOTS:-}" ]; then                         # heavy jobs that may run at once
  if [ "$T" -le 9000 ]; then RAM_SLOTS=1; elif [ "$T" -le 17000 ]; then RAM_SLOTS=2
  elif [ "$T" -le 33000 ]; then RAM_SLOTS=3; else RAM_SLOTS=4; fi
fi
# What the queue may give its jobs. At least a third of the RAM: on a machine under about 4.3 GB the reserve alone
# is bigger than the RAM, and a negative cap would stop every command.
RAM_FOR_JOBS=$(max2 $((T - RAM_RESERVE_MB)) $((T / 3)))
: "${RAM_JOB_MAX_MB:=$((RAM_FOR_JOBS / RAM_SLOTS))}" # the cap of one queued job
: "${RAM_BUILD_MAX_MB:=$RAM_FOR_JOBS}"               # the cap of a build, which runs alone
: "${RAM_JOB_SWAP_MB:=512}"   # swap one capped job may use: more would push the desktop into swap
: "${RAM_KILL:=1}"            # 1: the watchdog may stop AI-started jobs at the critical level; 0: it only warns
: "${RAM_INTERVAL_S:=2}"      # how often the watchdog reads the memory
: "${RAM_WAIT_S:=2400}"       # how long a queued job waits for a slot and memory before it gives up (exit 75)
: "${RAM_PSI_CRIT:=10}"       # below the warn level, a full-stall share at or over this also counts as critical
: "${RAM_PROTECT:=}"          # extended regex: command lines that are never stopped (for example a dev server)
: "${RAM_NOTIFY:=1}"          # 1: a desktop notification when the watchdog stops something
: "${RAM_MIN_STOP_MB:=200}"   # the watchdog never stops an unqueued process smaller than this
: "${RAM_STOP_DAEMONS:=1}"    # 0: the watchdog and ram.sh free leave Gradle and Kotlin daemons alone (the tests set it)

for v in RAM_WARN_MB RAM_CRIT_MB RAM_HEAVY_MIN_MB RAM_AGENT_MIN_MB RAM_RESERVE_MB RAM_SLOTS RAM_JOB_MAX_MB \
  RAM_BUILD_MAX_MB RAM_JOB_SWAP_MB RAM_INTERVAL_S RAM_WAIT_S RAM_PSI_CRIT RAM_MIN_STOP_MB; do
  case ${!v} in '' | *[!0-9]*)
    echo "ram: $v must be a whole number (it is '${!v}'); check $RAM_CONFIG" >&2
    exit 2
    ;;
  esac
done
[ "$RAM_SLOTS" -ge 1 ] || RAM_SLOTS=1

# ---------------------------------------------------------------- small helpers

mb() { awk -v m="$1" 'BEGIN { if (m >= 1024) printf "%.1f GB", m / 1024; else printf "%d MB", m }'; }

now() { date +%s; }

rotate() { # keeps a log file under $2 lines by dropping its older half
  local n
  n=$(wc -l <"$1" 2>/dev/null || echo 0)
  if [ "${n// /}" -gt "$2" ]; then
    tail -n "$(($2 / 2))" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
  fi
}

event() { # epoch first, so the hooks can tell which lines are new
  echo "$(now) $(date '+%F %T') $*" >>"$EVENTS"
  rotate "$EVENTS" 2000
}

notify() {
  [ "$RAM_NOTIFY" = 1 ] || return 0
  if have notify-send; then
    notify-send -u critical -a "RAM guard" "RAM guard" "$1" >/dev/null 2>&1 &
  elif have osascript; then
    osascript -e "display notification \"$1\" with title \"RAM guard\"" >/dev/null 2>&1 &
  fi
}

user_manager_ok() { [ "$OS" = Linux ] && have systemd-run && systemctl --user show-environment >/dev/null 2>&1; }

# Every process as one tab-separated line: pid ppid uid rss_kb age_s name args.
# Two ps calls, each with its variable-width column last: names and command lines both hold spaces
# ("Isolated Web Co", "/Applications/Visual Studio Code.app/..."), so neither can sit in the middle.
ps_table() {
  local tmp="$STATE_DIR/ps.$$"
  ps -A -o pid=,comm= >"$tmp.c" 2>/dev/null
  ps -A -o pid=,ppid=,uid=,rss=,etime=,args= >"$tmp.a" 2>/dev/null
  awk -v OFS='\t' '
    function secs(s,   d, a, n, i, t) {
      d = 0
      if (index(s, "-")) { split(s, a, "-"); d = a[1]; s = a[2] }
      n = split(s, a, ":"); t = 0
      for (i = 1; i <= n; i++) t = t * 60 + a[i]
      return d * 86400 + t
    }
    FNR == NR { p = $1; c = $0; sub(/^[ \t]*[0-9]+[ \t]+/, "", c); n = split(c, q, "/"); name[p] = q[n]; next }
    {
      a = $0
      for (i = 1; i <= 5; i++) sub(/^[ \t]*[^ \t]+/, "", a)
      sub(/^[ \t]+/, "", a)
      print $1, $2, $3, $4, secs($5), ($1 in name ? name[$1] : "?"), a
    }' "$tmp.c" "$tmp.a"
  rm -f "$tmp.c" "$tmp.a"
}

# The awk functions that sort processes into kinds and find what an AI session started.
# A process "from AI" descends from a Claude Code process: the commands its Bash tool runs, and their children.
CLASSIFY_AWK='
  function kind(p,   c, a) {
    c = nm[p]; a = ar[p]
    if (isai[p]) return "ai"
    if (c ~ /^(agy|codex|gemini|aider|opencode|cursor-agent)$/) return "ai"
    if (a ~ /modelcontextprotocol|(^|[\/ -])mcp([-_ ]|$)|mcp-server/) return "mcp"
    if (c ~ /^(code|code-insiders|codium|cursor|windsurf|zed|studio|nvim|emacs)$/ || a ~ /com\.intellij|android-studio/) return "editor"
    if (c ~ /^java/ && a ~ /GradleDaemon|org\.gradle\.launcher\.daemon/) return "gradle"
    if (c ~ /^java/ && a ~ /KotlinCompileDaemon|kotlin-daemon/) return "kotlin"
    if (c ~ /^java/) return "java"
    if (c ~ /^(dart|flutter_tester|frontend_server|dartvm|dartaotruntime)/ || a ~ /flutter_tools\.snapshot|frontend_server/) return "dart"
    if (c ~ /^qemu-system|^emulator/ || a ~ /\/emulator\/qemu/) return "emulator"
    if (c ~ /^(node|next-server|bun|deno|npm|pnpm|yarn|tsc|esbuild|vite)/) return "node"
    if (a ~ /--headless|playwright|puppeteer/) return "browser"
    if (c ~ /^(chrome|chromium|firefox|brave|msedge|opera|vivaldi|Isolated Web|Web Content|WebExtensions|GeckoMain|Privileged)/ || a ~ /(firefox|chrome|chromium|brave)[^ ]*( |$)/) return "browser"
    if (c ~ /^(gnome-shell|Xwayland|Xorg|plasmashell|kwin|mutter|gnome-software|nautilus|tracker-miner|evolution|gsd-|WindowServer|Finder|Dock)/) return "desktop"
    return "other"
  }
  function load() {
    pid = $1; pp[pid] = $2; uid[pid] = $3; rss[pid] = int($4 / 1024); age[pid] = $5; nm[pid] = $6; ar[pid] = $7
    if ($6 == "claude" || $7 ~ /(^|\/)claude( |$)/ || $7 ~ /@anthropic-ai\/claude-code/) isai[pid] = 1
  }
  function mark(   p, q, n) {
    for (p in pp) {
      q = pp[p]; n = 0; fromai[p] = 0
      while (q > 1 && n < 100) { if (q in isai) { fromai[p] = 1; break }; q = pp[q]; n++ }
    }
  }
'

# ---------------------------------------------------------------- the queue: ram.sh run

usage_run() {
  echo "usage: ram.sh run [--need MB] [--max MB] [--alone] [--name LABEL] [--timeout S] [--wait S] [--no-cap] -- CMD..." >&2
  exit 2
}

is_build() {
  case " $* " in
    *" flutter build "* | *gradlew* | *" gradle "* | *" assemble"* | *" bundle"* | *xcodebuild* | *" next build "* | \
      *" run build "* | *" pnpm build "* | *" yarn build "* | *" bun run build "* | *" docker build "* | *" podman build "*) return 0 ;;
  esac
  return 1
}

busy_slots() {
  local n=0 i=1
  have flock || { echo 0; return; }
  while [ "$i" -le "$RAM_SLOTS" ]; do
    if ! flock -n "$STATE_DIR/slots/slot.$i" true 2>/dev/null; then n=$((n + 1)); fi
    i=$((i + 1))
  done
  echo "$n"
}

# In a job's subshell: drops the slot locks a build (--alone) holds on fds 21 and up, however many slots there are.
close_slot_fds() {
  local i=1
  while [ "$i" -le "$RAM_SLOTS" ]; do eval "exec $((20 + i))>&-"; i=$((i + 1)); done
}

job_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

job_alive() { # a job file whose ram.sh is gone is stale: remove it
  local pid
  pid=$(job_get "$1" pid)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  rm -f "$1" "$1.peak"
  return 1
}

run_abort() {
  if [ -n "${RUN_UNIT:-}" ] && user_manager_ok; then
    systemctl --user kill --signal=SIGTERM "$RUN_UNIT.scope" 2>/dev/null
  fi
  [ -n "${RUN_CHILD:-}" ] && kill -TERM "$RUN_CHILD" 2>/dev/null
  echo "ram: stopped, and the job with it" >&2
  exit 143
}

cmd_run() {
  local need="" cap="" label="" timeout_s=0 nocap=0 wait_s="$RAM_WAIT_S" alone=0
  while [ $# -gt 0 ]; do
    case $1 in
      --need) [ $# -ge 2 ] || usage_run; need=$2; shift 2 ;;
      --max) [ $# -ge 2 ] || usage_run; cap=$2; shift 2 ;;
      --name) [ $# -ge 2 ] || usage_run; label=$2; shift 2 ;;
      --timeout) [ $# -ge 2 ] || usage_run; timeout_s=$2; shift 2 ;;
      --wait) [ $# -ge 2 ] || usage_run; wait_s=$2; shift 2 ;;
      --alone) alone=1; shift ;;
      --no-cap) nocap=1; shift ;;
      --) shift; break ;;
      -*) usage_run ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || usage_run
  for v in "$need" "$cap" "$timeout_s" "$wait_s"; do
    case $v in *[!0-9]*) echo "ram: numbers only for --need, --max, --timeout and --wait" >&2; exit 2 ;; esac
  done
  if is_build "$@"; then
    alone=1
    [ -n "$cap" ] || cap=$RAM_BUILD_MAX_MB
    [ -n "$need" ] || need=$(max2 "$RAM_HEAVY_MIN_MB" 4000)
  fi
  [ -n "$cap" ] || cap=$RAM_JOB_MAX_MB
  [ -n "$need" ] || need=$RAM_HEAVY_MIN_MB
  [ -n "$label" ] || label=$(printf '%s ' "$@" | cut -c1-70 | sed 's/ *$//')

  # One job per folder: two Flutter, Gradle or Next.js runs in one folder fight over build/, .dart_tool/, .next/.
  local key start=$SECONDS slot="" said=0 lastsay=0 i
  key=$(pwd -P | cksum | cut -d' ' -f1)
  if have flock; then
    exec 8>"$STATE_DIR/slots/dir.$key"
    if ! flock -w "$wait_s" 8; then
      echo "ram: another queued job ran in this folder for $wait_s s; gave up" >&2
      return 75
    fi
  fi
  while :; do
    read_mem
    if [ "$MEM_AVAIL_MB" -ge "$need" ]; then
      if ! have flock; then
        slot=0
      elif [ "$alone" = 1 ]; then
        # A build takes every slot, so nothing else heavy runs beside it.
        i=1 slot=all
        while [ "$i" -le "$RAM_SLOTS" ]; do
          eval "exec $((20 + i))>\"\$STATE_DIR/slots/slot.$i\""
          if ! flock -n $((20 + i)); then slot=""; fi
          i=$((i + 1))
        done
        if [ -z "$slot" ]; then
          i=1
          while [ "$i" -le "$RAM_SLOTS" ]; do eval "exec $((20 + i))>&-"; i=$((i + 1)); done
        fi
      else
        i=1
        while [ "$i" -le "$RAM_SLOTS" ]; do
          exec 9>"$STATE_DIR/slots/slot.$i"
          if flock -n 9; then slot=$i; break; fi
          exec 9>&-
          i=$((i + 1))
        done
      fi
      [ -n "$slot" ] && break
    fi
    if [ $((SECONDS - start)) -ge "$wait_s" ]; then
      echo "ram: gave up after $wait_s s: $(mb "$MEM_AVAIL_MB") free (needs $(mb "$need")), $(busy_slots) of $RAM_SLOTS slots busy" >&2
      return 75
    fi
    # One line now, then one a minute: a waiting job must not flood an AI's context.
    if [ "$said" = 0 ] || [ $((SECONDS - lastsay)) -ge 60 ]; then
      echo "ram: waiting: $(mb "$MEM_AVAIL_MB") free (needs $(mb "$need")), $(busy_slots) of $RAM_SLOTS slots busy" >&2
      said=1
      lastsay=$SECONDS
    fi
    sleep 3
  done

  local id jf unit="" scope=0 code t0=$SECONDS sampler=""
  id="$(now)-$$"
  jf="$STATE_DIR/jobs/$id"
  if [ "$nocap" = 0 ] && user_manager_ok; then
    scope=1
    unit="ram-job-$id"
  fi
  printf 'pid=%s\nunit=%s\nlabel=%s\ndir=%s\nstart=%s\ncap=%s\n' "$$" "$unit" "$label" "$(pwd -P)" "$(now)" "$cap" >"$jf"
  # Globals: the traps run after this function's locals are gone.
  RUN_JOB_FILE=$jf
  RUN_SAMPLER=""
  RUN_UNIT=$unit
  RUN_CHILD=""
  trap 'rm -f "$RUN_JOB_FILE" "$RUN_JOB_FILE.peak" "$RUN_JOB_FILE.peak.tmp"; [ -n "$RUN_SAMPLER" ] && kill "$RUN_SAMPLER" 2>/dev/null; true' EXIT
  # Stopped itself (a tool timeout, Ctrl+C)? Stop the job too: an orphaned job would run on outside the queue.
  trap 'run_abort' TERM INT HUP

  local -a tmo=()
  if [ "$timeout_s" -gt 0 ]; then
    if have timeout; then tmo=(timeout --kill-after=30 "$timeout_s")
    elif have gtimeout; then tmo=(gtimeout --kill-after=30 "$timeout_s")
    else echo "ram: no timeout command here; running without --timeout" >&2; fi
  fi

  echo "ram: running '$label' (cap $(mb "$cap"), $(mb "$MEM_AVAIL_MB") free)" >&2
  if [ "$scope" = 1 ]; then
    # Samples the job's peak memory and the kernel's kill count from its own cgroup.
    (
      cg="" n=0
      while [ -z "$cg" ] && [ "$n" -lt 40 ]; do
        cg=$(systemctl --user show -p ControlGroup --value "$unit.scope" 2>/dev/null)
        [ -n "$cg" ] || sleep 0.25
        n=$((n + 1))
      done
      f="/sys/fs/cgroup$cg"
      while [ -n "$cg" ] && [ -d "$f" ]; do
        p=$(cat "$f/memory.peak" 2>/dev/null || cat "$f/memory.current" 2>/dev/null || echo 0)
        o=$(awk '/^oom_kill / {print $2}' "$f/memory.events" 2>/dev/null)
        echo "$((p / 1048576)) ${o:-0}" >"$jf.peak.tmp" && mv "$jf.peak.tmp" "$jf.peak"
        sleep 2
      done
    ) 8>&- 9>&- &
    sampler=$!
    RUN_SAMPLER=$sampler
    # oom_score_adj 1000: if the kernel must kill something anyway, it kills this job first, never the desktop.
    # Started in the background and waited for, with stdin passed on: bash then prints no long "Killed" line,
    # and a stop signal for ram.sh reaches run_abort at once.
    # The job gets none of the lock fds: a daemon it starts (Gradle, Kotlin) would hold a slot for hours.
    (
      close_slot_fds
      exec systemd-run --user --scope --quiet --collect --unit="$unit" \
        -p MemoryMax="${cap}M" -p MemorySwapMax="${RAM_JOB_SWAP_MB}M" -- \
        bash -c 'echo 1000 >/proc/self/oom_score_adj 2>/dev/null; exec "$@"' ram-job ${tmo[@]+"${tmo[@]}"} "$@"
    ) <&0 8>&- 9>&- &
    RUN_CHILD=$!
    wait "$RUN_CHILD" 2>/dev/null
    code=$?
  else
    (
      close_slot_fds
      echo 1000 >/proc/self/oom_score_adj 2>/dev/null
      exec ${tmo[@]+"${tmo[@]}"} "$@"
    ) <&0 8>&- 9>&- &
    RUN_CHILD=$!
    wait "$RUN_CHILD" 2>/dev/null
    code=$?
  fi

  local peak="" ooms=0 mins
  if [ -r "$jf.peak" ]; then read -r peak ooms <"$jf.peak"; fi
  mins=$(((SECONDS - t0) / 60))
  # A job killed within 2 s of its start leaves no kill count behind: a peak at the cap tells the same.
  if [ "$code" = 137 ] && [ -n "$peak" ] && [ "$peak" -ge $((cap * 95 / 100)) ]; then ooms=${ooms:-1}; [ "$ooms" -gt 0 ] || ooms=1; fi
  if grep -q " job=$id " "$EVENTS" 2>/dev/null; then
    echo "ram: '$label' was stopped by the RAM watchdog: the machine ran out of memory (ram.sh last tells what used it)" >&2
  elif [ "${ooms:-0}" -gt 0 ]; then
    echo "ram: '$label' went over its cap of $(mb "$cap"), so the kernel stopped part of it. Use less memory (fewer workers, a smaller heap), or a bigger --max only if the machine has room" >&2
  fi
  echo "ram: '$label' exit $code ($mins min${peak:+, peak $(mb "$peak")})" >&2
  return "$code"
}

# ---------------------------------------------------------------- stopping things

stop_pid() { # TERM, then KILL after 3 s
  kill -TERM "$1" 2>/dev/null || return 0
  local n=0
  while [ "$n" -lt 6 ]; do
    sleep 0.5
    kill -0 "$1" 2>/dev/null || return 0
    n=$((n + 1))
  done
  kill -KILL "$1" 2>/dev/null
  sleep 0.3
}

stop_tree() { # a process and everything under it, children first
  local root=$1 kids
  kids=$(ps_table | awk -F'\t' -v r="$root" '
    { pp[$1] = $2 }
    END { for (p in pp) { q = p; n = 0; while (q > 1 && n < 100) { if (pp[q] == r) { print p; break }; q = pp[q]; n++ } } }')
  for k in $kids; do kill -TERM "$k" 2>/dev/null; done
  stop_pid "$root"
  for k in $kids; do kill -KILL "$k" 2>/dev/null; done
}

stop_job() { # $1 job file, $2 why
  local unit pid label
  unit=$(job_get "$1" unit)
  pid=$(job_get "$1" pid)
  label=$(job_get "$1" label)
  read_mem
  event "STOP job=$(basename "$1") what='$label' free=${MEM_AVAIL_MB}MB why=$2"
  notify "Stopped '$label': only $(mb "$MEM_AVAIL_MB") of memory were free."
  if [ -n "$unit" ] && user_manager_ok; then
    systemctl --user kill --signal=SIGTERM "$unit.scope" 2>/dev/null
    sleep 3
    systemctl --user kill --signal=SIGKILL "$unit.scope" 2>/dev/null
  else
    # The queued command runs as a child of ram.sh: stop the children, ram.sh then reports and exits.
    ps_table | awk -F'\t' -v r="$pid" '$2 == r {print $1}' | while read -r k; do stop_tree "$k"; done
  fi
}

# Listening processes: servers (a dev server, a mock API) are stopped only as a last resort.
server_pids() {
  if have ss; then
    ss -lptnH 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' '
  elif have lsof; then
    lsof -nP -iTCP -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u | tr '\n' ' '
  fi
}

# Prints the next process to stop: "pid<TAB>MB<TAB>what". Order: build daemons (biggest first), then
# AI-started heavy processes (newest first), then, only when $1 is "last", AI-started servers and emulators.
pick_victim() {
  local mode=$1
  ps_table | awk -F'\t' -v me="$UIDN" -v self="$$" -v minmb="$RAM_MIN_STOP_MB" -v mode="$mode" \
    -v servers=" $(server_pids) " -v protect="$RAM_PROTECT" -v daemons="$RAM_STOP_DAEMONS" "$CLASSIFY_AWK"'
    { load() }
    END {
      mark()
      best = ""; bt = 9; bkey = 0
      for (p in pp) {
        if (uid[p] != me || p == self || p in isai) continue
        k = kind(p)
        if (k ~ /^(ai|mcp|editor|desktop)$/) continue
        if (protect != "" && ar[p] ~ protect) continue
        if (ar[p] ~ /ram\.sh/) continue
        srv = index(servers, " " p " ") > 0
        if (k == "gradle" || k == "kotlin") { if (daemons == "0") continue; t = 1; key = rss[p] }
        else if (fromai[p] && rss[p] >= minmb && !srv && k != "emulator") { t = 2; key = 1000000000 - age[p] }
        else if (mode == "last" && fromai[p] && rss[p] >= minmb) { t = 3; key = rss[p] }
        else continue
        if (t < bt || (t == bt && key > bkey)) { best = p; bt = t; bkey = key }
      }
      if (best != "") {
        what = (kind(best) == "gradle" ? "Gradle daemon" : kind(best) == "kotlin" ? "Kotlin daemon" : nm[best])
        printf "%s\t%d\t%s %s\n", best, rss[best], what, substr(ar[best], 1, 60)
      }
    }'
}

# One step of relief: the newest queued job, else the best victim. Returns 1 when nothing can be stopped.
relieve() {
  local jf newest="" nt=0 t
  for jf in "$STATE_DIR"/jobs/*; do
    case $jf in *.peak | *.tmp) continue ;; esac
    [ -f "$jf" ] && job_alive "$jf" || continue
    t=$(job_get "$jf" start)
    if [ "${t:-0}" -gt "$nt" ]; then newest=$jf; nt=$t; fi
  done
  if [ -n "$newest" ]; then
    stop_job "$newest" "critical"
    return 0
  fi
  local mode=normal line pid mbs what
  [ "$MEM_AVAIL_MB" -lt $((RAM_CRIT_MB / 2)) ] && mode=last
  line=$(pick_victim "$mode")
  [ -n "$line" ] || return 1
  pid=${line%%$'\t'*}
  mbs=$(echo "$line" | cut -f2)
  what=$(echo "$line" | cut -f3)
  event "STOP pid=$pid what='$what' rss=${mbs}MB free=${MEM_AVAIL_MB}MB why=critical"
  notify "Stopped $what ($(mb "$mbs")): only $(mb "$MEM_AVAIL_MB") of memory were free."
  stop_tree "$pid"
  return 0
}

cmd_free() {
  local dry=0 all=0
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1 ;;
      --all) all=1 ;;
      *) echo "usage: ram.sh free [--dry-run] [--all]" >&2; exit 2 ;;
    esac
    shift
  done
  read_mem
  local before=$MEM_AVAIL_MB tsv list
  tsv=$(ps_table)
  # Build daemons are caches: the next build starts them again. Idle ones (no CPU used in 3 s) go first;
  # --all stops busy ones too (their build fails). Orphaned test runners and headless browsers (their parent
  # is gone) serve nobody.
  list=$(printf '%s\n' "$tsv" | awk -F'\t' -v me="$UIDN" -v daemons="$RAM_STOP_DAEMONS" "$CLASSIFY_AWK"'
    { load() }
    END {
      mark()
      for (p in pp) {
        if (uid[p] != me || p in isai) continue
        k = kind(p)
        if ((k == "gradle" || k == "kotlin") && daemons == "0") continue
        if (k == "gradle" || k == "kotlin") { print p "\tdaemon\t" rss[p] "\t" (k == "gradle" ? "Gradle daemon" : "Kotlin daemon"); continue }
        orphan = (pp[p] == 1 || nm[pp[p]] == "systemd" || nm[pp[p]] == "launchd")
        if (orphan && (nm[p] ~ /^(flutter_tester|frontend_server)/ || ar[p] ~ /vitest|jest-worker|playwright|--headless|flutter_tools\.snapshot test/))
          print p "\torphan\t" rss[p] "\t" nm[p] " (orphaned)"
      }
    }')
  if [ -z "$list" ]; then
    echo "ram: nothing safe to stop ($(mb "$MEM_AVAIL_MB") free). ram.sh status shows who uses the memory."
    return 0
  fi
  local pid kind mbs what t1 t2 freed=0 n=0
  while IFS=$'\t' read -r pid kind mbs what; do
    if [ "$kind" = daemon ] && [ "$all" = 0 ]; then
      t1=$(ps -o time= -p "$pid" 2>/dev/null)
      sleep 3
      t2=$(ps -o time= -p "$pid" 2>/dev/null)
      if [ "$t1" != "$t2" ]; then
        echo "kept: $what $pid ($(mb "$mbs")): it is working now (--all stops it, and its build fails)"
        continue
      fi
    fi
    if [ "$dry" = 1 ]; then
      echo "would stop: $what $pid ($(mb "$mbs"))"
    else
      stop_pid "$pid"
      echo "stopped: $what $pid ($(mb "$mbs"))"
      event "FREE pid=$pid what='$what' rss=${mbs}MB"
    fi
    freed=$((freed + mbs))
    n=$((n + 1))
  done <<EOF
$list
EOF
  if [ "$dry" = 1 ]; then
    echo "ram: would stop $n process(es), about $(mb "$freed")"
  else
    sleep 1
    read_mem
    echo "ram: stopped $n process(es); free memory $(mb "$before") -> $(mb "$MEM_AVAIL_MB")"
  fi
}

# ---------------------------------------------------------------- the watchdog

watch_pid() {
  local pid
  pid=$(cat "$STATE_DIR/watch.pid" 2>/dev/null) || return 1
  case $pid in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -o args= -p "$pid" 2>/dev/null | grep -q 'watch --foreground' || return 1
  echo "$pid"
}

snapshot() {
  {
    echo "=== $(now) $(date '+%F %T') free=${MEM_AVAIL_MB}MB of ${MEM_TOTAL_MB}MB swap_used=$((SWAP_TOTAL_MB - SWAP_FREE_MB))MB psi_some=$PSI_SOME psi_full=$PSI_FULL"
    ps_table | sort -t "$(printf '\t')" -k4,4nr | head -8 |
      awk -F'\t' '{ printf "  %7s %6d MB  %-16s %s\n", $1, $4 / 1024, $6, substr($7, 1, 90) }'
  } >>"$SNAPS"
  rotate "$SNAPS" 4000
}

watch_loop() {
  if have flock; then
    exec 7>"$STATE_DIR/watch.lock"
    flock -n 7 || { echo "ram: the watchdog already runs"; return 0; }
  elif watch_pid >/dev/null; then
    echo "ram: the watchdog already runs"
    return 0
  fi
  echo $$ >"$STATE_DIR/watch.pid"
  trap 'rm -f "$STATE_DIR/watch.pid"; exit 0' TERM INT
  event "WATCH start warn=${RAM_WARN_MB}MB crit=${RAM_CRIT_MB}MB stop_jobs=$RAM_KILL slots=$RAM_SLOTS"
  local level prev=OK last_snap=-100000 every win_t0=$SECONDS stops=0
  echo "OK $MEM_AVAIL_MB $(now)" >"$STATE_DIR/level"
  while :; do
    read_mem
    read_psi
    if [ "$MEM_AVAIL_MB" -lt "$RAM_CRIT_MB" ] || { [ "$MEM_AVAIL_MB" -lt "$RAM_WARN_MB" ] && [ "$PSI_FULL" -ge "$RAM_PSI_CRIT" ]; }; then
      level=CRIT
    elif [ "$MEM_AVAIL_MB" -lt "$RAM_WARN_MB" ]; then
      level=WARN
    else
      level=OK
    fi
    if [ "$level" != "$prev" ]; then
      event "LEVEL $level free=${MEM_AVAIL_MB}MB psi_full=$PSI_FULL"
      echo "$level $MEM_AVAIL_MB $(now)" >"$STATE_DIR/level"
      prev=$level
    fi
    if [ "$level" = OK ]; then every=300; else every=30; fi
    if [ $((SECONDS - last_snap)) -ge "$every" ]; then
      snapshot
      last_snap=$SECONDS
    fi
    if [ "$level" = CRIT ] && [ "$RAM_KILL" = 1 ]; then
      # At most 4 stops a minute: memory takes a moment to come back, and one stop is usually enough.
      if [ $((SECONDS - win_t0)) -ge 60 ]; then win_t0=$SECONDS; stops=0; fi
      if [ "$stops" -lt 4 ]; then
        snapshot
        if relieve; then stops=$((stops + 1)); sleep 3; continue; fi
      fi
    fi
    sleep "$RAM_INTERVAL_S"
  done
}

start_watchdog() {
  local pid
  if pid=$(watch_pid); then
    echo "ram: the watchdog runs (pid $pid)"
    return 0
  fi
  if user_manager_ok; then
    # A transient user service: outside the editor's group, so the watchdog outlives an editor crash.
    systemctl --user reset-failed perfect-vibecoding-ram-watch.service >/dev/null 2>&1
    local -a envs=()
    # The service does not inherit this shell's environment: pass on every setting the watchdog reads.
    for v in RAM_CONFIG RAM_STATE_DIR RAM_LOG_DIR RAM_WARN_MB RAM_CRIT_MB RAM_KILL RAM_SLOTS RAM_PROTECT RAM_NOTIFY \
      RAM_INTERVAL_S RAM_PSI_CRIT RAM_MIN_STOP_MB RAM_STOP_DAEMONS; do
      if [ -n "${!v+x}" ]; then envs+=(-E "$v=${!v}"); fi
    done
    systemd-run --user --quiet --collect --unit=perfect-vibecoding-ram-watch ${envs[@]+"${envs[@]}"} \
      bash "$RAM_SCRIPT" watch --foreground >/dev/null 2>&1
  elif have setsid; then
    setsid nohup bash "$RAM_SCRIPT" watch --foreground >/dev/null 2>&1 </dev/null &
  else
    nohup bash "$RAM_SCRIPT" watch --foreground >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null
  fi
  local n=0
  while [ "$n" -lt 20 ]; do
    if pid=$(watch_pid); then
      echo "ram: the watchdog started (pid $pid): warns below $(mb "$RAM_WARN_MB") free, stops AI-started jobs below $(mb "$RAM_CRIT_MB")"
      return 0
    fi
    sleep 0.25
    n=$((n + 1))
  done
  echo "ram: the watchdog did not start; run it by hand to see why: bash $RAM_SCRIPT watch --foreground" >&2
  return 1
}

stop_watchdog() {
  local pid
  if user_manager_ok && systemctl --user is-active --quiet perfect-vibecoding-ram.service 2>/dev/null; then
    echo "ram: the watchdog runs as the login service: ram.sh uninstall-service stops it for good" >&2
  fi
  if pid=$(watch_pid); then
    kill "$pid" 2>/dev/null
    echo "ram: the watchdog stopped (pid $pid)"
  else
    echo "ram: the watchdog was not running"
  fi
}

cmd_watch() {
  case ${1:---status} in
    --start) start_watchdog ;;
    --stop) stop_watchdog ;;
    --foreground) watch_loop ;;
    --status)
      local pid
      if pid=$(watch_pid); then echo "ram: the watchdog runs (pid $pid)"; else echo "ram: the watchdog is not running"; return 1; fi
      ;;
    *) echo "usage: ram.sh watch --start | --stop | --status | --foreground" >&2; exit 2 ;;
  esac
}

# ---------------------------------------------------------------- reports

cmd_jobs() {
  local jf any=0 st
  for jf in "$STATE_DIR"/jobs/*; do
    case $jf in *.peak | *.tmp) continue ;; esac
    [ -f "$jf" ] && job_alive "$jf" || continue
    st=$(job_get "$jf" start)
    echo "  $(job_get "$jf" label) · $(basename "$(job_get "$jf" dir)") · $((($(now) - st) / 60)) min · cap $(mb "$(job_get "$jf" cap)")"
    any=1
  done
  [ "$any" = 1 ] || echo "  no queued job runs"
}

cmd_status() {
  read_mem
  read_psi
  local level="OK" pct=$((MEM_AVAIL_MB * 100 / (MEM_TOTAL_MB > 0 ? MEM_TOTAL_MB : 1))) pid
  if [ "$MEM_AVAIL_MB" -lt "$RAM_CRIT_MB" ]; then level=CRITICAL; elif [ "$MEM_AVAIL_MB" -lt "$RAM_WARN_MB" ]; then level=LOW; fi
  echo "RAM: $(mb "$MEM_AVAIL_MB") free of $(mb "$MEM_TOTAL_MB") ($pct%) · swap used $(mb $((SWAP_TOTAL_MB - SWAP_FREE_MB))) of $(mb "$SWAP_TOTAL_MB") · stalls: some ${PSI_SOME}%, full ${PSI_FULL}% · $level"
  if pid=$(watch_pid); then
    echo "watchdog: runs (pid $pid) · refuses new heavy work below $(mb "$RAM_WARN_MB") free · stops AI-started jobs below $(mb "$RAM_CRIT_MB")$([ "$RAM_KILL" = 1 ] || echo ' (stopping is OFF)')"
  else
    echo "watchdog: NOT running · start it: bash $RAM_SCRIPT watch --start"
  fi
  echo "queue: $RAM_SLOTS slots, $(busy_slots) busy · a job is capped at $(mb "$RAM_JOB_MAX_MB"), a build at $(mb "$RAM_BUILD_MAX_MB")"
  cmd_jobs
  # PSS (proportional set size) splits shared pages between the processes that share them, so the groups add
  # up; RSS counts a shared page once per process and makes a multi-process editor look several times bigger.
  ps_table | awk -F'\t' -v me="$UIDN" "$CLASSIFY_AWK"'
    function pss(p,   f, line, v) {
      f = "/proc/" p "/smaps_rollup"; v = -1
      while ((getline line < f) > 0) if (line ~ /^Pss:/) { split(line, x, " "); v = int(x[2] / 1024); break }
      close(f)
      return v
    }
    { load() }
    END {
      mark()
      label["ai"] = "AI sessions"; label["mcp"] = "MCP servers"; label["editor"] = "editors"; label["gradle"] = "Gradle daemons"
      label["kotlin"] = "Kotlin daemons"; label["java"] = "other Java"; label["dart"] = "Dart and Flutter"
      label["emulator"] = "emulators"; label["node"] = "Node"; label["browser"] = "browsers"; label["desktop"] = "desktop"
      label["other"] = "other"
      for (p in pp) {
        m = (uid[p] == me) ? pss(p) : -1
        if (m < 0) m = rss[p]
        k = kind(p); sum[k] += m; cnt[k]++; mem[p] = m
        if (fromai[p] && k != "ai" && k != "mcp") { aisum += m }
      }
      print "by group:"
      n = 0
      while (n < 7) {
        bk = ""; bv = -1
        for (k in sum) if (!(k in done) && sum[k] > bv) { bk = k; bv = sum[k] }
        if (bk == "" || bv < 50) break
        done[bk] = 1; n++
        printf "  %-18s %4d proc  %7.1f GB\n", label[bk], cnt[bk], bv / 1024
      }
      printf "  started by AI agents (tests, builds, servers): %.1f GB\n", aisum / 1024
      print "biggest processes:"
      n = 0
      while (n < 6) {
        bp = ""; bv = -1
        for (p in mem) if (!(p in shown) && mem[p] > bv) { bp = p; bv = mem[p] }
        if (bp == "") break
        shown[bp] = 1; n++
        printf "  %7s %6d MB  %-16s%s %s\n", bp, bv, nm[bp], (fromai[bp] ? " [AI]" : ""), substr(ar[bp], 1, 70)
      }
    }'
  if [ "$level" != OK ]; then
    echo "next: wait for queued jobs to end · ram.sh free stops idle build daemons · ask the owner to close what they do not use"
  fi
}

cmd_last() {
  local boot
  if [ -r /proc/stat ]; then boot=$(awk '/^btime/ {print $2}' /proc/stat)
  else boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/'); fi
  [ -r "$SNAPS" ] || { echo "ram: no snapshot yet (the watchdog writes them)"; return 0; }
  awk -v boot="${boot:-0}" '
    /^=== / { if (cur != "" && t < boot) keep = cur; t = $2; cur = $0 "\n"; next }
    { cur = cur $0 "\n" }
    END { if (cur != "" && t < boot) keep = cur; if (keep == "") keep = cur; printf "%s", keep }' "$SNAPS" |
    sed '1s/^=== [0-9]* /snapshot: /'
  if [ -r "$EVENTS" ]; then
    echo "watchdog events before this boot:"
    awk -v boot="${boot:-0}" '$1 < boot && $1 > boot - 3600 { $1 = ""; print " " $0 }' "$EVENTS" | tail -n 12
  fi
}

# ---------------------------------------------------------------- doctor

cmd_doctor() {
  local dir="" fix=0
  while [ $# -gt 0 ]; do
    case $1 in
      --fix) fix=1 ;;
      -*) echo "usage: ram.sh doctor [DIR] [--fix]" >&2; exit 2 ;;
      *) dir=$1 ;;
    esac
    shift
  done
  [ -n "$dir" ] || dir=$PWD
  read_mem
  echo "machine: $(mb "$MEM_TOTAL_MB") RAM, $(mb "$SWAP_TOTAL_MB") swap, $(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu) CPUs"
  [ "$SWAP_TOTAL_MB" -gt 0 ] || echo "  WARN no swap: a full memory kills a process at once. Fedora and Ubuntu use zram swap by default."
  if watch_pid >/dev/null; then echo "  ok   the watchdog runs"; else echo "  WARN the watchdog is not running: bash $RAM_SCRIPT watch --start"; fi
  if have oomctl; then
    local lim
    lim=$(oomctl 2>/dev/null | awk '/app\.slice$/ {f = 1} f && /Memory Pressure Limit/ {print $4; exit}')
    [ -n "$lim" ] && echo "  info systemd-oomd acts only at $lim memory pressure, and kills a whole app group (the editor and its AI sessions): the watchdog acts earlier and smaller"
  fi
  if [ -r /proc/sys/kernel/sysrq ]; then
    local sr
    sr=$(cat /proc/sys/kernel/sysrq)
    if [ "$sr" != 1 ] && [ $((sr & 64)) = 0 ]; then
      echo "  info Alt+SysRq+F (kill the biggest process) is off (kernel.sysrq=$sr). Optional rescue for a frozen desktop: see freeze.md"
    fi
  fi
  local tsv
  tsv=$(ps_table)
  printf '%s\n' "$tsv" | awk -F'\t' -v me="$UIDN" "$CLASSIFY_AWK"'
    { load() }
    END {
      for (p in pp) { k = kind(p); if (uid[p] == me) { s[k] += rss[p]; c[k]++ } }
      if (c["ai"] > 0) printf "  info %d AI session processes use %.1f GB; a long conversation grows: start new sessions\n", c["ai"], s["ai"] / 1024
      if (s["editor"] > 4096) printf "  WARN editors hold %.1f GB (RSS): close the windows you do not use\n", s["editor"] / 1024
      if (s["gradle"] + s["kotlin"] > 0) printf "  info build daemons hold %.1f GB: ram.sh free stops the idle ones\n", (s["gradle"] + s["kotlin"]) / 1024
      if (c["emulator"] > 0) printf "  info an Android emulator runs (%.1f GB): close it when no one tests on it\n", s["emulator"] / 1024
    }'

  echo "project: $dir"
  local gp="$dir/android/gradle.properties"
  if [ -f "$gp" ]; then
    local jvm xmx meta
    jvm=$(sed -n 's/^[[:space:]]*org\.gradle\.jvmargs[[:space:]]*=[[:space:]]*//p' "$gp" | tail -1)
    xmx=$(printf '%s' "$jvm" | grep -oE -- '-Xmx[0-9]+[gGmM]' | tail -1)
    meta=$(printf '%s' "$jvm" | grep -oE -- '-XX:MaxMetaspaceSize=[0-9]+[gGmM]' | tail -1)
    local xmx_mb=0 meta_mb=0 bad=0
    case $xmx in *[gG]) xmx_mb=$((${xmx//[^0-9]/} * 1024)) ;; *[mM]) xmx_mb=${xmx//[^0-9]/} ;; esac
    case $meta in *[gG]) meta_mb=$((${meta//[^0-9]/} * 1024)) ;; *[mM]) meta_mb=${meta//[^0-9]/} ;; esac
    if [ "$xmx_mb" -gt 3072 ]; then
      echo "  WARN android/gradle.properties gives Gradle $xmx of heap${meta:+ and $meta}: Flutter's template asks 8 GB, and the Kotlin daemon copies it. Use -Xmx3g -XX:MaxMetaspaceSize=1g"
      bad=1
    elif [ "$meta_mb" -gt 1024 ]; then
      echo "  WARN android/gradle.properties: $meta is more than a Flutter build needs; use -XX:MaxMetaspaceSize=1g"
      bad=1
    else
      echo "  ok   Gradle heap: ${xmx:-the default}"
    fi
    if ! grep -q '^[[:space:]]*kotlin\.daemon\.jvmargs' "$gp"; then
      echo "  WARN no kotlin.daemon.jvmargs: the Kotlin daemon takes the same heap as Gradle. Add kotlin.daemon.jvmargs=-Xmx1g"
      bad=1
    fi
    if ! grep -q '^[[:space:]]*org\.gradle\.daemon\.idletimeout' "$gp"; then
      echo "  info an idle Gradle daemon stays 3 hours. Add org.gradle.daemon.idletimeout=900000 (15 minutes)"
      bad=1
    fi
    if [ "$fix" = 1 ] && [ "$bad" = 1 ]; then
      local bak
      bak="$gp.bak-$(date +%Y%m%d-%H%M%S)"
      cp "$gp" "$bak"
      # Lower only what is too big: a smaller heap or metaspace the owner chose stays as it is.
      local newjvm=${jvm:--Xmx3g}
      if [ "$xmx_mb" -gt 3072 ]; then newjvm=$(printf '%s' "$newjvm" | sed -E 's/-Xmx[0-9]+[gGmM]/-Xmx3g/g'); fi
      if [ "$meta_mb" -gt 1024 ]; then
        newjvm=$(printf '%s' "$newjvm" | sed -E 's/-XX:MaxMetaspaceSize=[0-9]+[gGmM]/-XX:MaxMetaspaceSize=1g/g')
      fi
      case $newjvm in *-Xmx*) ;; *) newjvm="-Xmx3g $newjvm" ;; esac
      awk -v j="$newjvm" '
        /^[[:space:]]*org\.gradle\.jvmargs[[:space:]]*=/ { if (!d) print "org.gradle.jvmargs=" j; d = 1; next }
        { print }
        END { if (!d) print "org.gradle.jvmargs=" j }' "$bak" >"$gp"
      grep -q '^[[:space:]]*kotlin\.daemon\.jvmargs' "$gp" || echo "kotlin.daemon.jvmargs=-Xmx1g" >>"$gp"
      grep -q '^[[:space:]]*org\.gradle\.daemon\.idletimeout' "$gp" || echo "org.gradle.daemon.idletimeout=900000" >>"$gp"
      echo "  fixed android/gradle.properties (backup: $bak). Running Gradle daemons keep the old heap: ram.sh free --all"
    fi
  fi
  if [ -f "$dir/pubspec.yaml" ]; then
    echo "  info flutter test runs about one test process per CPU core: pass --concurrency=2 while agents work"
  fi
  if [ -d "$dir/.claude/worktrees" ]; then
    local nwt
    nwt=$(find "$dir/.claude/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "$nwt" -gt 0 ]; then
      echo "  WARN $nwt worktrees in .claude/worktrees: an editor that opens this folder may analyze each copy. Exclude them (freeze.md, 'Editor settings'), and remove the ones you no longer need"
    fi
  fi
  if [ -d "$dir/.vscode" ] || [ -f "$dir/pubspec.yaml" ] || [ -f "$dir/package.json" ]; then
    if ! grep -qs 'watcherExclude' "$dir/.vscode/settings.json"; then
      echo "  info no files.watcherExclude in .vscode/settings.json: VS Code watches build/, .dart_tool/, node_modules/ and the worktrees (freeze.md, 'Editor settings')"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------- checks for the hooks

# Prints "ok", or "deny <reason>". Fast: no process scan.
cmd_check() {
  local what=${1:-}
  read_mem
  local jobs=0 jf labels=""
  for jf in "$STATE_DIR"/jobs/*; do
    case $jf in *.peak | *.tmp) continue ;; esac
    [ -f "$jf" ] && job_alive "$jf" || continue
    jobs=$((jobs + 1))
    labels="$labels${labels:+; }$(job_get "$jf" label)"
  done
  case $what in
    agent)
      if [ "$MEM_AVAIL_MB" -lt "$RAM_AGENT_MIN_MB" ]; then
        echo "deny $(mb "$MEM_AVAIL_MB") of memory free; a new agent needs $(mb "$RAM_AGENT_MIN_MB"). Wait for the running agents or jobs to end${labels:+ (queued now: $labels)}, run 'bash $RAM_SCRIPT free' to stop idle build daemons, or ask the owner to close apps. 'bash $RAM_SCRIPT status' shows who uses it."
      else
        echo ok
      fi
      ;;
    heavy)
      if [ "$MEM_AVAIL_MB" -lt "$RAM_WARN_MB" ] || [ "$jobs" -gt 0 ]; then
        local why
        if [ "$jobs" -gt 0 ]; then why="another heavy job runs in the queue ($labels)"; else why="only $(mb "$MEM_AVAIL_MB") of memory is free"; fi
        echo "deny $why. Queue it: it waits for memory and a free slot, then runs under a memory cap: bash $RAM_SCRIPT run -- <the same command>. A wait can be long: start it with the Bash tool's background option."
      else
        echo ok
      fi
      ;;
    level)
      # For the session hook: the same levels as the watchdog, from this file's thresholds and ram.env.
      read_psi
      local lv=ok
      if [ "$MEM_AVAIL_MB" -lt "$RAM_CRIT_MB" ] || { [ "$MEM_AVAIL_MB" -lt "$RAM_WARN_MB" ] && [ "$PSI_FULL" -ge "$RAM_PSI_CRIT" ]; }; then
        lv=critical
      elif [ "$MEM_AVAIL_MB" -lt "$RAM_WARN_MB" ]; then
        lv=low
      fi
      echo "$lv $MEM_AVAIL_MB $RAM_WARN_MB $RAM_CRIT_MB"
      ;;
    *) echo "usage: ram.sh check heavy|agent|level" >&2; exit 2 ;;
  esac
}

# ---------------------------------------------------------------- login service

cmd_install_service() {
  user_manager_ok || { echo "ram: this needs Linux with a systemd user session" >&2; return 2; }
  local dest="${XDG_DATA_HOME:-$HOME/.local/share}/perfect-vibecoding-ram" units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$dest" "$units"
  # A copy that plugin updates cannot move or delete under the running service.
  cp "$RAM_SCRIPT" "$dest/ram.sh" && chmod 755 "$dest/ram.sh"
  cat >"$units/perfect-vibecoding-ram.service" <<EOF
[Unit]
Description=RAM watchdog for AI coding: stops AI-started jobs before the memory runs out

[Service]
ExecStart=/usr/bin/env bash $dest/ram.sh watch --foreground
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  local pid
  if pid=$(watch_pid); then kill "$pid" 2>/dev/null; sleep 0.5; fi
  systemctl --user daemon-reload && systemctl --user enable --now perfect-vibecoding-ram.service &&
    echo "ram: the watchdog now starts at every login (copy in $dest; run install-service again after a plugin update)"
}

cmd_uninstall_service() {
  user_manager_ok || { echo "ram: no systemd user session here" >&2; return 2; }
  systemctl --user disable --now perfect-vibecoding-ram.service 2>/dev/null
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/perfect-vibecoding-ram.service"
  systemctl --user daemon-reload
  echo "ram: the login service is removed"
}

# ---------------------------------------------------------------- main

usage() {
  sed -n '3,14p' "$RAM_SCRIPT" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -gt 0 ] || usage
cmd=$1
shift
case $cmd in
  status) cmd_status ;;
  run) cmd_run "$@" ;;
  free) cmd_free "$@" ;;
  watch) cmd_watch "$@" ;;
  jobs) cmd_jobs ;;
  last) cmd_last ;;
  doctor) cmd_doctor "$@" ;;
  check) cmd_check "$@" ;;
  install-service) cmd_install_service ;;
  uninstall-service) cmd_uninstall_service ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
