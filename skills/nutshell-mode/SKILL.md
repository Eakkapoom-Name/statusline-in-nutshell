---
name: nutshell-mode
description: Switch the nutshell statusline between the one-line simple layout and the four-line detail layout. No argument toggles the mode, or say simple or detail. Use when the user mentions one line, single line, compact, simple, detail, shorter or longer statusline.
argument-hint: "[simple|detail]"
---

# Simple or detail layout

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Then run `bash ~/.claude/nutshell/bin/statusline-toggle.sh status` and read the
`statusline` row: if it reads `inactive`, the script refuses this command
anyway, so answer from the template below and stop.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

- No argument, or `toggle`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh mode` (the script
  defaults to toggle)
- `simple` or `detail`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh mode simple|detail`
- Anything else: do not run the script, and say nothing (see below).

`simple` is what a new install starts on; an install that predates 0.3.4
keeps `detail` until its owner asks, so an upgrade never changes layout
under them. `detail` is the four-row layout: model, advisor and the
context bar, then the cost windows, then the rate windows, then the
workspace. `simple` is one row holding model and effort, the advisor when
there is one, the context counts, the current session's cost, both rate
windows with a countdown to their reset, and the repo with its branch. The
context bar, the reset clock times and the today, week, month and all-time
costs are what simple leaves out to fit.

The mode is independent of which parts are shown and of emoji labels:
`nutshell-show` and `nutshell-hide` work in both layouts, where a hidden
part drops its line in detail and its segment in simple, and icons replace
the words in both. Never hand-edit `config.json`; the script is the only writer.

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
- Any argument other than `simple`, `detail` or `toggle`: say nothing at
  all. Do not run the script, do not name the argument.

After the script ran:

- Say nothing at all, whatever happened: a mode that changed, a mode that
  was already set, a non-zero exit, a config the script could not write, an
  argument the script rejected. No output, no code block, no confirmation,
  no error. The row itself is the only report. A write that failed leaves
  the layout unchanged, which is the same thing the user sees for a mode
  that was already there.
