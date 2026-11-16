# What jobs cost in memory, and what cuts it

Rough numbers for a mid-size app on Linux. Yours differ: measure it. `ram.sh run` prints the peak of each job when
it ends, and `ram.sh status` shows the memory per group. Size the next run from the peak, not from this page.

## Build tools

- **Gradle daemon** (Android builds): it grows up to its heap (`-Xmx`) plus metaspace and native memory. Flutter's
  Android template asks `-Xmx8G -XX:MaxMetaspaceSize=4G`, far more than a debug build needs (2 to 4 GB in all), and
  an idle daemon then stays for 3 hours. Cut both in `android/gradle.properties`:
  `org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g` and `org.gradle.daemon.idletimeout=900000` (15 minutes).
  `ram.sh doctor --fix` writes them, with a backup. `ram.sh free` ends idle daemons now.
- **Kotlin compile daemon**: when `kotlin.daemon.jvmargs` is unset, it copies the Gradle heap, so an 8 GB Gradle
  heap means a second process that may grow to 8 GB. Set `kotlin.daemon.jvmargs=-Xmx1g` (`doctor --fix` adds it).
- **Xcode builds and `pod install`**: 2 to 6 GB for a build. One at a time. Close the simulator when nobody tests.
- **Docker or Podman builds**: what the build steps use, often 1 to 4 GB. Run them alone.

## Flutter and Dart

- **`flutter test`**: about one `flutter_tester` process per CPU core, 150 to 400 MB each, plus the compiler
  (0.5 to 1 GB). On 8 cores that is 2 to 4 GB. Pass `--concurrency=2` while agents work, and test only the files
  you changed.
- **`flutter analyze` and the Dart analysis server**: 0.5 to 2 GB per analyzed folder. The editor runs one per open
  folder, so each window and each worktree adds one. Exclude what is not source code (`freeze.md`, "Editor
  settings") and close the windows you do not use.
- **`flutter run` and hot reload**: the compiler takes 0.5 to 1.5 GB, plus the app and the device.
- **`build_runner`**: 0.5 to 2 GB. Prefer a one-off `build` to a long-lived `watch` while agents work.
- **Android emulator**: its `hw.ramSize` (often 2 to 4 GB) plus about 1 GB for the emulator itself. Set
  `hw.ramSize=2048` in the device's `config.ini`, run one emulator at most, and close it when nobody tests on it.

## Node and the web

- **`next build`**: 1 to 3 GB. **`next dev`**: 0.5 to 2 GB, and it grows with each page it compiles.
- **`tsc`**: 0.3 to 1.5 GB on a big project.
- **Node's heap limit**: `NODE_OPTIONS=--max-old-space-size=2048` caps the heap of one Node process near 2 GB.
  The trade-off: a job that needs more fails with an out-of-memory error instead of growing.
- **Vitest and Jest**: one worker per core, 100 to 500 MB each. Use `--maxWorkers=2`, or `--runInBand` for Jest.
- **Playwright**: each browser engine takes 200 to 500 MB per worker. Run one engine (`--project=chromium`) with
  `--workers=1` or 2 while agents work.

## What stays all day

- **Editor windows**: 1 to 3 GB each with their extensions and language servers. One editor with several projects
  open was measured at 5 to 8 GB. Close the windows you do not use, and exclude `build/`, `.dart_tool/`,
  `node_modules/` and worktrees from watching and indexing.
- **Long AI conversations**: a session's process grows with its conversation, from a few hundred MB to more than
  1 GB inside an editor. Start a new session at a clean point instead of keeping one endless session.
- **Each agent**: one more session plus the tests and builds it runs. Count 1 to 2 GB per working agent.
- **The browser**: 100 to 500 MB per busy tab. The owner closes what they do not use.

## A budget

Add it up before parallel work. On a 15 GB machine, the desktop, one editor, a browser and two AI sessions can
already hold 9 to 11 GB. That leaves room for one build or one test run, not three, and never an emulator beside a
build. When `ram.sh status` shows less than 20% free, let what runs finish before you start anything new.
