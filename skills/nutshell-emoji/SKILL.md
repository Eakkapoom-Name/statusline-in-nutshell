---
name: nutshell-emoji
description: Switch the nutshell statusline labels between text and emoji icons. No argument toggles the mode, or say on or off. Use when the user mentions emoji, icons or text labels on their statusline.
argument-hint: "[on|off]"
---

# Emoji labels

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Then run `bash ~/.claude/nutshell/bin/statusline-toggle.sh status` and read the
`statusline` row: if it reads `inactive`, the script refuses this command
anyway, so answer from the template below and stop.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

- No argument, or `toggle`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh emoji` (the script
  defaults to toggle)
- `on` or `off`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh emoji on|off`
- Anything else: do not run the script, and say nothing (see below).

Emoji mode is independent of which parts are shown, and it is off by
default. This skill is the only way to change it: the nutshell-show and
nutshell-hide skills do not accept `emoji`. Never hand-edit `config.json`;
the script is the only writer.

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
- Any argument other than `on`, `off` or `toggle`: say nothing at all. Do
  not run the script, do not name the argument.

After the script ran:

- Say nothing at all, whatever happened: a part that changed, a part that
  was already in that state, `all`, a non-zero exit, a config the script
  could not write, an argument the script rejected. No output, no code
  block, no confirmation, no error. The row itself is the only report.
  A write that failed leaves the labels unchanged, which is
  the same thing the user sees for a setting that was already there.
