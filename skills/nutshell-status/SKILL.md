---
name: nutshell-status
description: Print which parts of the nutshell status line are currently on or off, covering the status line itself plus model, cost, session, workspace and emoji. Read-only. Use when the user asks what their status line is showing or whether a line or emoji mode is on.
---

# Status line state

If `~/.claude/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Run:

```bash
bash ~/.claude/statusline-toggle.sh status
```

Report the script's output verbatim, preformatted. No prose around it.
