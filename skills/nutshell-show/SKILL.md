---
name: nutshell-show
description: Turn on one line of the nutshell status line (model, cost, session or workspace) or all four at once. Use when the user asks to show, display, enable or bring back a status line section. Emoji labels are a separate switch, handled by the nutshell-emoji skill.
argument-hint: "[all|model|cost|session|workspace]"
---

# Show a status line part

If `~/.claude/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Then run `bash ~/.claude/statusline-toggle.sh status`. If the `status-line`
row reads `off`, the status line is inactive: say so, tell the user to run
the nutshell-active skill first, and stop. The script refuses this command
while inactive anyway; checking first avoids asking a question that cannot
be acted on.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

- No argument, or `all`: `bash ~/.claude/statusline-toggle.sh all on`
- `model`, `cost`, `session` or `workspace`: `bash ~/.claude/statusline-toggle.sh <part> on`
- `emoji`: not handled here. Tell the user to use the nutshell-emoji skill.
- Anything else: say the part is not recognised and list all, model, cost,
  session, workspace.

Report the script's output verbatim (`part: state` lines). No prose, no
mention of unchanged parts. Never hand-edit `statusline.config.json` or
`settings.json`; the script is the only writer.
