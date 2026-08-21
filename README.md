# statusline-in-nutshell

A four-line status line for Claude Code: model/effort/context on line 1,
cost windows on line 2, rate-limit usage on line 3, and where you are
(directory, repo, branch) on line 4. Toggle each line on or off with a
slash command, no manual JSON editing.

```
model: Sonnet 5 (medium) | advisor: Fable 5 | context: 412.0k/1.0m tokens [████░░░░░░] 41% used
session: 1.24$ | today: 3.87$ | week: 12.50$ | month: 41.02$ | all-time: 210.33$
5 hours session: 42% used (resets 6:19am) | weekly session: 18% used (resets Jul 27, 6:00pm)
workspace: ~/Documents/statusline-in-nutshell | repo: Eakkapoom-Name/statusline-in-nutshell | branch: master
```

Emoji mode swaps the text labels for icons:

```
💡 Sonnet 5 (medium) | 🎓 Fable 5 | ⏳ 412.0k/1.0m tokens [████░░░░░░] 41% used
🪙 1.24$ | ⛅ 3.87$ | 📅 12.50$ | 🧾 41.02$ | 💳 210.33$
🕐 42% used (resets 6:19am) | 🔄 18% used (resets Jul 27, 6:00pm)
📂 ~/Documents/statusline-in-nutshell | 🌐 Eakkapoom-Name/statusline-in-nutshell | 🌿 master
```

## Platform support

Ubuntu only for now. macOS and WSL support is paused, not dropped for
good, just no way to test them at the moment. Will pick it back up once
that's sorted.

## Install

**Marketplace (recommended):** updates itself when the plugin version
bumps, and a `SessionStart` hook keeps your installed scripts in sync
automatically.

```bash
/plugin marketplace add Eakkapoom-Name/statusline-in-nutshell
/plugin install nutshell-statusline@statusline-in-nutshell
```

Restart your session. The hook copies the scripts into `~/.claude/` and
registers the status line in the background, nothing to watch for beyond
the status line showing up.

**npx (no marketplace):** installs the skill directly, flat command
`/nutshell` instead of `/nutshell-statusline:nutshell`.

```bash
npx skills add Eakkapoom-Name/statusline-in-nutshell --agent claude-code
```

There's no background hook on this path, so syncing only happens when you
invoke the skill. First run installs everything; after that, an update to
this repo won't reach your machine until you run `/nutshell` again, that's
what triggers the sync check. Want updates to land automatically? Use the
marketplace install instead.

## Usage

Talk to the skill in plain language after the slash command:

```
/nutshell-statusline:nutshell show
/nutshell-statusline:nutshell hide
/nutshell-statusline:nutshell show model
/nutshell-statusline:nutshell hide cost
/nutshell-statusline:nutshell hide rate
/nutshell-statusline:nutshell hide workspace
/nutshell-statusline:nutshell off
/nutshell-statusline:nutshell on
/nutshell-statusline:nutshell cost
/nutshell-statusline:nutshell emoji
/nutshell-statusline:nutshell emoji on
/nutshell-statusline:nutshell emoji off
/nutshell-statusline:nutshell status
/nutshell-statusline:nutshell reset-all-time-cost
/nutshell-statusline:nutshell uninstall
```

Or just say it: "hide the cost line", "show everything", "turn on emoji",
"what's showing?".

- `show` / `hide` turns all four lines on or off. Hiding everything
  leaves the status line blank, so the skill asks you to confirm first.
- `hide cost` / `show model` / etc. toggles one line without touching the
  others. Name a line with no on/off word and it flips whatever state
  it's currently in.
- `emoji` (or `emoji on` / `emoji off`) swaps text labels for icons. It's
  independent of which lines are shown, and defaults to off.
- `off` hands the row back to Claude Code and `on` takes it back. See
  "Turning it off" below; this is not the same as `hide`.
- `status` prints the current on/off state for the status line itself and
  for model, cost, rate, workspace, emoji.
- `reset-all-time-cost` wipes the all-time cost counter for good (today,
  week, month are untouched). Needs `ccusage`, asks for confirmation
  first since there's no undo.
- `uninstall` removes the status line and the installed scripts, see the
  Uninstall section below.

(npx install: drop the `nutshell-statusline:` prefix, e.g. `/nutshell hide cost`.)

## Requirements

- `bash`
- `jq`, required. Everything here reads or writes its JSON through it. The
  toggle script fails with a clear error if it's missing.
