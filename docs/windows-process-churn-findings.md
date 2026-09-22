# Windows: process churn, residual cost and leaked children

Status: **fixed 2026-09-21**, in the commit this file arrives with. The
investigation below is unchanged except where a claim did not survive
being tested; what shipped is listed under "What was done" at the end.
Measured 2026-09-18 on the maintainer's Windows 11 box (16 logical CPUs,
Git for Windows bash, WinGet-installed native `jq`, Claude Code 2.1.276,
nutshell 0.3.6).

This is the sequel to `windows-render-timeout-fix.md`. That fix took the
render from 4-7s / ~67 forks down to ~150ms / ~11 forks, which made renders
complete. What follows is what is left over at that speed, and why it is
still enough to be felt as a system-wide slowdown.

## Symptom reported

Windows feels slow while Claude Code is open, and the cursor in the prompt
text area flickers two or three times at once — worst while the model is
generating text or thinking.

## Finding 1: the cost line is not the cause

The maintainer's initial hypothesis was that the cost line was responsible.
It is not. Ten renders per variant, same payload, same machine:

| config                        | ms / render |
|-------------------------------|-------------|
| detail, all parts on          | 151         |
| detail, **cost off**          | 149         |
| simple, all parts on          | 148         |

Turning the cost line off saves ~2ms of 150. The cost windows are read from
`cost_cache.json`, which a background refresher owns on a 300s gate, so the
render path never computes them.

## Finding 2: essentially all of the 150ms is process creation

Baselines on the same box:

| operation                     | ms  |
|-------------------------------|-----|
| `bash -c 'exit 0'`            | 42  |
| `bash -n statusline.sh` (parse only) | 44 |
| source `nutshell-lib.sh`, do nothing | 42 |
| `jq -n 1`                     | 38  |
| `stat -c %Y <file>`           | 58  |
| `mktemp` + `mv` (one atomic write) | 86 |

A single process creation costs roughly 40ms here, against ~1ms on Linux
and macOS. The render is bash startup (~42) + the one big `jq` (~38) + the
`stat` on `.credentials.json` + whatever writes fire. There is no fat left
to trim inside the script; the floor is the number of processes, and the
script is already down to a handful.

## Finding 3: the multiplier is `refreshInterval` x concurrent sessions

`~/.claude/settings.json` on this box:

```json
"statusLine": { "type": "command", "command": "bash ~/.claude/nutshell/bin/statusline.sh", "refreshInterval": 1 }
```

`1` is the minimum Claude Code accepts. Its own settings schema (extracted
from the 2.1.276 binary) documents the field as:

> `refreshInterval: k().min(1).optional()` — "Re-run the status line command
> every N seconds **in addition to** event-driven updates"

So it is 1Hz on the timer *plus* a render per assistant message / thinking
delta. Six `claude` processes were running during the measurement.

Observed churn, sampled with `Get-CimInstance Win32_Process`:

- **69 distinct `bash`/`jq`/`conhost` PIDs in ~5 seconds** ≈ 14 process
  creations per second, sustained.
- Bursts to **14 concurrent `bash`** processes.
- 11-13 `conhost.exe` alive at any moment — Windows allocates a console
  host per console child spawned from a native parent.

14 creations/sec x ~40ms ≈ half a core spent on nothing but process setup,
and Defender real-time protection is enabled (`DisableRealtimeMonitoring:
False`, `DisableScriptScanning: False`) with no exclusions covering
`bash.exe`, `jq.exe` or `~/.claude/nutshell/`, so every image is scanned.

## Finding 4: killed renders leak children and temp files — this is a real bug

Claude Code still cancels an in-flight render when a new trigger lands, and
at ~150ms x 6 sessions that still happens. Two independent traces of it:

- **Orphaned `jq.exe` processes.** Five were alive with ages of 796-951
  seconds and `ParentProcessId` pointing at a dead PID. They come from the
  `read ... < <(jq "${NUT_JQ_ARGS[@]}" ...)` process substitution in
  `statusline.sh`: when bash is killed, `jq` is left holding a pipe with no
  reader and never exits. These accumulate for as long as the machine is up.
  *(That mechanism was proposed here without being tested, and it did not
  hold up — see Finding 7. The orphans were real; this explanation of them
  was not.)*
- **Leaked atomic-write temp files.** 38 `rate_cache.json.XXXXXX` /
  `cost_cache.json.XXXXXX` files in `~/.claude/nutshell/state/`, many
  zero-byte, dating back to Sep 8. `nut_write_atomic` does
  `mktemp` -> `printf` -> `mv`, with `rm -f` only on a *failed* write; a
  kill between `mktemp` and `mv` skips the cleanup entirely. The count went
  35 -> 38 during a single investigation session, so it is still growing.

Any fix here has to hold on Ubuntu and macOS too, and the plugin's floor is
stock bash 3.2.

## Finding 5: the cursor flicker

