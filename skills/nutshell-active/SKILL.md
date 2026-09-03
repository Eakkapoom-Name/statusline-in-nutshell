---
name: nutshell-active
description: Re-register the nutshell status line in settings.json after it was made inactive, restoring the saved per-line settings. Takes --force to replace a status line registered by something else. Use when the user asks to activate their status line again, turn it back on, restore or re-enable it.
argument-hint: "[--force]"
---

# Register the status line again

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

- No argument: `bash ~/.claude/nutshell/bin/statusline-toggle.sh on`
- `--force`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh on --force`

If the script refuses because settings.json registers a different status
line, show its message verbatim and stop. Never add `--force` unless the
user asked for it.

Report the script's output verbatim. Never hand-edit `settings.json`; the
script is the only writer.
