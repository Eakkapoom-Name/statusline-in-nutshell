# Handoff: cross-platform verification still owed

Written 2026-09-10 at the v0.3.4 release, extended the same day for the
0.3.5 work that is on `main` and not yet tagged. Unlike the rest of `docs/`,
this one tracks work that is NOT done: it is the list of what still needs
running on macOS, on Windows and under WSL, and it goes stale the moment
those tests happen. Delete or rewrite it once they do.

## What shipped in 0.3.4

Three things, all on `main`:

1. **`flock` and `timeout` are no longer dependencies.** `nutshell-lib.sh`
   carries `nut_lock_acquire` / `nut_lock_wait` / `nut_lock_release` and
   `nut_timeout`. Four call sites use them: `hooks/sync.sh`,
   `auth_cache_refresh.sh` (lock plus the 15s probe limit),
   `cost_cache_refresh.sh` (`take_lock`), and `statusline-toggle.sh`'s
   90s reset cap.
2. **Dependency tiers changed.** `nutshell-doctor.sh` reported four
   dependencies, all four `required`: `jq`, `bash`, `ccusage`, `claude`.
   `flock` and `timeout` are not reported at all. (0.3.5 adds a fifth,
   `curl`, at the `optional` tier.)
3. **A one-line layout, `/nutshell:nutshell-mode`.** `config.json` key
   `"mode"`, values `simple` and `detail`. A first install starts on
   `simple` with the cost part hidden; an install that predates 0.3.4 keeps
   `detail` and keeps whatever cost setting it had.

## What is new since 0.3.4, unreleased

All on `main`, none of it tagged, and every item below is Linux-only so far:

1. **The simple row changed shape.** Short labels with colons in words mode
   (`adv:`, `ctx:`, `5h:`, `7d:`, `fable:`), no context bar, no cost segment
   at all, and one location segment in the same `<path>@<branch>` shape in
   both label modes (emoji mode prefixes the repo globe rather than spending
   a second icon on the branch).
2. **The rate row and the cost row swapped places** in detail, so rate is
   line 2 and cost is line 3. `show`, `hide` and `status` follow that order,
   and the cost labels are `weekly:` and `monthly:`.
3. **A per-model weekly window** (the `fable` segment), experimental. A
   sixth installed script, `usage_cache_refresh.sh`, probes
   `https://api.anthropic.com/api/oauth/usage` with the token from
   `~/.claude/.credentials.json`, passed to curl through a 0600 `-K` config
   file rather than argv. Omitted entirely when there is no such window.
4. **An accent color**, experimental: `config.json` key `"color"`,
   `orange` (default) or `blue`, command `/nutshell:nutshell-color`.
5. **The setup skill installs dependencies** instead of only reporting them.
   `nutshell-install-deps.sh` plans a channel and a version per gap, the
   skill asks once, then `--apply` runs the names the user agreed to.
6. **The doctor learned Windows and curl.** `MINGW*`, `MSYS*` and `CYGWIN*`
   now report `os_kind=windows` with scoop, winget and choco remedies (they
   read as `unknown` before, so every remedy was useless prose there), and
   `curl` is reported as the one `optional` dependency.

## What was verified, and where

196 assertions across seven suites, all green, **on Linux only** (Zorin 18,
bash 5.2.21, jq 1.7), last run 2026-09-10 with the 0.3.5 work in place:

| Suite | Cases | What it covers |
|---|---|---|
| Shim units | 18 x2 | lock acquire/refuse/release, stale break, noclobber restore, EXIT trap, 20-way concurrency, blocking wait and its cap, timeout output capture, kill path, exit-status passthrough, `set -e` safety, non-coreutils `timeout` impostor |
| Integration | 13 x2 | 10 concurrent cost refreshes producing one scan, 10 concurrent auth probes, sync under contention, reset waiting for a live holder, render, `uninstall --purge` |
| Upgrade | 3 | pre-0.3.4 `flock` fd-target files do not read as a held lock |
| Kill paths | 6 x2 | a killed reset reports failure rather than `done`, hung probe cut short through the real `nut_spawn` shape |
| Mode | 51 | both layouts, every part toggle, first-install versus upgrade defaults, config repair, the toggle verb, the status row, the per-model weekly window (live, expired, absent, session part off), the accent color and its pinned max effort |
| Deps | 34 x2 | the doctor per OS (Linux, macOS, Git Bash) against stub `uname`, the optional `curl` tier, and the installer: plan versus apply, channel and version resolution, the sudo arms, CRLF from a native package manager, dry run, a failing install, usage errors |

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

Then the 0.3.5 surfaces, none of which has ever run on a Mac:

- **The per-model weekly window will be absent, and that is correct.** macOS
  keeps its OAuth credentials in the Keychain, so `~/.claude/.credentials.json`
  usually does not exist and `usage_cache_refresh.sh` exits before it probes.
  Confirm the row is simply missing and that no `state/usage_cache.json` is
  written, rather than a 0% segment or an error. If the file DOES exist on a
  given Mac, confirm the probe works and the segment appears.
