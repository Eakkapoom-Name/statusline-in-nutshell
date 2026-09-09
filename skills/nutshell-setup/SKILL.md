---
name: nutshell-setup
description: Install or repair the nutshell statusline by checking its dependencies, copying the bundled scripts into ~/.claude/nutshell/bin/ and registering the statusLine command in settings.json. Use when the statusline scripts are missing, the statusline is broken, blank or stale, when parts of the cost line stay empty, or when the user asks to install, reinstall, repair, fix or update the nutshell statusline. The other nutshell statusline skills call this one when the scripts are missing.
---

# Install the nutshell statusline

The `SessionStart` hook installs the scripts at every session start, so this
skill is the mid-session repair: it is what the other nutshell statusline
skills invoke when they find `~/.claude/nutshell/bin/statusline-toggle.sh`
missing, and what you run yourself when the statusline looks wrong without
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
dep      <name> <required> <ok|old|missing> <version> <path> <fix> <cost if absent>
```

Every dependency is required as of 0.3.4, so exit status 1 means at least
one of them is missing or too old, and 0 means all four are present. The
tier column is kept in the record shape because the porcelain format is
parsed, not because anything reports `optional` any more. `flock` and
`timeout` are no longer reported at all: the library carries its own lock
and its own timeout, so neither tool has to be installed on any platform.

Missing does not mean the same thing for all four. `jq` and `bash` are
stop conditions, nothing works without them. `ccusage` and `claude` leave
the install worth finishing, with rows that stay permanently empty or
wrong until they are there.

Add `--probe` when `ccusage` is already installed and you want to confirm
the cost windows will actually fill. It runs a real one-day `ccusage daily
--json` and checks for the `period` field the refresher reads, which is the
only reliable answer: the field name is not a documented function of the
version. It costs several seconds, so it is opt-in.

A `probe ccusage_schema fail` is not a separate thing to handle: the
`dep ccusage` record is reported `old` in that case, with an upgrade command
in its fix column, so step 2 below already acts on it. An installed binary
answering with a schema the refresher cannot read leaves the cost windows
just as empty as no binary at all.

Drop `--porcelain` for a human-readable table when the user asked to see
the state of their machine rather than have it fixed.

### 2. Offer to close the gaps, never close them unasked

Every `missing` or `old` record carries a `<fix>` column. For `jq`, `bash`
and `ccusage` it is the exact command for this OS. For `claude` it is prose,
since the binary is Claude Code itself and a gap there is a `PATH` problem
with no install command to offer. Ask before running any command, with
`AskUserQuestion`, and show what you would run. Two rules that do not bend:

- **Never run `sudo` without showing the exact command first.** This covers
  `apt-get`/`dnf`/`pacman` and also `npm install -g`, which needs `sudo` on
  a system-installed Node.
- **Never install Homebrew for the user.** Where the fix column says to
  install it, report that and leave it to them; it is a much larger change
  to their machine than anything else here. Reporting it is not a reason to
  abandon the install: finish the sync and say which rows stay empty, unless
  the gap is `jq` or `bash`.

If the user declines, that is a complete answer. Continue with the install
and report what stays off, using the `<cost if absent>` column:

- no `jq`: the statusline cannot run at all.
- no `ccusage`: today / week / month / all-time stay empty, and
  `nutshell-reset-all-time-cost` is unavailable.
- no `claude` on `PATH`: line 3 can show a 0% row it should have left out.

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
`config.json` says `"disabled": true` (the user made the statusline
inactive on purpose), when `settings.json` registers a statusline that
is not ours, or when `settings.json` cannot be parsed or repaired. It
never touches `config.json` or anything under `state/`, and never writes a
`.bak`: the settings repair writes only when every key survives it.

### 4. Check the result yourself, since the script reports nothing

- `ls ~/.claude/nutshell/bin/` must list all five files.
- `jq -r '.statusLine.command // "none"' ~/.claude/settings.json` must
  print `bash ~/.claude/nutshell/bin/statusline.sh`, with three
  exceptions to report rather than fix: `config.json` has
  `"disabled": true` (leave it; the nutshell-active skill is the way
  back), the command points at a different script (someone else's status
  line; do not replace it), or `settings.json` is not a JSON object
  (the script repairs a BOM, comments, a trailing comma or a non-object
      by itself, and leaves anything else alone until it is valid again).

### 5. Prove the cost line end to end, if ccusage was just installed

`command -v ccusage` only proves the binary is on *your* `PATH`. Run the
real refresher once, in the foreground, and check what it wrote:

```bash
bash ~/.claude/nutshell/bin/cost_cache_refresh.sh
jq -e 'has("today_cost") and has("weekly_cost") and has("monthly_cost") and has("all_time_cost")' \
  ~/.claude/nutshell/state/cost_cache.json
