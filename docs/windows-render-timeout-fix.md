# Windows: statusline never rendered

## Problem

On Windows, the statusline never appeared. `~/.claude/settings.json` and
`~/.claude/nutshell/config.json` were both correct, and running
`statusline.sh` by hand produced correct output — so the script itself
looked fine in isolation.

The actual cause only showed up under real load. Claude Code cancels an
in-flight statusline render whenever a new update triggers (a new
assistant message, `/compact`, a permission-mode change, or the
`refreshInterval` timer), and triggers land every 2-3 seconds during active
use. `statusline.sh` took 4-7 seconds per render. Instrumenting the script
with start/finish timestamps and watching a real session confirmed it:
**100 renders started, 0 completed.** It was never once fast enough to
finish before the next trigger killed it.

The 4-7 seconds came from fork count: the script ran roughly 67 external
commands per render (six separate `jq` calls, ~40 `$(...)` command
substitutions, plus `sed`/`head`/`cut` piped together for the git-branch
lookup). Forking a process costs ~1ms on Linux/macOS but 150-210ms under
the Cygwin-based bash that Git for Windows ships — so a script that would
run in well under 100ms elsewhere took multiple seconds here.

A second, independent bug was found in the process: the `jq` binary
installed via WinGet is a native Windows executable, so its stdout goes
through CRLF translation. `jq -r` was emitting a trailing `\r\n`; bash's
`read` strips only the `\n`, leaving a stray `\r` glued to the *last*
field of every one of the script's `jq` reads. This silently broke real
behavior on Windows: a `disabled: true` config value read as `"true\r"`
and never matched, so `statusline-toggle.sh off` did not actually turn the
statusline off, and the cost/auth background refreshers spawned on every
render instead of only when their caches were stale.

## Fix

- Collapsed six `jq` calls (payload, config, settings, cost cache, auth
  cache, rate-window merge) into one call that reads stdin plus all five
  state files at once.
- Replaced every `$(...)` command substitution in the render path with
  `printf -v`, which writes into a variable without forking a subshell.
- `git_branch` now reads `.git/HEAD` via a plain `read < file` redirection
  instead of piping through `sed | head | cut`.
- Token-count formatting (e.g. `51800` → `"51.8k"`) moved into the same
  `jq` call using exact integer arithmetic. `awk` is kept only as a
  fallback for the rare decimal-tie case (about 1 value in 100) that
  integer rounding cannot resolve on its own — neither bash's own
  `printf`, nor jq's `round`, reproduce C `printf`'s rounding at an exact
  tie, so a real floating-point implementation still has to decide those.
- Added `-j` to every `jq` invocation in the script (suppresses jq's own
  trailing newline) to fix the CRLF-into-last-field bug, plus a defensive
  strip on the one field where it still mattered.
- Added a bash-version gate (`NUT_FAST_STRFTIME`, `NUT_FAST_CASE_MOD`) so
  bash 4.2+ uses `printf '%(fmt)T'` and `${var,,}` in place of forking
  `date`/`tr`, while bash 3.2 (stock macOS) keeps the original fork-based
  path unchanged. The `${var,,}` case-mod expansion is routed through
  `eval` rather than written literally, since bash parses an entire
  function body before running any of it — a 4.0+ operator sitting on a
  branch that never executes on bash 3.2 could still be a *parse* error on
  that shell.

Fork sites per render: 67 → 11. Steady-state render time: ~7.4s → ~0.72s.
Live completion rate, measured the same way as the original diagnosis:
0% → 96% (56/58 renders completed).

Verified with a differential test harness comparing old and new output
across ~47 payload/config combinations, run twice — once normally and once
with the bash 4.2+ fast paths force-disabled to simulate the bash 3.2
fallback code paths macOS uses — with all cases passing both times.

The bash 3.2 path was then confirmed on real hardware: macOS 26.5.2
arm64, stock bash 3.2.57, jq 1.8.2.

### Caveats

- Fork cost is inherently platform-dependent; the 67→11 reduction and the
  `-j` fix are correctness/performance improvements everywhere, but the
  original may never have been slow enough to hit the cancellation window
  on Linux or macOS in the first place. This fix was written and measured
  entirely on the Windows system below.

## System this was diagnosed and fixed on

| Component | Value |
|---|---|
| OS | Windows 11 Home Single Language, build 10.0.26200 |
| Shell (`bash --version`) | GNU bash 5.3.15(1)-release (x86_64-pc-cygwin) |
| Shell binary | `/usr/bin/bash` (Git for Windows' bundled bash) |
| `uname -a` | `MINGW64_NT-10.0-26200 ... 3.6.9-... Msys` |
| `jq` | jq-1.8.2, native Windows binary, installed via WinGet (`jqlang.jq`) |
| `jq` path | `AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe/jq` |
| Claude Code CLI | 2.1.266 |
| Antivirus | Windows Defender, real-time protection on |
