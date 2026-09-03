---
name: nutshell-reset-all-time-cost
description: Reset the nutshell status line's all-time cost counter to zero, leaving today, week and month untouched. Irreversible, needs ccusage, and asks for confirmation first. Use when the user asks to reset, zero or clear their all-time or lifetime cost.
---

# Reset the all-time cost

If `~/.claude/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Then run `bash ~/.claude/statusline-toggle.sh status`. If the `status-line`
row reads `off`, the status line is inactive: say so, tell the user to run
the nutshell-active skill first, and stop. The script refuses this command
while inactive anyway; checking first avoids asking a question that cannot
be acted on.

1. If `command -v ccusage` fails, tell the user this feature is unavailable
   without `ccusage` and stop.
2. Ask: "This permanently resets your all-time cost. Today/week/month stay
   unaffected. Proceed?" and wait.
3. Only after yes, run:

```bash
bash ~/.claude/statusline-toggle.sh reset-all-time --yes
```

Without `--yes` the script only warns and does nothing. Reply to the yes/no
answer with exactly "Done." or "Abort." and nothing else. Report the
script's output verbatim.