```

The first run has no ledger to scan from, so it reads every transcript and
takes several seconds. That is expected, and only the first run.

This run inherits your `PATH`, which is the one thing it cannot prove. The
statusline spawns its own refresher, and a `ccusage` under a prefix that
Claude Code's `PATH` lacks (a user-local npm prefix is the usual one) passes
this check and still leaves the cost line empty, which is the exact symptom
this whole step exists to rule out. So confirm the *spawned* refresher runs
too, by watching the cache be rewritten again without you:

```bash
before=$(jq -r .updated_at ~/.claude/nutshell/state/cost_cache.json)
# wait for the next turn to finish, then:
jq -r --argjson b "$before" 'if .updated_at > $b then "spawned refresh ok" else "still \($b): the statusline cannot reach ccusage" end' \
  ~/.claude/nutshell/state/cost_cache.json
```

Wait for the next turn to finish. The plugin's `Stop` hook refreshes the
cache within 10s of a turn ending, under Claude Code's own environment,
which is exactly the spawned path this is meant to prove, so the answer
comes one turn later rather than after minutes of idling. If you are not
going to wait for it, say so rather than reporting a clean bill of health:
tell the user the foreground run passed and that a `ccusage` outside Claude
Code's `PATH` would still leave the row empty.

## How to answer

Short and plain. One template per situation. Quote script output in a code
block only where a template says so, and add nothing else. Never echo the
doctor's `--porcelain` records to the user: they are input for you, not a
report. Say what is missing and what it costs, in words.

Two lines at the end, always in this order:

1. The dependencies: what was already there, what was installed, what the
   user declined and what that costs.
2. The install: what was copied or migrated and whether the registration is
   in place, or "already up to date" when nothing needed doing.

Per outcome:

- Doctor exits 0, sync copies nothing, registration already ours: "Every
  dependency is present and the statusline is already up to date. Nothing
  changed."
- Doctor exits 0, sync copied or migrated files: name what landed in
  `~/.claude/nutshell/bin/` and say "The row updates within a second."
- `dep jq` is `missing` or `old` and the user agreed to the fix: report the
  command that ran and its result. If it failed, quote the failure in a
  code block and stop: nothing else here can work without `jq`.
- `dep jq` is `missing` and the user declined: "Without `jq` the statusline
  cannot run at all. Install it with `<fix>` when you want it back." Stop
  rather than running the sync, which would exit 0 having done nothing.
- `dep ccusage` or `dep claude` is `missing` and the user declined: finish
  the install, then one line per gap taken from its `<cost if absent>`
  column. No warning tone, a decline is a complete answer, and the rest of
  the statusline works.
- `dep ccusage` is `old`, or `probe ccusage_schema fail`: "`ccusage` is
  installed but too old for the refresher to read, so today, week, month and
  all-time stay empty. Upgrade it with `<fix>`."
- Registration skipped because `config.json` says `"disabled": true`: "The
  scripts are up to date. The statusline is inactive on purpose, so it was
  not registered. Run `/nutshell:nutshell-active` to bring it back."
- Registration skipped because `settings.json` registers a different
  statusline: "The scripts are up to date. `settings.json` registers another
  statusline, so it was left alone. Run `/nutshell:nutshell-active --force`
  to replace it." Never force it yourself.
- Registration skipped because `settings.json` could not be parsed or
  repaired: "The scripts are up to date. `~/.claude/settings.json` could not
  be parsed or repaired, so it was left untouched. Fix the file, then run
  this again." The silent repair covers a BOM, `//` and `/* */` comments, a
  trailing comma, and a file that is valid JSON but not an object; anything
  else needs the user.
- Step 5 ran and the spawned refresh was not waited for: say the foreground
  run passed and that a `ccusage` outside Claude Code's own `PATH` would
  still leave the cost row empty. Do not report a clean bill of health you
  did not verify.
- The doctor itself cannot run (missing, or non-zero with no records): say
  which path you tried, then run the sync anyway and report its result. The
  doctor is a report, not a gate: only a missing `jq` or `bash` stops the
  install, and a non-zero exit on its own never does.

Never hand-edit `settings.json` or `config.json`.
