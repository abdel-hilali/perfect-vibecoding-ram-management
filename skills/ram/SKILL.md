---
name: ram
description: Keeps the PC from freezing when AI agents, builds and tests share its memory. A machine-wide queue runs heavy jobs one by one under a memory cap, a watchdog stops the newest AI-started job before the memory runs out, and hooks refuse new agents and unqueued heavy commands when memory is low. Use when you run tests, builds, analyzers or an emulator, before you start agents or a workflow, when the PC is slow or froze, or when a hook or the watchdog stopped something.
---

# RAM: keep the machine alive

One PC runs the owner's editor, a browser, several AI sessions and the tests and builds they start. When the memory
is full, the screen freezes for minutes before anything is killed, and the owner may have to power off and lose
work. These rules keep the memory in budget. `scripts/ram.sh` in this skill's folder does the work.

## The rules

1. **Check before heavy work.** Run `ram.sh status` before a build, a whole test suite, an emulator or new agents.
   It shows free memory, who uses it, the watchdog and the queue.
2. **Heavy jobs go through the queue:** `ram.sh run -- <command>`. It waits for free memory and a free slot, runs
   the job under a memory cap and prints its peak. A wait can last minutes: run it as a background task, wait for
   its end, and never start the same job a second time beside it.
3. **One build at a time.** A build (`flutter build`, `flutter drive`, `flutter test integration_test`, `gradlew`,
   `next build`, `xcodebuild`, `docker build`) takes the whole queue. Start no second build and no emulator beside it.
4. **Never more agents than the memory allows.** Each agent is one more session that grows with its conversation,
   plus the tests it runs. Start agents one by one, and only while `ram.sh check agent` says `ok`. On `deny`, wait
   for a running agent to end.
5. **Small jobs.** Test the files you changed, not the whole suite. Use `flutter test --concurrency=2` and
   `vitest --maxWorkers=2` while agents work. `costs.md` lists the memory per job and the settings that cut it.
6. **Kill by PID, never by name.** `pkill -f flutter` also kills the editor's tools and other sessions' jobs. Find
   the PID in `ram.sh status` and stop only that process: `kill <pid>`. `ram.sh free` stops idle build daemons safely.
7. **Tell the owner** when a job was stopped, when memory stays low, and when a setting wastes memory (see below).

## What the queue does

- One heavy job per slot (1 slot up to 9 GB of RAM, 2 up to 17 GB, 3 up to 33 GB, then 4), and one job per folder:
  two runs in one folder fight over `build/`, `.dart_tool/` and `.next/`.
- A job starts only when enough memory is free (20% of the RAM, and at least 4 GB for a build). It gives up with
  exit 75 after 40 minutes (`--wait` changes that).
- On a machine that cannot free 4 GB when idle (the RAM less the reserve), a build waits for what it can free, and
  `run` warns that a Flutter build may freeze such a machine. `--need` still sets the wait.
- On Linux each job runs in its own memory cap, with little swap. A job that goes over its cap is stopped alone,
  and the desktop lives. The kernel also kills a queued job first if it must kill anything.
- When the job ends, `run` prints its exit code, its time and its peak memory. Use the peak to size the next run.

## What the watchdog does, and never does

The watchdog (`ram.sh watch --start`) reads the memory every 2 seconds. It is a small bash process outside the
editor, so it outlives an editor crash.

- **Low** (under about 15% of the RAM free): it only logs. The hooks refuse new agents and unqueued heavy commands.
- **Critical** (under about 7%, or low with long memory stalls): it stops one thing at a time, at most 4 a minute,
  in this order:
  1. the newest queued job;
  2. Gradle and Kotlin daemons, the biggest first (they are caches: the next build starts them again);
  3. the newest heavy process (over 200 MB) that an AI session started;
  4. only as a last resort, under half the critical level: an AI-started server or emulator.
- It **never** stops the editor, the desktop, an AI session, an MCP server, a process the owner started outside
  the queue (build daemons aside), or a command line that matches the owner's `RAM_PROTECT` pattern.
- Each stop goes to the log, and a desktop notification tells the owner. Every few minutes it writes the biggest
  processes to a snapshot log, so `ram.sh last` can tell after a freeze what used the memory.
- It never changes a setting, never runs as root and never kills by name.

## When a hook says no

