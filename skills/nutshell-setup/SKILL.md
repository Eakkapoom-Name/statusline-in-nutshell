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
           usage_cache_refresh.sh
  config.json
  state/   cost_cache.json  cost_ledger.json  cost_baseline.json
           rate_cache.json  auth_cache.json  usage_cache.json
           ledger_<source>.json
  locks/   sync.lock  cost_cache.lock  auth_cache.lock  usage_cache.lock
```

`nutshell-doctor.sh` and `nutshell-install-deps.sh` are deliberately not in
that list. They are setup-time tools, they run from the plugin directory,
and keeping them out of `bin/` keeps them out of the sync and uninstall
paths.

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

Four of the five are required, so exit status 1 means at least one of THOSE
is missing or too old. `curl` is the one optional entry and never affects
the exit status. `flock` and `timeout` are not reported at all: the library
carries its own lock and its own timeout, so neither tool has to be
installed on any platform.

Missing does not mean the same thing for all five. `jq` and `bash` are
stop conditions, nothing works without them. `ccusage` and `claude` leave
the install worth finishing, with rows that stay permanently empty or
wrong until they are there. `curl` costs one experimental segment and
nothing else.

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

### 2. Plan the installs, ask once, then run them

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/nutshell-setup/scripts/nutshell-install-deps.sh" --plan --porcelain
```

Same fallback path as the doctor: `"${CLAUDE_SKILL_DIR}/scripts/nutshell-install-deps.sh"`.

`--plan` changes nothing on the machine. It reads the doctor's records,
works out which channel would close each gap on this OS, asks that channel
what version it would land, and prints one record per gap:

```
plan  <dep> <run|skip> <channel> <version> <command or reason> <current verdict>
```

No records at all means nothing is missing. Skip straight to step 3 and
ask nothing.

**Ask before installing anything, exactly once, with `AskUserQuestion`.**
One question, single select, two options, never a menu and never one
question per dependency:

- Option 1: install every `run` record. The label is short, five words at
  most, and ends with `(Recommended)`, for example `Install jq and ccusage
  (Recommended)`. The `description` is where the user reads what is about
  to land on their machine: every name with its version and channel, for
  example `jq 1.7.1 via apt-get, ccusage 20.0.20 via npm`.
- Option 2: `Skip`, install nothing.

A `?` in the version column means the channel would not say (offline, or a
package index that does not answer that question). Show it as unknown
rather than leaving the version out.

If the user agrees, run exactly the names they agreed to:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/nutshell-setup/scripts/nutshell-install-deps.sh" --apply jq ccusage
```

It prints `+ <command>` before each install, re-reads the doctor afterwards,
and reports `<dep>: installed|failed|skipped, now <verdict>`. A package
manager that reports success while leaving the binary off this shell's
`PATH` therefore still comes back as `missing`, which is the answer worth
having. Exit status 1 means at least one named dependency is still not
satisfied.

Never pass `all` unless the user agreed to all of it. `--apply` installs
only the names it is given.

What the script will not do, and neither should you:

- **`claude`**: it is Claude Code itself. A `missing` record there is a
  `PATH` problem on the machine, not an install. Report it.
- **`bash`**: the plugin targets stock bash 3.2 so macOS needs no newer
  one. Report it, never install one.
- **Homebrew**: where a fix says to install Homebrew first, that is the
  user's call. It is a far larger change than any package here. Report it
  and finish the install; the rows it would have filled stay empty, which
  is only fatal for `jq`.
- **A `sudo` command that needs a password**: a tool call has no terminal,
  so the prompt could never be answered and the call would hang. The plan
  reports these as `skip` with the exact command in its reason column. Give
  the user that command and tell them they can run it here by typing
  `!` followed by it, then run the doctor again.

If the user declines, that is a complete answer. Continue with the install
and report what stays off, using the doctor's `<cost if absent>` column:

- no `jq`: the statusline cannot run at all.
- no `ccusage`: today / weekly / monthly / all-time stay empty, and
  `nutshell-reset-all-time-cost` is unavailable.
- no `claude` on `PATH`: the rate row can show a 0% window it should have
  left out.
- no `curl`: the per-model weekly window (the experimental `fable` segment)
  never appears. Nothing else changes.

### 3. Run the same script the hook runs

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/sync.sh"
```

If that path does not resolve, run `bash "${CLAUDE_SKILL_DIR}/../../hooks/sync.sh"`.

The script is idempotent, silent, and always exits 0. It creates the
directories, migrates a pre-0.3.1 install (moves the config, state files
and extra ledgers from `~/.claude/` into `nutshell/`, deletes the old
lock files, and deletes the old scripts only once every new file is in
place), copies each of the six files into `bin/` when it is missing or
differs from the bundled copy, and registers
`"statusLine": {"type": "command", "command": "bash ~/.claude/nutshell/bin/statusline.sh", "refreshInterval": 1}`
in `~/.claude/settings.json`. It skips the registration when
`config.json` says `"disabled": true` (the user made the statusline
inactive on purpose), when `settings.json` registers a statusline that
is not ours, or when `settings.json` cannot be parsed or repaired. It
never touches `config.json` or anything under `state/`, and never writes a
`.bak`: the settings repair writes only when every key survives it.

### 4. Check the result yourself, since the script reports nothing

- `ls ~/.claude/nutshell/bin/` must list all six files.
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
- `dep jq` is `missing` or `old` and the user agreed to the install: report
  the command that ran and its result. If it failed, quote the failure in a
  code block and stop: nothing else here can work without `jq`.
- A dependency reported `installed` whose verdict is still `missing`,
  after a `winget` or `scoop` install: that is the normal outcome, not a
  fault. Those write the new `PATH` where only a new terminal reads it.
  Say "`<dep>` installed. Reopen the terminal, then run this again."
- A dependency the plan marked `skip` because its fix needs a sudo
  password: "`<dep>` needs `<command>`, which needs your password. Run it
  with `!` and I will re-check." Never try to run it anyway.
- `dep jq` is `missing` and the user declined: "Without `jq` the statusline
  cannot run at all. Install it with `<fix>` when you want it back." Stop
  rather than running the sync, which would exit 0 having done nothing.
- `dep ccusage` or `dep claude` is `missing` and the user declined: finish
  the install, then one line per gap taken from its `<cost if absent>`
  column. No warning tone, a decline is a complete answer, and the rest of
  the statusline works.
- `dep ccusage` is `old`, or `probe ccusage_schema fail`: "`ccusage` is
  installed but too old for the refresher to read, so today, weekly, monthly
  and all-time stay empty. Upgrade it with `<fix>`."
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
