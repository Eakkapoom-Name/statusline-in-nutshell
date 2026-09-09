# Test harness

Plain bash, no framework, no dependencies beyond what the plugin already
needs. Every suite builds its own fake `HOME` and stubs `ccusage` and
`claude` on `PATH`, so nothing here reads or writes the real
`~/.claude`, and nothing has to be installed first.

Written for the 0.3.4 release, whose cross-platform verification is still
owed. See [handoff.md](../handoff.md) for what has been run and where.

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
Allow about four minutes: two of the suites deliberately wait out the 90
second cap on `reset-all-time`.

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
| `t_shim.sh` | 18 | `nut_lock_acquire` and friends: refusing a held lock, breaking a stale one, refusing to steal a fresh one, restoring `noclobber`, releasing through the EXIT trap, 20 concurrent starters where exactly one may enter, the blocking wait and its cap. Then `nut_timeout`: output captured through `$(...)`, a fast command returning immediately rather than at the limit, a slow one killed, the child's own exit status preserved, a caller under `set -e` surviving, and a non-coreutils `timeout` on `PATH` being bypassed |
| `t_integ.sh` | 13 | The real scripts under a fake `HOME`: 10 concurrent cost refreshes producing exactly one `ccusage` scan, 10 concurrent auth probes producing one, a hung probe cut short, the sync hook registering correctly under contention, `reset-all-time` waiting for a live lock holder, the statusline rendering, and `uninstall --purge` leaving no `locks/` behind |
| `t_upgrade.sh` | 3 | An install that predates 0.3.4, whose empty `sync.lock`, `cost_cache.lock` and `auth_cache.lock` were flock's fd targets, must not read as permanently locked. Uninstall removes both the old and the new names |
| `t_kill.sh` | 6 | A `reset-all-time` killed at its limit must report failure rather than `done`, and must release its lock. The hung auth probe runs through the real `nut_spawn` shape: nohup, disown, no tty |
| `t_modeassert.sh` | 33 | Both layouts byte for byte, every part toggle in simple, first-install versus upgrade defaults for `mode` and `cost`, a bad or missing key repaired, the `mode` verb including its toggle and its refusal while inactive, and the `status` row order |
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