- **"deny ... Queue it"**: run the same command through `ram.sh run -- <command>`.
- **"deny ... A long-lived job"** (an emulator, `flutter run`): never queue it; it would hold a slot all its life.
  Wait until `ram.sh check heavy` prints `ok`, then start it detached.
- **"deny ... a new agent needs ..."**: do not start the agent. Wait for running work to end, run `ram.sh free`,
  or ask the owner to close what they do not use.
- **"the RAM watchdog stopped ..."**: that job did not finish, and its result is missing. Tell the owner. Rerun it
  only through the queue, once `ram.sh status` shows room. Never rerun it at once outside the queue.

## What to tell the owner

- Which job was stopped and why, and that `ram.sh last` shows what used the memory.
- That memory stays low, and what holds it (the groups in `ram.sh status`): an editor window they do not use,
  browser tabs, an emulator, idle build daemons.
- The `ram.sh doctor` findings for their project: an 8 GB Gradle heap, no Kotlin heap limit, many old worktrees,
  no editor exclusions. `doctor --fix` rewrites `android/gradle.properties` (with a backup): run it only with their yes.
  It lowers a bigger `-Xms` with the heap: a JVM whose `-Xms` is over its `-Xmx` does not start.
- After a freeze: the steps in `freeze.md`.

Never change the machine yourself (sysctl, systemd, swap, the login service). Suggest the change, explain its
trade-off, and let the owner run it.

## Commands

| Command | What it does |
| --- | --- |
| `ram.sh status` | Free memory, stalls, memory per group, biggest processes, watchdog, queue |
| `ram.sh run [options] -- CMD` | Runs CMD in the queue under a cap. Options below |
| `ram.sh jobs` | The queued jobs that run now |
| `ram.sh free [--dry-run] [--all]` | Stops idle Gradle and Kotlin daemons and orphaned test runners |
| `ram.sh watch --start`, `--stop`, `--status` | Starts, stops or shows the watchdog |
| `ram.sh last` | What used the memory just before the last reboot, and the watchdog's events |
| `ram.sh doctor [DIR] [--fix]` | Settings of the machine and of a project that waste memory |
| `ram.sh check heavy`, `agent`, `level` | For the hooks: `ok`, `deny <reason>`, or the level |
| `ram.sh install-service` | For the owner only: starts the watchdog at every login |

`run` options: `--need MB` (free memory to wait for), `--max MB` (the cap), `--alone` (no other queued job beside
it; builds do this), `--name LABEL`, `--timeout S`, `--wait S` (give up after), `--no-cap`.

`run` exit codes: the job's own; 75 when it gave up waiting; 137 or 143 when its cap or the watchdog stopped it
(the last lines say which).

## Settings

Environment variables, or the owner's file `~/.config/perfect-vibecoding-ram/ram.env` (shell syntax, for example
`RAM_SLOTS=1`). The environment wins over the file. The defaults scale with the RAM.

| Setting | Default | Meaning |
| --- | --- | --- |
| `RAM_SLOTS` | 1 to 4 | Heavy jobs at once |
| `RAM_WARN_MB` | 15% | Below it, the hooks refuse new heavy work |
| `RAM_CRIT_MB` | 7% | Below it, the watchdog stops jobs |
| `RAM_KILL` | 1 | 0: the watchdog only warns |
| `RAM_PROTECT` | none | Extended regex of command lines never stopped, for example a dev server |
| `RAM_JOB_MAX_MB`, `RAM_BUILD_MAX_MB` | from the RAM | The cap of a job and of a build |
| `RAM_WAIT_S` | 2400 | How long a queued job waits before it gives up |
| `RAM_NOTIFY` | 1 | 0: no desktop notification |

In Claude Code: the plugin's hooks call this script for you. At session start they start the watchdog (unless the
`watchdog` option is off; `stop_jobs` off makes it only warn); before the Agent, Task and Workflow tools they run
`check agent`; before a heavy Bash command that is not queued they run `check heavy`, and a deny comes back with
its reason. They also tell you, once, about each job the watchdog stopped, and they put `RAM_SH` (this script's
path) into the session's Bash environment, where other kits' tools look for it first. Run the script as
`bash ${CLAUDE_SKILL_DIR}/scripts/ram.sh <command>`. For a queued job that may wait, set the Bash tool's
`run_in_background` option and read the output when the task ends; do not poll it in a loop or start it twice.
The owner changes the two options in `/config`.
