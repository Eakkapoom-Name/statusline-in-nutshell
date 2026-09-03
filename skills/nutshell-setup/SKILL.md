---
name: nutshell-setup
description: Install or repair the nutshell status line by copying the bundled scripts into ~/.claude/nutshell/bin/ and registering the statusLine command in settings.json. Use when the status line scripts are missing, the status line is broken, blank or stale, or the user asks to install, reinstall, repair, fix or update the nutshell status line. The other nutshell status line skills call this one when the scripts are missing.
---

# Install the nutshell status line

The `SessionStart` hook installs the scripts at every session start, so this
skill is the mid-session repair: it is what the other nutshell status line
skills invoke when they find `~/.claude/nutshell/bin/statusline-toggle.sh` missing, and
what you run yourself when the status line looks wrong without waiting for a
restart.

Everything this plugin owns lives under `~/.claude/nutshell/`:

```
~/.claude/nutshell/
  bin/     statusline.sh  statusline-toggle.sh  cost_cache_refresh.sh
  config.json
  state/   cost_cache.json  cost_ledger.json  cost_baseline.json
           rate_cache.json  auth_cache.json  ledger_<source>.json
  locks/   sync.lock  cost_cache.lock  auth_cache.lock
```

## What to do

1. The three bundled scripts live in `${CLAUDE_SKILL_DIR}/scripts/`. If that
   variable does not resolve, use the `scripts/` directory beside this
   SKILL.md.
2. Create `~/.claude/nutshell/bin/`, `~/.claude/nutshell/state/` and
   `~/.claude/nutshell/locks/` if they do not exist.
3. Migrate a pre-0.3.1 install, which kept everything loose in `~/.claude/`.
   Move each of these, and only when the destination does not already exist,
   so an already-migrated or half-migrated install is left alone:
   `statusline.config.json` to `nutshell/config.json`, `.cost_cache.json`,
   `.cost_ledger.json`, `.cost_baseline.json`, `.rate_cache.json` and
   `.auth_cache.json` to `nutshell/state/` under their names without the
   leading dot (`cost_cache.json` and so on), and each
   `.cost_ledger_<source>.json` to `nutshell/state/ledger_<source>.json`.
   Delete the old lock files (`.cost_cache.lock`, `.auth_cache.json.lock`,
   `.statusline-sync.lock`); they hold nothing.
4. For each of `statusline.sh`, `statusline-toggle.sh` and
   `cost_cache_refresh.sh`: if it is missing from `~/.claude/nutshell/bin/`,
   or differs from the bundled copy, copy the bundled copy there and
   `chmod +x` it. Do not write a `.bak`: nothing in this plugin creates
   backup files. Once all three are in place, delete any pre-0.3.1 copies
   still sitting at `~/.claude/statusline.sh`,
   `~/.claude/statusline-toggle.sh` and `~/.claude/cost_cache_refresh.sh`.
   Not before: if a copy failed, those old files are still the working
   install.
5. Then, unless `~/.claude/nutshell/config.json` has `"disabled": true`
   (the user handed the row back to Claude Code with the nutshell-inactive skill),
   make sure `~/.claude/settings.json` carries
   `"statusLine": {"type": "command", "command": "bash ~/.claude/nutshell/bin/statusline.sh", "refreshInterval": 1}`.
   If the key is absent, or present but different, add or update it with
   `jq`, writing through a same-directory temp file and a rename. Do not
   back settings.json up. If the file exists but is not a JSON object,
   leave it untouched and skip registration rather than repairing it, and
   say so in the report. All three keys are required: without
   `refreshInterval` the status line only re-runs on assistant messages and a
   few UI events, so disk-sourced segments (advisor, cost, session) stay stale
   while the session is idle. A `statusLine` pointing at
   `~/.claude/statusline.sh` is a pre-0.3.1 registration of ours and should be
   replaced; one pointing anywhere else belongs to something else, so leave it
   and report that instead.
6. Never touch `config.json` or anything under `state/`.
7. Report one line: what was copied or migrated and whether the registration
   changed, or "already up to date" when nothing needed doing.
