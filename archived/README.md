# archived

Code the plugin no longer ships, kept so it can be read or brought back.
Nothing in this directory is installed, sourced, run or tested: the sync
hook copies only `skills/nutshell-setup/scripts/`, the plugin loads skills
only from `skills/` and hooks only from `hooks/hooks.json`, and
`docs/test-harness/run-all.sh` checks only `hooks/` and the scripts
directory.

## The ccusage cost windows (retired 2026-09-23)

The statusline used to show five spend figures on a row of their own:
the current session, today, this week, this month and all time. Every one
but the first came from `ccusage daily --json`, scanned in the background,
plus any extra per-source ledger another tool wrote into
`state/ledger_<source>.json`. The row now shows only the current session's
cost, read straight from the statusLine payload's `cost.total_cost_usd`, at
the end of the session row. Nothing is scanned, spawned or cached for it.

Whole files, moved here with `git mv` so `git log --follow` still finds
their history:

| Here | Was |
|---|---|
| `scripts/cost_cache_refresh.sh` | `skills/nutshell-setup/scripts/cost_cache_refresh.sh` |
| `hooks/cost-refresh.sh` | `hooks/cost-refresh.sh` (the `Stop` hook, removed from `hooks/hooks.json`) |
| `skills/nutshell-reset-all-time-cost/SKILL.md` | `skills/nutshell-reset-all-time-cost/SKILL.md` |

Code cut out of files that stayed. These are excerpts with their original
line numbers noted inside, not runnable scripts, hence `.txt`:

| Fragment | Cut from |
|---|---|
| `fragments/statusline-cost.txt` | `statusline.sh`, partial: the cost cache gate, the four window labels, the cost cache inputs in the jq program, the spawn of the refresher, and the old cost row. The rest is in `git show c01a8ad:skills/nutshell-setup/scripts/statusline.sh` |
| `fragments/statusline-toggle-reset-all-time.txt` | `statusline-toggle.sh`: the `reset-all-time` verb and its dispatch |
| `fragments/nutshell-doctor-ccusage.txt` | `nutshell-doctor.sh`: the ccusage remedies, the `--probe` schema check and the ccusage dependency record |
| `fragments/t_deps-ccusage-apply.txt` | `t_deps.sh`: the apply cases, which used ccusage through npm (now jq through apt-get) |
| `fragments/t_kill-reset-all-time.txt` | `t_kill.sh`: a killed `reset-all-time` must fail and release its lock |
| `fragments/t_upgrade-cost-refresh.txt` | `t_upgrade.sh`: an old flock lock must not block the cost refresher |
| `fragments/t_integ-cost-and-reset.txt` | `t_integ.sh`: the cost lock under contention and both `reset-all-time` cases |

## The hardcoded advisor name map (retired 2026-09-23)

`fragments/statusline-advisor-map.txt` is the `advisor_display_name` case
statement that turned `fable`, `opus`, `sonnet` and `haiku` into display
names, and had to be patched at every model release. The name now comes from
Claude Code's own model catalog cache (`~/.claude/cache/model-catalog/`),
with the capitalised alias as the fallback, inside the jq program in
`statusline.sh`.

## Kept on purpose

What was kept on purpose, in the live code, from the cost retirement: the `NUT_COST_*` and
`NUT_EXTRA_LEDGER_PREFIX` paths in `nutshell-lib.sh`, so `uninstall --purge`
still removes what an older install wrote, and `NUT_RETIRED_BIN_FILES`,
which makes the sync delete `bin/cost_cache_refresh.sh` from an upgraded
install. `nut_lock_wait` stays in the library too; `reset-all-time` was its
only caller.

To bring the windows back, the fragments show where each piece plugged in.
The jq program's field order is the part to be careful with: `cfg_mode` has
to stay the last field, see the comment on it in `statusline.sh`.
