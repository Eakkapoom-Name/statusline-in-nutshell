---
name: nutshell-reset-all-time-cost
description: Reset the nutshell statusline's all-time cost counter to zero, leaving today, weekly and monthly untouched. Irreversible, needs ccusage, and asks for confirmation first. Use when the user asks to reset, zero or clear their all-time or lifetime cost.
---

# Reset the all-time cost

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

This one runs whether the statusline is active or inactive: the all-time
total is cost history, not a rendered row. No `status` pre-check is needed.

1. If `command -v ccusage` fails, tell the user this feature is unavailable
   without `ccusage` and stop.
2. Ask: "This permanently resets your all-time cost. Today/week/month stay
   unaffected. Proceed?" and wait.
3. Only after yes, run:

```bash
bash ~/.claude/nutshell/bin/statusline-toggle.sh reset-all-time --yes
```

Without `--yes` the script only warns and does nothing. The reset recomputes
from `ccusage` and takes about ten seconds, so the script prints a progress
line before the result.

Never hand-edit `config.json` or anything under `state/`; the scripts are
the only writers.

## How to answer

Short and plain. One template per situation. Quote script output in a code
block only where a template says so, and add nothing else.

When the scripts, `nutshell-lib.sh` or `jq` are missing, invoke the setup
skill yourself and retry once. Never tell the user to run setup. `ccusage`
is the one exception, see its template below: installing a package needs
the user's yes, so that gap is reported rather than repaired.

Before the script runs:

- `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist: say "The
  script `~/.claude/nutshell/bin/statusline-toggle.sh` is missing, starting
  repair, please wait a moment." Then run setup and continue with the
  normal reply.
- stderr says `nutshell-lib.sh is missing`: say "The script
  `~/.claude/nutshell/bin/nutshell-lib.sh` is missing, starting repair,
  please wait a moment." Then run setup and retry once. If it fails again:
  "Setup could not restore `nutshell-lib.sh`. See its report above." Stop.
- stderr says `jq is required`: run setup, which reports the gap and offers
  the install command. Retry once if `jq` is now present. If not: "`jq` is
  still not installed, so the statusline cannot run. Install it with the
  command setup showed, then ask again." Stop.
- `command -v ccusage` fails: "`ccusage` is not installed, so there is no
  all-time total to reset. Run `/nutshell:nutshell-setup` to install it."
  Stop. This is the one gap setup cannot repair on your behalf, since
  installing a package needs the user's yes.
- The user answers no: "Abort." and nothing else. Do not run the script.

After the script ran, on a yes:

- stdout ends `done: all-time cost is now 0; today / weekly / monthly are unchanged.`:
  that line in a code block, then "Done." Leave out the
  `resetting all-time cost` progress line above it.
- stderr says `ccusage is required for this operation`: the stderr in a code
  block, then "Nothing was reset." This means `ccusage` is on your `PATH`
  but not on the script's.
- stderr says `refresher not found at`: the stderr in a code block, then
  "The install is incomplete. Run `/nutshell:nutshell-setup` to repair it,
  then try again." Invoke setup yourself and retry once first.
- stderr says `reset failed or timed out`: the stderr in a code block, then
  "Nothing was reset: the recompute did not finish. With `timeout`
  installed it is cut off at 90 seconds, which a very large transcript
  history can hit. Retry, and if it fails again the all-time total is
  unchanged."
- stderr says `'reset-all-time' resets your all-time cost`: "The confirmation
  flag was missing, so nothing was reset. This is a bug in the skill, not
  your input."
