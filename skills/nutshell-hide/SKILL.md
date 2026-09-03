---
name: nutshell-hide
description: Turn off one line of the nutshell status line (model, cost, session or workspace) or all four, keeping the status line itself registered. Use when the user asks to hide or blank a status line section. Not for handing the row back to Claude Code, which is the nutshell-inactive skill, and not for emoji labels, which is the nutshell-emoji skill.
argument-hint: "[all|model|cost|session|workspace]"
---

# Hide a status line part

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

Before a change that would leave model, cost, session and workspace all off,
ask: "Hiding all parts will leave the status line blank. Do you want to
proceed?" and wait. A bare hide, or `all`, always triggers this. For a single
part, run `bash ~/.claude/statusline-toggle.sh status` first and ask only
when the other three parts are already off. Reply to a yes/no answer with
exactly "Done." or "Abort." and nothing else.

- No argument, or `all`: `bash ~/.claude/statusline-toggle.sh all off`
- `model`, `cost`, `session` or `workspace`: `bash ~/.claude/statusline-toggle.sh <part> off`
- `emoji`: not handled here. Tell the user to use the nutshell-emoji skill.
- Anything else: say the part is not recognised and list all, model, cost,
  session, workspace.

Hiding is not the same as inactive: hiding keeps the registration and prints
a blank row, while the nutshell-inactive skill removes the registration so
Claude Code shows its own footer.

Report the script's output verbatim. No prose, no mention of unchanged
parts. Never hand-edit `statusline.config.json` or `settings.json`; the
script is the only writer.
