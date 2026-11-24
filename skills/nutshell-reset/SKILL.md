---
name: nutshell-reset
description: Put the nutshell statusline back to the look a fresh install has, undoing every show, hide, emoji, mode and color change at once. Keeps whether the statusline is active or inactive, and keeps its caches. Use when the user asks to reset the statusline, restore its defaults, start over or undo their customizations.
---

# Reset to the default look

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

- No argument: `bash ~/.claude/nutshell/bin/statusline-toggle.sh reset`
- Anything else: do not run the script, and answer with the template below.

The reset puts back what a new install starts with. The script takes the
values from its own defaults, and its `reset:` line names them; today they
are the session and workspace parts shown, cost hidden, text labels rather
than emoji, the one-line simple layout and the orange accent. It changes
nothing else: an inactive statusline stays inactive (run
`/nutshell:nutshell-active` to show it), `settings.json` is not touched, and
the caches and any cost history stay. Unlike `show`, `hide`, `emoji`, `mode`
and `color`, it also runs while the statusline is inactive. Never hand-edit
`config.json`; the script is the only writer.

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
- Any argument at all: "`/nutshell:nutshell-reset` takes no argument. Run it
  on its own to restore the default look." Do not run the script.

After the script ran:

- stdout starts `reset:` and there is no second line: say nothing at all.
  The row itself is the report.
- stdout also says `still inactive`: "The default look is restored. The
  statusline is inactive, so run `/nutshell:nutshell-active` to show it."
- stderr says `could not write`: "The reset did not complete. Check that
  `~/.claude/nutshell/config.json` is writable, then retry." Add that
  stderr line in a code block.
