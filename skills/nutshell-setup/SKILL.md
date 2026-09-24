---
name: nutshell-setup
description: Install or repair the nutshell statusline by checking its dependencies, copying the bundled scripts into ~/.claude/nutshell/bin/ and registering the statusLine command in settings.json. Use when the statusline scripts are missing, the statusline is broken, blank or stale, or when the user asks to install, reinstall, repair, fix or update the nutshell statusline. The other nutshell statusline skills call this one when the scripts are missing.
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
           auth_cache_refresh.sh  account_usage_cache_refresh.sh
  config.json
  state/   shared_rate_limit_cache.json  auth_cache.json  account_usage_cache.json
  locks/   sync.lock  auth_cache.lock  account_usage_cache.lock
```

An install from before the ccusage cost windows were retired may still
hold `state/cost_cache.json`, `cost_ledger.json`, `cost_baseline.json`,
`ledger_<source>.json` and `locks/cost_cache.lock`. Nothing reads them any
more; `uninstall --purge` removes them. The sync deletes the old
`bin/cost_cache_refresh.sh` itself.

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
dep      <name> <required> <ok|old|missing> <version> <path> <fix> <cost if absent>
```

Three of the four are required, so exit status 1 means at least one of THOSE
is missing or too old. `curl` is the one optional entry and never affects
the exit status. `flock` and `timeout` are not reported at all: the library
carries its own lock and its own timeout, so neither tool has to be
installed on any platform.

Missing does not mean the same thing for all four. `jq` and `bash` are
stop conditions, nothing works without them. `claude` leaves the install
worth finishing, with a rate row that can be wrong until it is there.
`curl` costs one experimental segment, and leaves the rate percentages
waiting for a reply before they refresh.

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
  most, and ends with `(Recommended)`, for example `Install jq and curl
  (Recommended)`. The `description` is where the user reads what is about
  to land on their machine: every name with its version and channel, for
  example `jq 1.7.1 via apt-get, curl 8.5.0 via apt-get`.
- Option 2: `Skip`, install nothing.

A `?` in the version column means the channel would not say (offline, or a
package index that does not answer that question). Show it as unknown
rather than leaving the version out.

If the user agrees, run exactly the names they agreed to:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/nutshell-setup/scripts/nutshell-install-deps.sh" --apply jq curl
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
- no `claude` on `PATH`: the rate row can show a 0% window it should have
  left out.
- no `curl`: the per-model weekly window (the experimental `fable` segment)
  never appears, and the 5-hour and weekly percentages refresh only when a
  session gets a reply, rather than on their own every few minutes.

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
differs from the bundled copy, deletes a `bin/` script an older version
installed that is no longer shipped, and registers
`"statusLine": {"type": "command", "command": "bash ~/.claude/nutshell/bin/statusline.sh", "refreshInterval": 1}`
in `~/.claude/settings.json` (`"refreshInterval": 5` on Windows, where a
render costs ~150ms of process creation against ~1ms elsewhere). It skips the registration when
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
- `dep claude` or `dep curl` is `missing` and the user declined: finish
  the install, then one line per gap taken from its `<cost if absent>`
  column. No warning tone, a decline is a complete answer, and the rest of
  the statusline works.
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
- The doctor itself cannot run (missing, or non-zero with no records): say
  which path you tried, then run the sync anyway and report its result. The
  doctor is a report, not a gate: only a missing `jq` or `bash` stops the
  install, and a non-zero exit on its own never does.

Never hand-edit `settings.json` or `config.json`.
