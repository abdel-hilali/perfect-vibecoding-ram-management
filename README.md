# perfect-vibecoding-ram-management

A Claude Code plugin that keeps a developer PC from freezing when several AI agents, builds and tests share its
memory.

## What it does

- **A machine-wide queue.** `ram.sh run -- <command>` waits for free memory and a free slot, runs the job under a
  memory cap, and prints its peak memory when it ends. One build at a time (`flutter drive` and integration tests
  count as builds), and one job per folder. A build waits for 4 GB free, or on a smaller machine for what it can
  free when idle, with a warning that a Flutter build may freeze such a machine.
- **A watchdog.** It reads the memory every 2 seconds. At the critical level it stops the newest AI-started job
  before the desktop freezes. It never stops the editor, the desktop, an AI session or an MCP server.
- **Hooks.** They refuse a new agent when memory is low, and an unqueued heavy command (tests, builds, analyzers, an
  emulator) when memory is low or a queued job runs. A long-lived job (an emulator, `flutter run`) must never be
  queued: its deny says to start it detached once there is room. They tell Claude once about each job the watchdog
  stopped, and they put `RAM_SH` (the plugin's `ram.sh`) into the session's environment, where the Flutter kit's
  tools look for it first.
- **A skill**, `/perfect-vibecoding-ram-management:ram`: the rules for agents, what each job costs in memory, and
  what to do after a freeze.
- **A doctor.** `ram.sh doctor` finds settings that waste memory (an 8 GB Gradle heap, no Kotlin heap limit, old
  worktrees, no editor exclusions). With your yes, `doctor --fix` rewrites `android/gradle.properties` and keeps a
  backup. When it lowers the heap, it lowers a bigger `-Xms` too: a JVM whose `-Xms` is over its `-Xmx` does not start.

## Why

A full memory rarely crashes a Linux desktop: it freezes it. With zram swap, the kernel compresses memory instead
of failing, every program waits, and the screen stops for minutes before anything is killed. On one measured
machine (15 GB of RAM, 8 GB of zram swap), systemd-oomd acted only at 80% memory pressure held for 20 seconds, and
then killed a whole app group: the editor with every AI session inside it. The logs showed freezes that ended with
a power-off and no out-of-memory kill at all. The editor held 5 to 8 GB, Flutter's Android template gave Gradle an
8 GB heap (copied again by the Kotlin daemon), and AI sessions inside the editor grew with their conversations.

The plugin acts earlier and smaller: it keeps heavy jobs in a queue with caps, and stops the newest AI-started job,
not the editor.

## Install

Run this once:

```bash
claude plugin install perfect-vibecoding-ram-management --marketplace abdel-hilali/perfect-vibecoding-ram-management --scope user
```

`--scope user` turns it on in every project: the memory belongs to the machine, not to one project. Use
`--scope project` instead to turn it on for one repository (then commit `.claude/settings.json`). This one-step form
needs a recent Claude Code (v2.1.292 or later). On an older one, add the marketplace first:

```bash
claude plugin marketplace add abdel-hilali/perfect-vibecoding-ram-management
claude plugin install perfect-vibecoding-ram-management@perfect-vibecoding-ram-management --scope user
```

Prefer to click? Inside a Claude Code session:

```text
/plugin marketplace add abdel-hilali/perfect-vibecoding-ram-management
/plugin install perfect-vibecoding-ram-management@perfect-vibecoding-ram-management
```

The plugin's page lists what it adds, the hooks included: read it, since hooks run commands on your machine.

The next session starts the watchdog. To start it now, or to run any command yourself, use the script from a clone
of this repository: `bash skills/ram/scripts/ram.sh status`. Inside Claude Code, ask for it and Claude uses the
plugin's copy.

### Plugin options

| Option | Default | What it does |
| --- | --- | --- |
| `watchdog` | `true` | Start the RAM watchdog with each session (if it is not running yet). |
| `stop_jobs` | `true` | Let the watchdog stop AI-started jobs when memory is critical. Off: it only logs and warns. |

Change them in `/config`, or in `/plugin` > Installed > the plugin > Configure options. A watchdog that already
runs keeps its setting: `ram.sh watch --stop`, and the next session starts it again with the new one.

### Updates and uninstall

```bash
claude plugin update perfect-vibecoding-ram-management@perfect-vibecoding-ram-management
claude plugin uninstall perfect-vibecoding-ram-management@perfect-vibecoding-ram-management --scope user
claude plugin marketplace remove perfect-vibecoding-ram-management
```

A running session keeps the old version: start a new session, or run `/reload-plugins`. A running watchdog keeps
the old code too: `ram.sh watch --stop`, and the next session starts the new one. The login service runs its own
copy: run `ram.sh install-service` again after an update. Before you uninstall, stop the watchdog
(`ram.sh watch --stop`) and, if you installed it, the login service (`ram.sh uninstall-service`).

## Commands

| Command | What it does |
| --- | --- |
| `ram.sh status` | Free memory, memory stalls, memory per group, the biggest processes, the watchdog, the queue |
| `ram.sh run [options] -- CMD` | Runs CMD in the queue under a memory cap; prints its exit code, time and peak |
| `ram.sh jobs` | The queued jobs that run now |
| `ram.sh free [--dry-run] [--all]` | Stops idle Gradle and Kotlin daemons and orphaned test runners |
| `ram.sh watch --start`, `--stop`, `--status` | Starts, stops or shows the watchdog |
| `ram.sh last` | What used the memory just before the last reboot or freeze |
| `ram.sh doctor [DIR] [--fix]` | Settings of the machine and of a project that waste memory |
| `ram.sh check heavy`, `agent`, `level` | For the hooks |
| `ram.sh install-service`, `uninstall-service` | Starts the watchdog at every login, as a systemd user service (Linux, no sudo) |

`run` options: `--need MB`, `--max MB`, `--alone`, `--name LABEL`, `--timeout S`, `--wait S`, `--no-cap`. It exits
with the job's code, 75 when it gave up waiting for memory, and 137 or 143 when its cap or the watchdog stopped it.

## Settings

Environment variables, or your file `~/.config/perfect-vibecoding-ram/ram.env` (shell syntax, for example
`RAM_SLOTS=1`). The environment wins over the file. The defaults scale with the RAM: the hooks refuse new heavy work
below 15% free, the watchdog stops jobs below 7%, and the queue runs 1 to 4 jobs at once. The skill's `SKILL.md`
lists the main settings; the top of `ram.sh` lists them all. `RAM_PROTECT` (an extended regex) keeps matching
command lines, such as your dev server, from ever being stopped.

## What it never touches

- The watchdog never stops the editor, the desktop, an AI session, an MCP server, a process you started yourself
  outside the queue (Gradle and Kotlin daemons aside: they are caches that the next build starts again), or a
  command line that matches `RAM_PROTECT`. `ram.sh free` stops only build daemons and orphaned test runners (their
  parent is gone).
- It never kills by name, never runs as root, and never uses the network.
- It never changes sysctl, systemd-oomd, swap or your projects on its own. `doctor --fix` and `install-service`
  run only when you run them, and `doctor --fix` keeps a backup.

## Privacy

The logs in `~/.local/state/perfect-vibecoding-ram/` (`events.log`, `snapshots.log`) hold process names and command
lines, and a command line can hold paths, project names or a token passed as an argument. They never leave your
machine, they rotate (at most 2,000 and 4,000 lines), and you can delete the folder at any time. The hook keeps one
tiny file per session in the temp folder: the time of the last stop it told Claude about.

## Where it runs

| Part | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Queue, watchdog, doctor, hooks (bash, Node 18 or newer) | yes | yes | inside WSL only |
| Memory caps per job | yes, with a systemd user session | no: jobs run without a cap | inside WSL with systemd |
| Memory stalls (PSI) in the levels | yes | no | inside WSL |

- The queue's slots and per-folder lock need `flock`. Linux has it. On macOS, install it; without it the queue
  still waits for free memory.
- On native Windows the hooks do nothing.

## Tests

```bash
bash tests/run.sh
```

Every case runs in throwaway folders, with settings that make it impossible to stop a real process. It needs bash
and Node 18; the cap cases need Linux with a systemd user session and skip elsewhere.

## License

MIT. See [LICENSE](LICENSE).
