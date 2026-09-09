---
name: nutshell-uninstall
description: Remove the nutshell statusline, unregistering it and deleting the installed scripts from ~/.claude/, optionally purging the toggle config and cost history. Asks for confirmation first. Use when the user asks to uninstall or completely remove the nutshell statusline.
argument-hint: "[--purge]"
---

# Uninstall the statusline

Do not run the setup skill from here. If `~/.claude/nutshell/bin/statusline-toggle.sh`
does not exist, say nothing is installed and stop. This is the one nutshell
skill that never repairs an install it is about to remove.

Argument: $0

If that line above is blank, or still shows the unreplaced placeholder (a
dollar sign followed by a zero), there is no argument. Treat `--purge`, or
an explicit request to wipe config and cost history, as the purge variant.

1. Tell the user that once this is done they must remove the `nutshell`
   plugin from the `/plugin` menu, since its `SessionStart` hook would
   otherwise reinstall the scripts next session. Say it before the
   confirmation, not after, but do not wait for them to do it: removing the
   plugin first would take this command with it.
2. Ask: "This removes the statusline registration and deletes the installed
   scripts from ~/.claude/nutshell/bin/. Your toggle config and cost history
   are kept. Proceed?" For the purge variant, ask instead: "This removes the
   statusline registration and the whole ~/.claude/nutshell/ directory, so
   your toggle config and cost history go too, including any cost ledgers
   written by other tools and any .bak files left by versions before 0.3.1.
   Proceed?" Wait for an answer.
3. Only after yes, run one of:

```bash
bash ~/.claude/nutshell/bin/statusline-toggle.sh uninstall --yes
bash ~/.claude/nutshell/bin/statusline-toggle.sh uninstall --yes --purge
```

Without `--yes` the script only warns and does nothing.

## How to answer

Short and plain. One template per situation. Quote script output in a code
block only where a template says so, and add nothing else.

The self-repair rule the other skills follow is inverted here: never invoke
setup from this skill. A missing script means there is nothing to uninstall,
and reinstalling it first would be the opposite of what was asked.

Before the script runs:

- `~/.claude/nutshell/bin/statusline-toggle.sh` does not exist: "Nothing is
  installed at `~/.claude/nutshell/bin/`, so there is nothing to uninstall."
  Stop.
- stderr says `nutshell-lib.sh is missing`: "The install is already
  incomplete: `~/.claude/nutshell/bin/nutshell-lib.sh` is gone, so the
  uninstall command cannot run. Delete `~/.claude/nutshell/` yourself, and
  remove the `statusLine` key from `~/.claude/settings.json`." Stop.
- stderr says `jq is required`: "`jq` is not installed, so the uninstall
  command cannot run. Install `jq` and ask again, or delete
  `~/.claude/nutshell/` yourself and remove the `statusLine` key from
  `~/.claude/settings.json`." Stop.
- Any argument other than `--purge`: "`<arg>` is not an argument this
  command takes. Use `/nutshell:nutshell-uninstall` on its own, or
  `/nutshell:nutshell-uninstall --purge` to delete the config and cost
  history too."
- The user answers no: "Abort." and nothing else. Do not run the script.

After the script ran, on a yes:

- stdout starts `uninstalled:` (either variant): that line in a code block,
  then "Remove the `nutshell` plugin from `/plugin` as well, or the
  `SessionStart` hook reinstalls the scripts next session." Then "Done." on
  its own line, last.
- No `uninstalled:` line at all: "The uninstall did not complete. Check that
  `~/.claude/nutshell/` and `~/.claude/settings.json` are writable, then
  retry." Add any stderr line in a code block.
- stderr says `'uninstall' removes the statusline registration`: "The
  confirmation flag was missing, so nothing was removed. This is a bug in
  the skill, not your input."