- `ccusage`, optional. Session cost still shows without it (that figure
  comes straight from Claude Code's own status line payload). With it, a
  background job also fills in today/week/month/all-time cost and unlocks
  `reset-all-time-cost`.

## What gets written where

- The three scripts (`statusline.sh`, `statusline-toggle.sh`,
  `cost_cache_refresh.sh`) get copied to `~/.claude/`. If one's already
  there and differs from the bundled version, it's backed up to
  `<name>.bak` first.
- The status line gets registered under `~/.claude/settings.json`'s
  `statusLine` key, with `refreshInterval: 1`. `settings.json` is backed up
  before any change; if it was already broken JSON, the original bytes still
  land in the backup before it gets repaired.
- That 1-second interval is deliberate. Claude Code re-runs a status line on
  assistant messages and a few UI events, but not when you switch advisor
  model or when the cost cache goes stale, so the advisor, cost, and rate
  segments would sit on old values while the session is idle. The timer
  re-runs the script on a clock instead, at the cost of one `bash` + `jq`
  pass per second. Note that deleting `refreshInterval` by hand doesn't
  stick on the plugin path: the sync hook restores the whole `statusLine`
  block at the next session start. To opt out for good, remove the plugin
  and install via `npx` instead, or edit the value in `hooks/sync.sh`.
- Your own state, `~/.claude/statusline.config.json` and the cost files
  (`.cost_cache.json`, `.cost_ledger.json`, `.cost_baseline.json`), is
  never touched by the sync step. Only the toggle script writes the
  config; only the cost refresher writes the cost files.
- Two lock files keep concurrent runs from stepping on each other:
  `.statusline-sync.lock` for the sync hook, `.cost_cache.lock` for the
  cost refresher. Neither holds user data. Locking uses `flock` when it's
  available and just skips it otherwise, so a system without `flock`
  still works, just without the race protection.

## Uninstall

Run the skill and ask it to uninstall (`/nutshell uninstall`, or
`/nutshell-statusline:nutshell uninstall` for the marketplace install).
It confirms first, then cleans up.

Marketplace install: remove the plugin from the `/plugin` menu first,
otherwise its `SessionStart` hook reinstalls the scripts on the next
session.

npx install: run the uninstall first, then drop the skill itself with
`npx skills remove nutshell`.

By default this keeps `statusline.config.json` and your cost history.
Ask for a purge (or pass `--purge`) to wipe those too. `settings.json`
is backed up to `settings.json.bak` first.

Manual fallback, if you'd rather not go through the skill:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
rm ~/.claude/statusline.sh ~/.claude/statusline-toggle.sh ~/.claude/cost_cache_refresh.sh
jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

## License

MIT. See [LICENSE](LICENSE).

## Turning it off

`/nutshell off` removes the `statusLine` registration from `settings.json`,
which is what makes Claude Code show its own footer again, including the
keyboard hints it hides while a custom status line is configured. `/nutshell on`
puts it back with your part settings intact. `settings.json` is backed up
before either change, and everything else in it is left alone.

This is different from `hide`. `/nutshell hide` (or `all off`) keeps the
registration and prints a blank row, so you get an empty bar rather than the
default one. Only `off` gives you Claude Code's own.

Neither command touches a status line it did not install. If `settings.json`
registers something else, for example one written by Claude Code's own
`/statusline`, `off` refuses to delete it and `on` refuses to overwrite it;
`on --force` takes over deliberately. The `SessionStart` hook applies the same
rule, so installing this plugin never silently replaces a status line you
already had.

The choice is recorded as `"disabled": true` in `statusline.config.json`, and
the `SessionStart` sync hook checks it before registering. Without that, the
hook would put the status line back at the start of the next session and the
opt-out would last exactly one session.

## The workspace line

Line 4 shows where the session is: the current directory (with `$HOME`
shortened to `~`), the repository, and the git branch.

The directory and repository come straight from the status line payload,
where `workspace.repo` is parsed from the `origin` remote. The branch does
not: the payload has no general branch field (`worktree.branch` exists only
for `--worktree` sessions), so the branch is read directly out of `.git/HEAD`
rather than by shelling out to `git`. That avoids forking a process once a
second and works on a machine with no git installed. A linked worktree, where
`.git` is a file pointing at the real git directory, is followed correctly,
and a detached HEAD shows a short commit SHA instead of a branch name.

Each of the three segments is independent. A directory outside any git repo
shows just the path; a repo with no `origin` remote shows the path and the
branch but no repository name. If none of the three resolve, the line is
omitted rather than printed empty.

Hide it with `/nutshell hide workspace`.
