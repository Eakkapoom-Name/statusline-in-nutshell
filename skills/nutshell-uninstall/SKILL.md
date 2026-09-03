---
name: nutshell-uninstall
description: Remove the nutshell status line, unregistering it and deleting the installed scripts from ~/.claude/, optionally purging the toggle config and cost history. Asks for confirmation first. Use when the user asks to uninstall or completely remove the nutshell status line.
argument-hint: "[--purge]"
---

# Uninstall the status line

Do not run the setup skill from here. If `~/.claude/statusline-toggle.sh`
does not exist, say nothing is installed and stop.

This skill lives at `${CLAUDE_SKILL_DIR}`. If that path is under
`~/.claude/skills/`, this is the npx install; otherwise it is the plugin
install.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument. Treat `--purge`, or
an explicit request to wipe config and cost history, as the purge variant.

1. On the plugin install, first tell the user to remove the `nutshell`
   plugin from the `/plugin` menu, since its `SessionStart` hook would
   otherwise reinstall the scripts next session.
2. Ask: "This removes the status line registration and deletes the installed
   scripts from ~/.claude/. Your toggle config and cost history are kept.
   Proceed?" For the purge variant, ask instead: "This removes the status
   line registration, deletes the installed scripts from ~/.claude/, and
   also wipes your toggle config and cost history. Proceed?" Wait for an
   answer and reply with exactly "Done." or "Abort." and nothing else.
3. Only after yes, run one of:

```bash
bash ~/.claude/statusline-toggle.sh uninstall --yes
bash ~/.claude/statusline-toggle.sh uninstall --yes --purge
```

Without `--yes` the script only warns and does nothing.
4. On the npx install, tell the user afterwards to remove the skills
   themselves:

```bash
npx skills remove nutshell-setup nutshell-status nutshell-show nutshell-hide nutshell-emoji nutshell-active nutshell-inactive nutshell-reset-all-time-cost nutshell-uninstall
```

Report the script's output verbatim.
