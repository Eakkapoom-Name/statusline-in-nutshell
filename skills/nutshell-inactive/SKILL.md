---
name: nutshell-inactive
description: Unregister the nutshell statusline so Claude Code shows its own default footer again, keeping the per-line settings for later. Use when the user asks to make the statusline inactive, turn it off, disable it, or get the default footer back. Not for hiding a single line, which is the nutshell-hide skill.
---

# Hand the row back to Claude Code

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Run:

```bash
bash ~/.claude/nutshell/bin/statusline-toggle.sh off
```

This takes no argument and needs no confirmation.

This is not the same as hiding: inactive removes the registration from
settings.json so Claude Code shows its own footer, while the nutshell-hide
skill keeps the registration, which leaves that footer suppressed and line 1
rendering. Inactive also stops the tracking: `statusline.sh` exits before
printing anything or spawning the background cost refresh and auth probe, so
a session that still holds the old registration stops doing that work at
once rather than waiting on a restart. The choice is
remembered, so the sync hook will not put the statusline back at the next
session start.

Never hand-edit `settings.json`; the script is the only writer.

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

After the script ran:

- stdout starts `statusline: off.`: "Statusline inactive and resume default
  statusline. Settings are kept and sync stop." No code block.
- stdout `statusline: already off (Claude Code's own footer is showing)`:
  "The statusline is already inactive. Nothing changed."
- stderr says `Refusing to remove someone else's registration`: the stderr
  in a code block, then "Foreign statusline plugin or skill, nothing was
  changed. Remove it yourself if that is what you want." Stop.
- stderr says `is not valid JSON, leaving it alone`: the script already
  tried the silent repair (a BOM, `//` or `/* */` comments, a trailing
  comma, or a file that is valid JSON but not an object) and the damage was
  something else, so nothing was written. Say "`~/.claude/settings.json`
  could not be parsed or repaired, the unregistration was aborted. Fix the
  file, then run `/nutshell:nutshell-inactive` again." Stop.
- stderr says `could not update settings.json, statusline left on` with no
  JSON message above it: the script already retried after adding the owner
  write bit, so the cause is something it cannot fix (a read-only mount, a
  full disk, an immutable file, or a file owned by someone else). Say
  "Writing `~/.claude/settings.json` failed, the statusline is still active.
  Check that the file and `~/.claude/` are writable, then retry
  `/nutshell:nutshell-inactive` again." Add the stderr in a code block.
