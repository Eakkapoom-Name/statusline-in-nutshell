---
name: nutshell-hide
description: Turn off one line of the nutshell status line (cost, session or workspace) or all three, keeping the status line itself registered. The model line cannot be hidden. Use when the user asks to hide or blank a status line section. Not for handing the row back to Claude Code, which is the nutshell-inactive skill, and not for emoji labels, which is the nutshell-emoji skill.
argument-hint: "[all|cost|session|workspace]"
---

# Hide a status line part

If `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist, invoke the setup skill
with the Skill tool first (`nutshell:nutshell-setup` if that name is listed,
otherwise `nutshell-setup`), then continue.

Then run `bash ~/.claude/nutshell/bin/statusline-toggle.sh status`. If the `status-line`
row reads `off`, the status line is inactive: say so, tell the user to run
the nutshell-active skill first, and stop. The script refuses this command
while inactive anyway; checking first avoids asking a question that cannot
be acted on.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument.

No confirmation is needed. The model line cannot be hidden, so no
combination of these commands can leave the status line blank.

- No argument, or `all`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh all off`
  (hides cost, session and workspace; model stays on)
- `cost`, `session` or `workspace`: `bash ~/.claude/nutshell/bin/statusline-toggle.sh <part> off`
- `model`: not possible. Say the model line is always shown, and that the
  nutshell-inactive skill is the way to give the whole row back to Claude
  Code. Do not run the script.
- `emoji`: not handled here. Tell the user to use the nutshell-emoji skill.
- Anything else: say the part is not recognised and list all, cost,
  session, workspace.

Hiding is not the same as inactive: hiding keeps the registration, so line 1
stays on screen and Claude Code's own footer stays suppressed, while the
nutshell-inactive skill removes the registration and brings that footer
back.

Report the script's output verbatim. No prose, no mention of unchanged
parts. Never hand-edit `statusline.config.json` or `settings.json`; the
script is the only writer.
