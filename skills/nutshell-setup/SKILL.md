---
name: nutshell-setup
description: Install or repair the nutshell status line by checking its dependencies, copying the bundled scripts into ~/.claude/nutshell/bin/ and registering the statusLine command in settings.json. Use when the status line scripts are missing, the status line is broken, blank or stale, when parts of the cost line stay empty, or when the user asks to install, reinstall, repair, fix or update the nutshell status line. The other nutshell status line skills call this one when the scripts are missing.
---

# Install the nutshell status line

The `SessionStart` hook installs the scripts at every session start, so this
skill is the mid-session repair: it is what the other nutshell status line
skills invoke when they find `~/.claude/nutshell/bin/statusline-toggle.sh`
missing, and what you run yourself when the status line looks wrong without
waiting for a restart.

It is also the only place that installs dependencies. The hook never does:
installing a package changes the user's machine, and a hook that fires at
every session start must not do that, silently or otherwise.

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

`nutshell-doctor.sh` is deliberately not in that list. It is a setup-time
tool, it runs from the plugin directory, and keeping it out of `bin/` keeps
it out of the sync and uninstall paths.

## What to do

### 1. Check the dependencies first

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/nutshell-setup/scripts/nutshell-doctor.sh" --porcelain
```

If that path does not resolve, the plugin root is two directories above this
SKILL.md, so use `"${CLAUDE_SKILL_DIR}/scripts/nutshell-doctor.sh"`.

This runs first, before the sync, because `sync.sh` exits 0 and silently
does nothing when `jq` is missing. Without the doctor you would report a
successful install of something that cannot run.

The doctor only reports. It never installs, writes or reaches the network,
and it needs no `jq` itself, so it still works on the machine it is
diagnosing. Records are tab-separated:

```
os       <kind> <name> <version> <arch>
pkgmgr   <package managers found, space separated>
install  <ok|incomplete|unknown> <bin dir>
probe    ccusage_schema <ok|fail|skipped|unavailable>
dep      <name> <required|optional> <ok|old|missing> <version> <path> <fix> <cost if absent>
```

Exit status is 1 when a required dependency is missing or too old, 0
otherwise. Optional gaps never fail the run.

Add `--probe` when `ccusage` is already installed and you want to confirm
the cost windows will actually fill. It runs a real one-day `ccusage daily
--json` and checks for the `period` field the refresher reads, which is the
only reliable answer: the field name is not a documented function of the
version. It costs several seconds, so it is opt-in.

Drop `--porcelain` for a human-readable table when the user asked to see
the state of their machine rather than have it fixed.

### 2. Offer to close the gaps, never close them unasked

Every `missing` or `old` record carries the exact command for this OS in its
`<fix>` column. Ask before running any of them, with `AskUserQuestion`, and
show the commands you would run. Two rules that do not bend:

- **Never run `sudo` without showing the exact command first.** This covers
  `apt-get`/`dnf`/`pacman` and also `npm install -g`, which needs `sudo` on
  a system-installed Node.
- **Never install Homebrew for the user.** Where the fix column says to
  install it, report that and stop; it is a much larger change to their
  machine than anything else here.

If the user declines, that is a complete answer. Continue with the install
and report what stays off, using the `<cost if absent>` column:

- no `jq`: the status line cannot run at all.
- no `ccusage`: today / week / month / all-time stay empty, and
  `nutshell-reset-all-time-cost` is unavailable.
- no `claude` on `PATH`: line 3 can show a 0% row it should have left out.
- no `flock`: concurrent refreshes are not serialised. Wasted work, no data
  loss: the writes are atomic and the ledger merge is idempotent.
- no `timeout`: a hung auth probe and a hung reset are never cut short.

### 3. Run the same script the hook runs

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/sync.sh"
```

If that path does not resolve, run `bash "${CLAUDE_SKILL_DIR}/../../hooks/sync.sh"`.

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

### 4. Check the result yourself, since the script reports nothing

- `ls ~/.claude/nutshell/bin/` must list all five files.
- `jq -r '.statusLine.command // "none"' ~/.claude/settings.json` must
  print `bash ~/.claude/nutshell/bin/statusline.sh`, with three
  exceptions to report rather than fix: `config.json` has
  `"disabled": true` (leave it; the nutshell-active skill is the way
  back), the command points at a different script (someone else's status
  line; do not replace it), or `settings.json` is not a JSON object
  (the script leaves it alone until it is valid again).

### 5. Prove the cost line end to end, if ccusage was just installed

`command -v ccusage` only proves the binary is on *your* `PATH`. The status
line spawns its refresher separately, so run the real thing once, in the
foreground, and check what it wrote:

```bash
bash ~/.claude/nutshell/bin/cost_cache_refresh.sh
jq -e 'has("today_cost") and has("weekly_cost") and has("monthly_cost") and has("all_time_cost")' \
  ~/.claude/nutshell/state/cost_cache.json
```

The first run has no ledger to scan from, so it reads every transcript and
takes several seconds. That is expected, and only the first run.

### 6. Report

One line on the dependencies (what was already there, what was installed,
what the user declined and what that costs), and one line on the install
(what was installed or migrated and whether the registration is in place,
or "already up to date" when nothing needed doing).

Never hand-edit `settings.json` or `config.json`.
