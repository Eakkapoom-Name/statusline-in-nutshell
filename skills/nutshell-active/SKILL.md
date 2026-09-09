---
name: nutshell-active
description: Re-register the nutshell statusline in settings.json after it was made inactive, restoring the saved per-line settings. Takes --force to replace a statusline registered by something else. Use when the user asks to activate their statusline again, turn it back on, restore or re-enable it.
argument-hint: "[--force]"
---

# Register the statusline again

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

- No argument: `bash ~/.claude/nutshell/bin/statusline-toggle.sh on`
- `--force`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh on --force`
- Anything else: do not run the script. Answer with the matching template
  below. The script would silently ignore an unknown argument and register
  without `--force`, which is not what the user asked for.

Never add `--force` unless the user asked for it. Never hand-edit
`settings.json`; the script is the only writer.

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
- Any argument other than `--force`: "`<arg>` is not an argument this
  command takes. Use `/nutshell:nutshell-active` on its own, or
  `/nutshell:nutshell-active --force` to replace a statusline registered by
  something else."

After the script ran:

- stdout `statusline: on, restored with your saved part settings.`:
  "Activate statusline, saved part settings and sync updates within a
  second." No code block.
- stdout `statusline: already on`: "The statusline is already active.
  Nothing changed."
- stderr says `already registers a different status`: the stderr in a code
  block, then "Foreign statusline plugin or skill, nothing was changed. Run
  `/nutshell:nutshell-active --force` to replace it." Stop, and do not run
  `--force` on your own.
- stderr says `is not valid JSON, leaving it alone`: the script already
  tried the silent repair (a BOM, `//` or `/* */` comments, a trailing
  comma, or a file that is valid JSON but not an object) and the damage was
  something else, so nothing was written. Say "`~/.claude/settings.json`
  could not be parsed or repaired, the registration was aborted. Fix the
  file, then run `/nutshell:nutshell-active` again." Stop.
- stderr says `could not update settings.json, statusline left off` with no
  JSON message above it: the script already retried after adding the owner
  write bit, so the cause is something it cannot fix (a read-only mount, a
  full disk, an immutable file, or a file owned by someone else). Say
  "Writing `~/.claude/settings.json` failed, the statusline is still
  inactive. Check that the file and `~/.claude/` are writable, then retry
  `/nutshell:nutshell-active` again." Add the stderr in a code block.
