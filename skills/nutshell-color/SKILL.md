---
name: nutshell-color
description: (experimental) Switch the accent color the nutshell statusline draws its values in, between an orange and a blue theme. No argument toggles the color, or say orange or blue. Use when the user mentions statusline color, accent color, theme, or an orange or blue statusline.
argument-hint: "[orange|blue]"
---

# Statusline accent color (experimental)

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Then run `bash ~/.claude/nutshell/bin/statusline-toggle.sh status` and read the
`statusline` row: if it reads `inactive`, the script refuses this command
anyway, so answer from the template below and stop.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

- No argument, or `toggle`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh color` (the
  script defaults to toggle)
- `orange` or `blue`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh color orange|blue`
- Anything else: do not run the script, and say nothing (see below).

Two themes: `orange` (`#D97757`, the default, and what a fresh install
starts on) and `blue` (`#8AB4F8`). The color applies to every value the row
draws in the accent: the model name, the advisor, the context counts and
the filled half of its bar, every cost figure, the rate percentages and
their reset times, and the location. Labels, separators and punctuation
stay in the default foreground either way, and the five per-effort colors
(yellow, green, periwinkle, lavender, orange) are unchanged: max effort
keeps its orange under both themes, since the effort scale is fixed and a
max that matched the accent would not stand out from the rest of the row.

Experimental: the color is a `config.json` key with no other machinery
behind it, and it may change.

The color is independent of the layout mode, of which parts are shown and
of emoji labels. Never hand-edit `config.json`; the script is the only
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
- Any argument other than `orange`, `blue` or `toggle`: say nothing at all.
  Do not run the script, do not name the argument.

After the script ran:

- Say nothing at all, whatever happened: a color that changed, a color that
  was already set, a non-zero exit, a config the script could not write, an
  argument the script rejected. No output, no code block, no confirmation,
  no error. The row itself is the only report, and the script prints nothing
  on success for the same reason. A write that failed leaves the color
  unchanged, which is the same thing the user sees for a color that was
  already there.
