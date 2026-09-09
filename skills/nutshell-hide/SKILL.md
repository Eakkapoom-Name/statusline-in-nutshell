---
name: nutshell-hide
description: Turn off one line of the nutshell statusline (cost, session or workspace) or all three, keeping the statusline itself registered. The model line cannot be hidden. Use when the user asks to hide or blank a statusline section. Not for handing the row back to Claude Code, which is the nutshell-inactive skill, and not for emoji labels, which is the nutshell-emoji skill.
argument-hint: "[all|cost|session|workspace]"
---

# Hide a statusline part

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Then run `bash ~/.claude/nutshell/bin/statusline-toggle.sh status`. If the `statusline`
row reads `inactive`, answer from the template below and stop. The script
refuses this command while inactive anyway; checking first avoids acting on
a request that cannot take effect.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

No confirmation is needed. The model line cannot be hidden, so no
combination of these commands can leave the statusline blank.

- No argument, or `all`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh all off`
  (hides cost, session and workspace; model stays on)
- `cost`, `session` or `workspace`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh <part> off`
- `model`, `emoji`, or anything else: do not run the script, and say
  nothing (see below).

Parts work the same in both layouts: in detail a hidden part drops its
line, in simple it drops its segment of the one row.

Hiding is not the same as inactive: hiding keeps the registration, so line 1
stays on screen and Claude Code's own footer stays suppressed, while the
nutshell-inactive skill removes the registration and brings that footer
back.

Never hand-edit `config.json` or `settings.json`; the script is the only
writer.

## How to answer

Short and plain. One template per situation. Quote script output in a code
block only where a template says so, and add nothing else.

When the scripts, `nutshell-lib.sh` or `jq` are missing, invoke the setup
skill yourself and retry once. Never tell the user to run setup.

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
- The `statusline` row reads `inactive`: "The statusline is inactive. Run
  `/nutshell:nutshell-active` to activate." Stop.
- Argument `model`, `emoji`, or anything else: say nothing at all. Do not
  run the script, do not name the argument, do not offer the skill that
  would have handled it.

After the script ran:

- Say nothing at all, whatever happened: a part that changed, a part that
  was already in that state, `all`, a non-zero exit, a config the script
  could not write, an argument the script rejected. No output, no code
  block, no confirmation, no error. The row itself is the only report.
  A write that failed leaves the row unchanged, which is the
  same thing the user sees for a part that was already hidden.
