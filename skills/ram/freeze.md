# When the PC froze

## What happened, and why

A full memory rarely crashes a Linux desktop: it freezes it. With zram swap (the default on Fedora and Ubuntu), the
kernel compresses memory into RAM instead of failing. Every program then waits on memory, the screen stops for
minutes, and nothing is killed yet. On one measured machine (15 GB of RAM, 8 GB of zram swap):

- systemd-oomd acted only at 80% memory pressure held for 20 seconds, and then it kills a whole app group: the
  editor with every AI session inside it;
- the logs showed freezes that ended with a power-off, and no out-of-memory kill at all;
- the editor held 5 to 8 GB, and Flutter's Android template gave Gradle an 8 GB heap, copied again by the Kotlin
  daemon.

The watchdog acts earlier and smaller: at the critical level it stops the newest AI-started job, not the editor.

## After the reboot

1. **See what used the memory**: `ram.sh last` prints the last snapshot before the boot (the biggest processes)
   and the watchdog's events of the hour before. No snapshot means the watchdog was not running.
2. **Check the AI sessions**: their transcripts survive. Resume the session that was working and read its last
   steps: a job that ran at the freeze did not finish, and its result is missing.
3. **Check the uncommitted tree**: `git status` and `git diff --stat` in each project. Look for half-written
   files (one that ends mid-line, an empty one). Rerun the tests of the changed files, through the queue.
4. **Fix the cause** that `ram.sh last` and `ram.sh doctor` show: a big Gradle heap, too many test workers, an
   emulator beside a build, too many agents, old worktrees.
5. **Start the watchdog** if it was not running: `ram.sh watch --start`.

## Editor settings

An editor watches and indexes every file in the folders it opens, and the Dart extension analyzes every package it
finds. Build output, packages and old worktrees cost memory and give nothing back. Add this to the project's
`.vscode/settings.json` (VS Code and its forks):

```json
{
  "files.watcherExclude": {
    "**/build/**": true,
    "**/.dart_tool/**": true,
    "**/node_modules/**": true,
    "**/.claude/worktrees/**": true,
    "**/runs/**": true
  },
  "search.exclude": {
    "**/build": true,
    "**/.dart_tool": true,
    "**/node_modules": true,
    "**/.claude/worktrees": true,
    "**/runs": true
  },
  "dart.analysisExcludedFolders": ["build", ".dart_tool", "node_modules", ".claude/worktrees", "runs"]
}
```

## Old worktrees

Each git worktree inside the project folder is a full copy that the editor may watch and analyze. One measured
project kept 109 old ones. List them and remove the ones nobody needs. The owner decides: a worktree can hold work
that is not merged yet.

```bash
git worktree list
git -C .claude/worktrees/<name> status --short   # uncommitted work?
git log --oneline main..<branch>                 # commits that are not on main?
git worktree remove .claude/worktrees/<name>     # refuses when the worktree has changes
git worktree prune                               # forgets worktrees whose folder is gone
```

## Optional hardening (the owner runs these)

Each one changes the machine. Explain the trade-off and let the owner choose.

- **A rescue key**: `sudo sysctl kernel.sysrq=64` (to keep it after a reboot: a file in `/etc/sysctl.d/` with
  `kernel.sysrq = 64`). Then Alt+SysRq+F asks the kernel to kill one process and ends a freeze in seconds.
  Trade-off: anyone at the keyboard can do it, and the kernel picks the victim: a queued job first (it has the
  highest OOM score), but without one it can be the editor. On many laptops SysRq needs the Fn key.
- **systemd-oomd limits**: a lower pressure limit and a shorter duration end a freeze sooner (`oomctl` shows the
  limits in force; `DefaultMemoryPressureLimit=` and `DefaultMemoryPressureDurationSec=` go in a file in
  `/etc/systemd/oomd.conf.d/`, and a slice may set its own `ManagedOOMMemoryPressureLimit=`). Trade-off: oomd still
  kills a whole app group, so the editor and every AI session in it go at once, and more often.
- **The watchdog at every login**: `ram.sh install-service` (no sudo) installs a systemd user service, so the
  watchdog runs before the first AI session too. Trade-off: one more small process all the time, and it runs a
  copy of the script: run `install-service` again after a plugin update. `ram.sh uninstall-service` removes it.
