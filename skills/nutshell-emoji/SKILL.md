---
name: nutshell-emoji
description: Switch the nutshell status line labels between text and emoji icons. No argument toggles the mode, or say on or off. Use when the user mentions emoji, icons or text labels on their status line.
argument-hint: "[on|off]"
---

# Emoji labels

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

- No argument: `bash ~/.claude/statusline-toggle.sh emoji` (the script
  defaults to toggle)
- `on` or `off`: `bash ~/.claude/statusline-toggle.sh emoji on|off`

Emoji mode is independent of which parts are shown, and it is off by
default. This skill is the only way to change it: the nutshell-show and
nutshell-hide skills do not accept `emoji`. Report the script's output verbatim. Never hand-edit
`statusline.config.json`; the script is the only writer.
