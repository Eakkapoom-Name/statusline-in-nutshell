# statusline-in-nutshell

A three-line status line for Claude Code: model/effort/context on line 1,
cost windows on line 2, rate-limit usage on line 3. Toggle each line on or
off with a slash command, no manual JSON editing.

```
model: Sonnet 5 (medium) | advisor: Fable 5 | context: 412.0k/1.0m tokens [████░░░░░░] 41% used
session: 1.24$ | today: 3.87$ | week: 12.50$ | month: 41.02$ | all-time: 210.33$
5 hours session: 42% used (resets 6:19am) | weekly session: 18% used (resets Jul 27, 6:00pm)
```

Emoji mode swaps the text labels for icons:

```
💡 Sonnet 5 (medium) | 🎓 Fable 5 | ⏳ 412.0k/1.0m tokens [████░░░░░░] 41% used
🪙 1.24$ | ⛅ 3.87$ | 📅 12.50$ | 🗓️ 41.02$ | 💳 210.33$
🕐 42% used (resets 6:19am) | ♻️ 18% used (resets Jul 27, 6:00pm)
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
/nutshell-statusline:nutshell cost
/nutshell-statusline:nutshell emoji
/nutshell-statusline:nutshell emoji on
/nutshell-statusline:nutshell emoji off
/nutshell-statusline:nutshell status
/nutshell-statusline:nutshell reset-all-time-cost
```

Or just say it: "hide the cost line", "show everything", "turn on emoji",
"what's showing?".

- `show` / `hide` turns all three lines on or off. Hiding everything
  leaves the status line blank, so the skill asks you to confirm first.
- `hide cost` / `show model` / etc. toggles one line without touching the
  others. Name a line with no on/off word and it flips whatever state
  it's currently in.
- `emoji` (or `emoji on` / `emoji off`) swaps text labels for icons. It's
  independent of which lines are shown, and defaults to off.
- `status` prints the current on/off state for model, cost, rate, emoji.
- `reset-all-time-cost` wipes the all-time cost counter for good (today,
  week, month are untouched). Needs `ccusage`, asks for confirmation
  first since there's no undo.

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
  `statusLine` key. `settings.json` is backed up before any change; if it
  was already broken JSON, the original bytes still land in the backup
  before it gets repaired.
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

1. Run `/plugin`, remove the `nutshell-statusline` plugin (and the
   marketplace too, if you want) from the menu.
2. Back up your settings, then remove the installed scripts and the
   `statusLine` key:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
rm ~/.claude/statusline.sh ~/.claude/statusline-toggle.sh ~/.claude/cost_cache_refresh.sh
jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

This leaves `statusline.config.json` and the cost/lock files in place.
Delete those by hand too if you want a clean slate.

## License

MIT. See [LICENSE](LICENSE).
