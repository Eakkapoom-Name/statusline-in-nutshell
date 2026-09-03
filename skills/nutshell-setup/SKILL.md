---
name: nutshell-setup
description: Install or repair the nutshell status line by copying the bundled scripts into ~/.claude/nutshell/bin/ and registering the statusLine command in settings.json. Use when the status line scripts are missing, the status line is broken, blank or stale, or the user asks to install, reinstall, repair, fix or update the nutshell status line. The other nutshell status line skills call this one when the scripts are missing.
---

# Install the nutshell status line

The `SessionStart` hook installs the scripts at every session start, so this
skill is the mid-session repair: it is what the other nutshell status line
skills invoke when they find `~/.claude/nutshell/bin/statusline-toggle.sh`
missing, and what you run yourself when the status line looks wrong without
waiting for a restart.

Everything this plugin owns lives under `~/.claude/nutshell/`:

```
~/.claude/nutshell/
  bin/     nutshell-lib.sh  statusline.sh  statusline-toggle.sh
           cost_cache_refresh.sh  auth_cache_refresh.sh
  config.json
  state/   cost_cache.json  cost_ledger.json  cost_baseline.json
           rate_cache.json  auth_cache.json  ledger_<source>.json
  locks/   sync.lock  cost_cache.lock  auth_cache.lock
```

## What to do

1. Run the same script the hook runs:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/sync.sh"
   ```

   If that path does not resolve, the plugin root is two directories above
   this SKILL.md, so run `bash "${CLAUDE_SKILL_DIR}/../../hooks/sync.sh"`.

   The script is idempotent, silent, and always exits 0. It creates the
   directories, migrates a pre-0.3.1 install (moves the config, state files
   and extra ledgers from `~/.claude/` into `nutshell/`, deletes the old
   lock files, and deletes the old scripts only once every new file is in
   place), copies each of the five files into `bin/` when it is missing or
   differs from the bundled copy, and registers
   `"statusLine": {"type": "command", "command": "bash ~/.claude/nutshell/bin/statusline.sh", "refreshInterval": 1}`
   in `~/.claude/settings.json`. It skips the registration when
   `config.json` says `"disabled": true` (the user made the status line
   inactive on purpose), when `settings.json` registers a status line that
   is not ours, or when `settings.json` is not a JSON object. It never
   touches `config.json` or anything under `state/`, and never writes a
   `.bak`.

2. Check the result yourself, since the script reports nothing:

   - `ls ~/.claude/nutshell/bin/` must list all five files.
   - `jq -r '.statusLine.command // "none"' ~/.claude/settings.json` must
     print `bash ~/.claude/nutshell/bin/statusline.sh`, with three
     exceptions to report rather than fix: `config.json` has
     `"disabled": true` (leave it; the nutshell-active skill is the way
     back), the command points at a different script (someone else's status
     line; do not replace it), or `settings.json` is not a JSON object
     (the script leaves it alone until it is valid again).

3. Report one line: what was installed or migrated and whether the
   registration is in place, or "already up to date" when nothing needed
   doing. Never hand-edit `settings.json` or `config.json`.
