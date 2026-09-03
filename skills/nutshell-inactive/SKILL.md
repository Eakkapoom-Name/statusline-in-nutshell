---
name: nutshell-inactive
description: Unregister the nutshell status line so Claude Code shows its own default footer again, keeping the per-line settings for later. Use when the user asks to make the status line inactive, turn it off, disable it, or get the default footer back. Not for hiding a single line, which is the nutshell-hide skill.
---

# Hand the row back to Claude Code

If `~/.claude/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Run:

```bash
bash ~/.claude/statusline-toggle.sh off
```

This is not the same as hiding: inactive removes the registration from
settings.json so Claude Code shows its own footer, while the nutshell-hide
skill keeps the registration and prints a blank row. The choice is
remembered, so the sync hook will not put the status line back at the next
session start.

Report the script's output verbatim. Never hand-edit `settings.json`; the
script is the only writer, and it backs the file up first.