- **`curl` is reported ok.** It ships with macOS, so the doctor's `curl` row
  should read `ok` with a version, and `remedy_curl` should never be reached.
- **Homebrew is never installed for the user.** With no `brew` on PATH, the
  jq remedy is prose ("install Homebrew ... then: brew install jq"), and
  `nutshell-install-deps.sh --plan` must classify it `skip`, never `run`.
  Covered by a stub on Linux; a real Mac is the honest test.
- **`brew info --quiet jq`** is what fills the version in the plan. Confirm
  it answers within the 25s probe limit on a cold Homebrew (it fetches
  metadata) and that a version, not `?`, reaches the plan.
- **`sudo -n true`** on a Mac with an admin account and no cached
  credential: the plan must say `skip` and hand back the command, never
  hang. Nothing on macOS should ever need sudo here, since brew does not.
- **The accent color** under Terminal.app and iTerm2: both truecolor
  escapes (`38;2;...`) must render, and max effort must stay orange while
  everything else turns blue.

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

The 0.3.5 work adds five more, all of them Windows-specific by nature:

- **The doctor's OS arm.** `uname -s` under Git Bash gives
  `MINGW64_NT-10.0-<build>`, under MSYS2 `MSYS_NT-10.0-<build>`, under
  Cygwin `CYGWIN_NT-10.0-<build>`. All three must report `os_kind=windows`
  and name a real remedy. Tested against stub `uname` output on Linux only.
- **The package-manager remedies, run for real.** In preference order:
  `scoop install jq`, then
  `winget install --id jqlang.jq -e --silent --accept-package-agreements --accept-source-agreements`,
  then `choco install jq -y`. Two things to watch: winget can raise a UAC
  prompt for a machine-wide install, which would hang a tool call the same
  way a sudo password would, and choco needs an elevated shell outright.
  If winget does prompt, the installer needs the same treatment sudo got.
- **CRLF from those three.** They are native Windows executables and answer
  `\r\n`. `probe_cmd` pipes every version probe through `tr -d '\r'`;
  confirm no carriage return reaches a `plan` record, since the records are
  tab-separated and parsed by the skill.
- **PATH after an install.** winget and scoop write the new PATH where only
  a new terminal reads it, so `--apply` will report `installed` while the
  doctor still says `missing`. That is the expected outcome and the setup
  skill has a template for it; confirm the message a user actually sees.
- **`curl -K <path>` and MSYS path rewriting.** The usage probe writes the
  Authorization header to `~/.claude/nutshell/state/usage_hdr.XXXXXX` and
  passes that POSIX path to curl. Git Bash rewrites path-looking arguments
  when the callee is a native `.exe`, and Windows 10 and later ship their
  own `curl.exe`. Confirm the probe still authenticates, and confirm the
  temp file is deleted afterwards whichever curl runs.
- **`fromdateiso8601` in a native jq.** `usage_cache_refresh.sh` converts
  the endpoint's ISO stamp with it. jq's date builtins lean on the C
  library and are the part of jq most likely to differ on a Windows build.
  A stamp that fails to convert makes the entry drop out silently, which
  looks exactly like an account with no per-model window.

Also worth timing on Windows: simple mode forks 9 fewer processes per render
than detail on the bash 3.2 path, and a fork costs 150 to 210ms under
Cygwin. Simple should therefore be visibly faster to complete a render.

### WSL

The README already calls WSL "still under development". Nothing in 0.3.4 or
0.3.5 changed that, and no WSL run has happened. Two things to check first
when one does:

- The doctor already appends `(WSL)` to the OS name from `uname -r`, and
  picks apt from `/etc/os-release`, so the remedies should be the Ubuntu
  ones. Confirm that, rather than assuming it.
- A minimal WSL image often ships no `curl`, which is the one platform where
  the new `optional` tier actually fires: the doctor must report it missing,
  exit 0 anyway, and the installer must plan
  `sudo apt-get install -y curl`. On a default WSL install sudo needs no
  password, so this is also the easiest place to exercise the `run` arm of
  a sudo fix end to end.

## Smaller things left open

- `nutshell-doctor.sh` reports `claude` as `required` with a remedy of
  "check your PATH" and no install command, because the binary is Claude
  Code itself. A PATH search across the known install locations would be a
  better answer than a prose remedy.
- The doctor's `--probe` still only checks the `ccusage` schema. Nothing
  probes whether `claude auth status` actually answers, and nothing probes
  the usage endpoint either.
- `nutshell-install-deps.sh` will not install a Node runtime on Windows, so
  a Windows machine without Node gets `ccusage` reported rather than
  installed. Same reasoning as Homebrew: a language runtime is a bigger
  change than a package. Revisit if it turns out to be the common case.
- The accent color is two hard-coded truecolor escapes. A terminal without
  truecolor gets whatever it approximates, and nothing detects that.
- `plugin.json` is still `0.3.4`. Everything in the 0.3.5 list above needs a
  version bump, a `vX.Y.Z` tag and a `gh release create` before plugin-path
  users see any of it.
