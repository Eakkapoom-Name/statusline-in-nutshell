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
15 second cap on a hung auth probe, once per PATH each. 564 assertions as of
2026-11-24: the ccusage cost cases moved to `archived/fragments/` on 2026-09-23,
four upgrade cases for the renamed caches were added the next day, the 23
absent-window cases of 0.3.7 the day after, six weekly Fable reset cases
in the rate suite on 2026-11-23, the 32 auto-compact window cases on
2026-11-24, three more weekly Fable reset cases the same day, and seven
reset stamp conversion cases in the absent-window suite after them, then
the 42 uninstall and 18 reset cases, with the upgrade suite's case for the
pre-0.3.1 lock files in `~/.claude` dropped along with that cleanup, and
the 183 settings refusal cases after the settings repair was removed.

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
| `t_upgrade.sh` | 10 | An install that predates 0.3.4, whose empty `sync.lock`, `cost_cache.lock` and `auth_cache.lock` were flock's fd targets, must not read as permanently locked. The sync deletes the retired `bin/cost_cache_refresh.sh` and swaps `bin/usage_cache_refresh.sh` for `account_usage_cache_refresh.sh`. It renames `state/rate_cache.json` to `shared_rate_limit_cache.json` and `state/usage_cache.json` to `account_usage_cache.json`, keeping the content, and when both names of the usage cache exist, keeps the new one. A purge sweeps the retired cost files, the ledgers and the 0.3.6 cache and lock names. Uninstall removes both the old and the new lock names |
| `t_kill.sh` | 2 | A hung auth probe run through the real `nut_spawn` shape (nohup, disown, no tty) is cut off at its limit and releases its lock |
| `t_modeassert.sh` | 75 | Both layouts byte for byte, the advisor name resolved from the model catalog (newest family version, exact ids past date and `[1m]` suffixes, the newest of several catalog files, `off`, no catalog, a broken one), the session cost at the end of the detail session row and after the rate windows in simple (alone when the session part is hidden, absent when the payload has none), every part toggle in simple, first-install versus upgrade defaults for `mode` and `cost`, a bad or missing key repaired, the `mode` verb including its toggle and its refusal while inactive, the `status` row order, the per-model weekly window (live, expired, absent, and hidden with the session part), and the accent color including the max effort that stays orange under it |
| `t_rate.sh` | 26 | Which of the three readings of the two account rate windows wins: this session's own payload, the shared rate cache, and the usage endpoint cache. Covers the stale-cache correction with no message sent, `windows_at` versus `updated_at` so a failed probe cannot outrank a live publish, an expired or absent endpoint window, a pre-0.3.6 usage cache, a metered session reading neither shared source, the session part hiding both, the cache settling to no write after one correction, and the weekly Fable reset taken from the same reading the all-models weekly row picked, so both rows always show one reset: the payload reset in a fresh tab, the endpoint reset in an idle tab where the endpoint is newer, and the Fable entry's own stamp only when no live weekly reading exists, its percent staying the endpoint's |
| `t_absent.sh` | 30 | A window the account no longer has (issue #3). The probe, against a stubbed `curl`: `windows_absent` needs both a null top-level key and no `limits[]` entry of that kind, so an unparseable entry, a missing key or a missing `limits` array never marks one, and a failed call carries the verdict forward. The reset stamp conversion: a non-zero fractional second rounds up to the next whole second in either the `Z` or the `+00:00` form, for the account and the per-model windows alike, while a whole-second stamp or an all-zero fraction is unchanged and any other offset is dropped. The render: an absent window leaves the row, the shared cache and `seen.windows` in a fresh and an idle tab, a frozen payload cannot restore it, the cache settles, a pre-0.3.7 usage cache changes nothing, a reading measured after the probe outranks it, a fresh payload brings it back, and a metered session touches nothing |
| `t_compact.sh` | 32 | The auto-compact window on the context segment. With no explicit window (none set, `"auto"`, a settings value below 100000 per model or top-level, a `"600k"` string in settings, another model's entry, an env value under 1) the row is unchanged. An env value below 100000 is raised to 100000, as Claude Code raises it. With one, the total becomes the window capped at the model window and the percent and bar count against it, capped at 100%, in both layouts and on a fresh session. Also a payload with no model id, the dated and Bedrock model ids, the user, project and local scope fold including a top-level `autoCompactWindow`, the exact key winning inside one scope, and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` beating every scope in each form Claude Code parses, falling through when it does not parse |
| `t_uninstall.sh` | 42 | Nothing outside `~/.claude/nutshell/` is touched: a hand-written `~/.claude/statusline.sh` and its registration survive install, `off`, `reset` and uninstall, and files with the names a pre-0.3.1 install used are never migrated, claimed or deleted. Uninstall leaves a statusLine that is not nutshell's in place and says so, still removes its own, and keeps unrelated settings. An unparseable or unwritable `settings.json` stops the uninstall before any script goes, with a non-zero exit naming the file. A purge sweeps the write temps in `state/` and beside `config.json` so `nutshell/` goes, while a file nutshell never wrote survives. An unknown flag is refused |
| `t_settings.sh` | 183 | A `settings.json` that is not a plain JSON object is never rewritten: with `//` and `/* */` comments, a trailing comma, a UTF-8 BOM, `[1,2]`, `"x"`, `null`, or nutshell's own registration followed by a comment, the sync hook, `on`, `on --force`, `off`, `reset`, `uninstall --yes --purge` and a second sync each leave it byte for byte. The sync stays silent and exits 0 while still installing the scripts; every other command names the file and says it was left alone, `on` and `off` exit 1 without flipping `disabled`, `reset` still restores the look, and uninstall exits 1 deleting nothing. The library's register and unregister return 1 on a non-object, the repair functions are gone, and a missing `settings.json` is still created and registered |
| `t_reset.sh` | 18 | `reset` brings the parts, emoji, mode and color back to exactly what a fresh install's config holds, active or inactive, from a customized or an upgraded config. It keeps the active/inactive state, `settings.json`, the caches and the cost history byte for byte, keeps keys it does not own, is idempotent, and refuses an argument |
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