Every statusline update makes Claude Code repaint the bottom UI block. In
`detail` mode that is **4 lines** plus the input box; `simple` mode emits
**1 line** (verified by piping each through `wc -l`). Repainting the region
containing the cursor is what makes it jump, and the reported "2 or 3 at
once" matches the multi-line redraw.

Not solely nutshell's doing: Claude Code repaints during streaming with any
statusline, which is why the maintainer sees it while the model generates
and thinks. But the 4-line layout multiplies the repainted area, and
`refreshInterval: 1` adds a repaint every second even while idle.

## Finding 6: the workspace row broke across two lines

Reported separately, found to be the same platform difference and fixed in
the same commit. On Windows the payload's `workspace.current_dir` is a
native path, so its separator is a backslash, and `color_path` assembled
the finished row with `printf -v PATHOUT '%b'`. The argument to `%b` is the
caller's DATA as much as it is color, and `%b` expands backslash escapes
inside all of it: `C:\Users\name8\Documents` rendered as `C:\Users`, a
literal newline, then `ame8\Documents`, which is the reported "unexpected
newline". `\U` also made bash write `printf: missing unicode digit for \U`
to stderr on every render, discarded by Claude Code and therefore invisible.

Both layouts were affected, since `simple_location` colors its path through
the same helper. Nothing platform-specific was needed to fix it: the colors
are expanded on their own and the row is assembled by concatenation, which
is also one expansion fewer per path segment.

## Finding 7: the `jq` orphans do not come from the render

Finding 4 asserted that `read ... < <(jq …)` leaves `jq` holding a pipe
when the render is killed. Tested directly on 2026-09-21 and **it does
not**: eight renders killed with `SIGKILL` at 10-80ms, which straddles the
window in which `jq` is running, left zero `jq.exe` behind, and none were
alive on the box at the time either. The render path was therefore left
alone — it is the one place in the plugin where a fork is a correctness
constraint, and it should not be restructured on an untested theory. The
orphans seen on Sep 18 had ages of 796-951s, far longer than any render, so
the likelier source is a background refresher whose parent had already
exited by design (`nut_spawn` uses `nohup`); that is worth a look if they
reappear, with the ages and parent pids recorded at the time.

The temp-file half of Finding 4 was real, reproduced, and fixed.

## What was done

Plugin code, all of it cross-platform, none of it on the render path except
where it makes the render cheaper:

1. **`color_path` no longer runs data through `printf %b`** (Finding 6).
   Six assertions in `t_modeassert.sh` cover a backslash `current_dir` in
   both layouts: four lines stay four, one line stays one, the path renders
   whole, and stderr stays empty. They fail on the old code.
2. **`refreshInterval` is 5s on Windows, 1s elsewhere** (Finding 3), chosen
   from `$OSTYPE` in `nutshell-lib.sh` so no `uname` fork joins the render.
   This is the biggest single win on the box: it divides the idle churn,
   and the repaint behind Finding 5's flicker, by five. Nothing is lost —
   cost and the usage windows sit behind a 300s gate, and every payload
   field still repaints on the event rather than on the timer. Linux and
   macOS keep the 1s they have always had. Covered in `t_shim.sh`.
3. **Atomic writes no longer fork `mktemp`** (Finding 2). The temp name is
   `<target>.$$`, which has the property the mktemp draw was there for — no
   two live writers can share it — for none of the ~40-80ms a fork costs
   here. The one temp file that holds a secret, the usage probe's auth
   header, keeps its `mktemp`.
4. **`nut_sweep_write_temps` clears the debris** (Finding 4). A killed
   process runs no trap, so the leftovers are swept by the next background
   refresher instead: one `find -mmin +10 -delete` per refresh, off the
   render path, never by the render itself. Covered in `t_integ.sh`.

Measured again on 2026-09-21, after all four: 236ms per render over 20
renders, against 83ms for a bare `bash -c 'exit 0'` on the same box in the
same minute. The render is therefore still what it was in Finding 2 - a
handful of process creations and nothing else - and the box itself is now
about twice as slow at creating one as it was on Sep 18 (83ms against 42),
which makes the case for the interval stronger rather than weaker. What
changed is how often that 236ms is paid: at `refreshInterval: 1` an idle
session spends ~24% of a core on it, and at 5 it spends ~5%. Across the six
sessions that were open during the original measurement, that is the
difference between ~140% of a core and ~28%.

Machine configuration, still the user's to make:

5. Add Defender exclusions (needs admin) for
   `C:\Program Files\Git\usr\bin\bash.exe`, the WinGet `jq.exe`, and
   `~/.claude/nutshell/`. Every process creation above is scanned without
   them.
6. Switch `mode` to `simple` (`/nutshell:nutshell-mode simple`) if the
   flicker still bothers: 1 repainted line instead of 4.
7. Close unused sessions; every cost above scales linearly with them.

## Cleanup owed on this box

Done 2026-09-21: the 39 stale temp files in `~/.claude/nutshell/state/`
were deleted. No orphaned `jq.exe` processes were alive by then, so there
was nothing to kill.
