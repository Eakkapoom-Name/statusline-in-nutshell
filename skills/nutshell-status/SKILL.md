---
name: nutshell-status
description: Print whether the nutshell statusline is active or inactive, which layout mode it uses, and which of its parts are on or off, covering cost, session, workspace and emoji. Read-only. Use when the user asks what their statusline is showing or whether a line, a layout or emoji mode is on.
---

# Statusline state

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Run:

```bash
bash ~/.claude/nutshell/bin/statusline-toggle.sh status
```

This command is read-only and works while the statusline is inactive, so
there is nothing to check first and nothing to confirm.

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

- Exit 0: the table in a code block, exactly as printed, and nothing else.
  No prose around it, no summary of the rows, no advice on what to change,
  and no extra line when the `statusline` row reads `inactive`: the table
  already says so.
- Non-zero exit with no table: "Reading the status failed: the script could
  not read `~/.claude/nutshell/config.json`. Check that the file is readable,
  then retry." Add any stderr line in a code block.
