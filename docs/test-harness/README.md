# Test harness

Plain bash, no framework, no dependencies beyond what the plugin already
needs. Every suite builds its own fake `HOME` and stubs `claude` (and,
in `t_deps.sh`, every package manager) on `PATH`, so nothing here reads or writes the real
`~/.claude`, and nothing has to be installed first.

Written for the 0.3.4 release and extended for the unreleased 0.3.5 work,
whose cross-platform verification is still owed. See
[handoff.md](../handoff.md) for what has been run and where.

## Running everything

```bash
bash docs/test-harness/run-all.sh
```

It finds the checkout from its own location, so it works from any directory.
Pass a path to test a different checkout:

```bash
bash docs/test-harness/run-all.sh /path/to/statusline-in-nutshell
```

Expect `every suite passed` on the last line, and an exit status of 0.
Allow about three minutes: the kill and integration suites wait out the
15 second cap on a hung auth probe, once per PATH each. 249 assertions as of
2026-09-24: the ccusage cost cases moved to `archived/fragments/` on 2026-09-23,
and four upgrade cases for the renamed caches were added the next day.

Each suite also runs on its own, taking the checkout and a scratch `HOME`:

```bash
bash docs/test-harness/t_modeassert.sh "$PWD" /tmp/somewhere-empty
```

`t_shim.sh` is the exception. It takes the library path rather than the
checkout, since it sources it directly:

```bash
bash docs/test-harness/t_shim.sh "$PWD/skills/nutshell-setup/scripts/nutshell-lib.sh" /tmp/somewhere-else
```

## What each suite covers

| Suite | Cases | Covers |
|---|---|---|
| `t_shim.sh` | 24 | `nut_lock_acquire` and friends: refusing a held lock, breaking a stale one, refusing to steal a fresh one, restoring `noclobber`, releasing through the EXIT trap, 20 concurrent starters where exactly one may enter, the blocking wait and its cap. Then `nut_timeout`: output captured through `$(...)`, a fast command returning immediately rather than at the limit, a slow one killed, the child's own exit status preserved, a caller under `set -e` surviving, and a non-coreutils `timeout` on `PATH` being bypassed |
| `t_integ.sh` | 14 | The real scripts under a fake `HOME`: 10 concurrent auth probes producing one, a hung probe cut short, the sync hook registering correctly under contention, the statusline rendering, stale write temporaries swept by a refresher while a live one is left alone, and `uninstall --purge` leaving no `locks/` behind |
| `t_upgrade.sh` | 9 | An install that predates 0.3.4, whose empty `sync.lock`, `cost_cache.lock` and `auth_cache.lock` were flock's fd targets, must not read as permanently locked. The sync deletes the retired `bin/cost_cache_refresh.sh` and swaps `bin/usage_cache_refresh.sh` for `account_usage_cache_refresh.sh`. It renames `state/rate_cache.json` to `shared_rate_limit_cache.json` and `state/usage_cache.json` to `account_usage_cache.json`, keeping the content, and when both names of the usage cache exist, keeps the new one. A purge sweeps the retired cost files, the ledgers and the 0.3.6 cache and lock names. Uninstall removes both the old and the new lock names |
| `t_kill.sh` | 2 | A hung auth probe run through the real `nut_spawn` shape (nohup, disown, no tty) is cut off at its limit and releases its lock |
| `t_modeassert.sh` | 75 | Both layouts byte for byte, the advisor name resolved from the model catalog (newest family version, exact ids past date and `[1m]` suffixes, the newest of several catalog files, `off`, no catalog, a broken one), the session cost at the end of the detail session row and after the rate windows in simple (alone when the session part is hidden, absent when the payload has none), every part toggle in simple, first-install versus upgrade defaults for `mode` and `cost`, a bad or missing key repaired, the `mode` verb including its toggle and its refusal while inactive, the `status` row order, the per-model weekly window (live, expired, absent, and hidden with the session part), and the accent color including the max effort that stays orange under it |
| `t_rate.sh` | 17 | Which of the three readings of the two account rate windows wins: this session's own payload, the shared rate cache, and the usage endpoint cache. Covers the stale-cache correction with no message sent, `windows_at` versus `updated_at` so a failed probe cannot outrank a live publish, an expired or absent endpoint window, a pre-0.3.6 usage cache, a metered session reading neither shared source, the session part hiding both, and the cache settling to no write after one correction |
| `t_deps.sh` | 34 | `nutshell-doctor.sh` per OS, with `uname` stubbed so the macOS and Git Bash arms run on Linux, the `optional` tier for `curl`, and `nutshell-install-deps.sh`: plan versus apply, channel and version resolution, both sudo arms, CRLF from a native package manager, a dry run that touches nothing, a failing install, and the usage errors. Nothing here installs anything or reaches the network: every package manager is a stub that records its argv |
| `t_mode.sh` | n/a | Not assertions. Dumps the simple row in fourteen states with its width in terminal cells, for eyeballing a layout change |

## The two passes

Suites marked `x2` in the handoff run twice. The second pass uses a `PATH`
mirror built by `run-all.sh`: symlinks to every executable on the real
`PATH` except `flock` and `timeout`. That is the same code path stock macOS
and the bash Git for Windows ships take, so the fallback lock and the
watcher-based timeout get exercised on a machine that has the real tools.

The mirror is symlinks rather than shell functions on purpose. `command -v`
finds a function, so defining one named `flock` would hide the very thing
the pass exists to remove.

## Emulating bash 3.2

macOS ships bash 3.2, where the plugin's `printf '%(fmt)T'` and `${var,,}`
fast paths are switched off. To exercise those fallbacks on a modern bash,
force both gates false:

```bash
sed 's/if \[ "${BASH_VERSINFO\[0\]:-0}" -ge 5 \]/if false \&\& [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]/; s/elif \[ "${BASH_VERSINFO\[0\]:-0}" -eq 4 \]/elif false \&\& [ "${BASH_VERSINFO[0]:-0}" -eq 4 ]/' \
  skills/nutshell-setup/scripts/statusline.sh > /tmp/sl32.sh
```

Copy the result into a fake `~/.claude/nutshell/bin/` before running it: the
script sources `nutshell-lib.sh` from its own directory and exits 0 in
silence when it cannot find it.

This is a simulation, not a substitute. Nothing here has run on real bash
3.2, and the handoff says so.

## Counting forks

The repo treats fork count as a correctness property, not a nicety: under
Cygwin a fork costs 150 to 210ms, which is what made renders miss their
cancellation window before 0.3.4.

```bash
strace -f -e trace=execve -o /tmp/forks.txt \
  bash ~/.claude/nutshell/bin/statusline.sh < payload.json >/dev/null
grep -c 'execve(' /tmp/forks.txt
```

Recorded on Linux at 0.3.4: 12 in either layout on bash 5.x, and on the
emulated 3.2 path 13 for simple against 22 for detail.
