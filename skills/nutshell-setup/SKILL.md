---
name: nutshell-setup
description: Install or repair the nutshell status line by copying the bundled scripts into ~/.claude/ and registering the statusLine command in settings.json. Use when the status line scripts are missing, the status line is broken, blank or stale, or the user asks to install, reinstall, repair, fix or update the nutshell status line. The other nutshell status line skills call this one when the scripts are missing.
---

# Install the nutshell status line

The `SessionStart` hook installs the scripts at every session start, so this
skill is the mid-session repair: it is what the other nutshell status line
skills invoke when they find `~/.claude/statusline-toggle.sh` missing, and
what you run yourself when the status line looks wrong without waiting for a
restart.

## What to do

1. The three bundled scripts live in `${CLAUDE_SKILL_DIR}/scripts/`. If that
   variable does not resolve, use the `scripts/` directory beside this
   SKILL.md.
2. For each of `statusline.sh`, `statusline-toggle.sh` and
   `cost_cache_refresh.sh`: if it is missing from `~/.claude/`, or differs
   from the bundled copy, copy the bundled copy to `~/.claude/` and
   `chmod +x` it. Do not write a `.bak`: nothing in this plugin creates
   backup files.
3. Then, unless `~/.claude/statusline.config.json` has `"disabled": true`
   (the user handed the row back to Claude Code with the nutshell-inactive skill),
   make sure `~/.claude/settings.json` carries
   `"statusLine": {"type": "command", "command": "bash ~/.claude/statusline.sh", "refreshInterval": 1}`.
   If the key is absent, or present but different, add or update it with
   `jq`, writing through a same-directory temp file and a rename. Do not
   back settings.json up. If the file exists but is not a JSON object,
   leave it untouched and skip registration rather than repairing it, and
   say so in the report. All three keys are required: without
   `refreshInterval` the status line only re-runs on assistant messages and a
   few UI events, so disk-sourced segments (advisor, cost, session) stay stale
   while the session is idle.
4. Never touch `statusline.config.json`, `.cost_cache.json`,
   `.cost_ledger.json`, `.cost_ledger_*.json`, `.cost_baseline.json`,
   `.rate_cache.json` or `.auth_cache.json`.
5. Report one line: what was copied and whether the registration changed, or
   "already up to date" when nothing needed doing.
