# Handoff: cross-platform verification still owed

Written 2026-09-10, at the v0.3.4 release. Unlike the rest of `docs/`, this
one tracks work that is NOT done: it is the list of what still needs running
on macOS, on Windows and under WSL, and it goes stale the moment those tests
happen. Delete or rewrite it once they do.

## What shipped in 0.3.4

Three things, all on `main`:

1. **`flock` and `timeout` are no longer dependencies.** `nutshell-lib.sh`
   carries `nut_lock_acquire` / `nut_lock_wait` / `nut_lock_release` and
   `nut_timeout`. Four call sites use them: `hooks/sync.sh`,
   `auth_cache_refresh.sh` (lock plus the 15s probe limit),
   `cost_cache_refresh.sh` (`take_lock`), and `statusline-toggle.sh`'s
   90s reset cap.
2. **Dependency tiers changed.** `nutshell-doctor.sh` now reports four
   dependencies and all four are `required`: `jq`, `bash`, `ccusage`,
   `claude`. `flock` and `timeout` are not reported at all.
3. **A one-line layout, `/nutshell:nutshell-mode`.** `config.json` key
   `"mode"`, values `simple` and `detail`. A first install starts on
   `simple` with the cost part hidden; an install that predates 0.3.4 keeps
   `detail` and keeps whatever cost setting it had.

## What was verified, and where

98 assertions across six suites, all green, **on Linux only** (Zorin 18,
bash 5.2.21, jq 1.7):

| Suite | Cases | What it covers |
|---|---|---|
| Shim units | 18 x2 | lock acquire/refuse/release, stale break, noclobber restore, EXIT trap, 20-way concurrency, blocking wait and its cap, timeout output capture, kill path, exit-status passthrough, `set -e` safety, non-coreutils `timeout` impostor |
| Integration | 13 x2 | 10 concurrent cost refreshes producing one scan, 10 concurrent auth probes, sync under contention, reset waiting for a live holder, render, `uninstall --purge` |
| Upgrade | 3 | pre-0.3.4 `flock` fd-target files do not read as a held lock |
| Kill paths | 6 x2 | a killed reset reports failure rather than `done`, hung probe cut short through the real `nut_spawn` shape |
| Mode | 33 | both layouts, every part toggle, first-install versus upgrade defaults, config repair, the toggle verb, the status row |

The `x2` suites ran twice: once with real `flock` and `timeout` present, and
once against a `PATH` mirror that omits exactly those two binaries, which is
the same code path macOS and Git Bash take.

Fork counts, measured with `strace -e trace=execve`: 12 either way on
bash 5.x; on the emulated bash 3.2 path, 13 for simple against 22 for
detail.

## What is NOT verified

### macOS

Nothing here has run on real macOS hardware. The bash 3.2 path was
simulated by forcing both fast-path gates false on bash 5.3. The
`docs/windows-render-timeout-fix.md` note records a real macOS 26.5.2 arm64
check of the render, but that predates every change in 0.3.4.

The suites that need running live in
[`docs/test-harness/`](test-harness/README.md); `run-all.sh` drives all of
them and needs nothing installed.

Run on a Mac (bash 3.2.57, arm64), in this order:

```bash
bash --version                      # expect 3.2.57
bash -n ~/.claude/nutshell/bin/*.sh # every script must parse on 3.2
bash ~/.claude/nutshell/bin/statusline-toggle.sh status
bash ~/.claude/nutshell/bin/nutshell-doctor.sh
bash docs/test-harness/run-all.sh   # about four minutes
```

Then the things bash 3.2 could break that 5.x cannot:

- `nut_lock_acquire`: `case "$-" in *C*)` and the `trap ... EXIT` forms.
  Confirm two concurrent refreshers produce one `ccusage` scan, and that
  `~/.claude/nutshell/locks/cost_cache.lock.held` is gone afterwards.
- `nut_timeout` without GNU `timeout` (the stock Mac case): confirm a fast
  command returns immediately rather than at the limit, which is the bug
  the watcher's `>/dev/null` redirection exists to prevent.
- `set -m` process-group signalling: `claude auth status` forks children,
  and a surviving grandchild holds a `$(...)` capture pipe open.
- Simple-mode render, including `fmt_countdown` and `simple_location`.

### Windows, Git for Windows bash

Never run. Three specific risks, each with a reason to doubt it:

- **`timeout.exe`**: `C:\Windows\System32\timeout.exe` is on the Git Bash
  `PATH` and is cmd's "wait N seconds", not coreutils. `nut_have_gnu_timeout`
  gates on `timeout --version | grep -i coreutils`, verified against a stub
  impostor on Linux but never against the real `.exe`.
- **SIGTERM to a native `.exe`**: Cygwin maps it to `TerminateProcess`, so
  grandchildren of `claude.exe` may survive. GNU `timeout` has the same
  limit there, so this is a wash rather than a regression, but it is
  unmeasured.
- **CRLF on `cfg_mode`**: it is the last field of the jq array and is
  compared against an exact string. A stray `\r` would silently force the
  detail layout. Both it and `rate_changed` are stripped, but the whole
  class of bug was found on Windows and never re-tested there.

Also worth timing on Windows: simple mode forks 9 fewer processes per render
than detail on the bash 3.2 path, and a fork costs 150 to 210ms under
Cygwin. Simple should therefore be visibly faster to complete a render.

### WSL

The README already calls WSL "still under development". Nothing in 0.3.4
changed that, and no WSL run has happened.

## Smaller things left open

- `nutshell-doctor.sh` reports `claude` as `required` with a remedy of
  "check your PATH" and no install command, because the binary is Claude
  Code itself. A PATH search across the known install locations would be a
  better answer than a prose remedy.
- The doctor's `--probe` still only checks the `ccusage` schema. Nothing
  probes whether `claude auth status` actually answers.
