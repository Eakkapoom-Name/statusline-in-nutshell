# statusline-in-nutshell

A three-line Claude Code status line: model, effort, and context on line 1,
cost windows on line 2, and rate-limit usage on line 3. Each line toggles on
or off independently, right from a slash command, no manual JSON editing.

Example output (colors and block-bar rendered in the real terminal):

```
model: Sonnet 5 (medium) | advisor: Fable 5 | context: 82.4k/200.0k tokens [████░░░░░░] 41% used
session: 1.24$ | today: 3.87$ | week: 12.50$ | month: 41.02$ | all-time: 210.33$
5 hours session: 42% used (resets 6:19am) | weekly session: 18% used (resets Jul 27, 6:00pm)
```

With emoji mode on, the text labels become icons:

```
💡 Sonnet 5 (medium) | 🎓 Fable 5 | ⏳ 82.4k/200.0k tokens [████░░░░░░] 41% used
🪙 1.24$ | ⛅ 3.87$ | 📅 12.50$ | 🗓️ 41.02$ | 💳 210.33$
🕐 42% used (resets 6:19am) | ♻️ 18% used (resets Jul 27, 6:00pm)
```

## Install (plugin, recommended)

The plugin path auto-updates on every push to this repo (there is no version
field, updates are commit-SHA based) and sets itself up with zero manual
steps.

```bash
/plugin marketplace add Eakkapoom-Name/statusline-in-nutshell
/plugin install statusline@statusline-in-nutshell
```

Start (or restart) a session. A `SessionStart` hook runs silently in the
background: it copies the three bundled scripts into `~/.claude/` and
registers the status line in `~/.claude/settings.json`. Nothing is printed
and nothing blocks the session, so the first sign it worked is simply that
the status line appears at the bottom of the terminal.

After install, the toggle command is:

```
/statusline:statusline-in-nutshell
```

## Install (npx, no plugin manager)

If you would rather not add a plugin marketplace, install the skill
directly with the `skills` CLI:

```bash
npx skills add Eakkapoom-Name/statusline-in-nutshell
```

This installs a flat (non-namespaced) command, `/statusline-in-nutshell`,
instead of `/statusline:statusline-in-nutshell`. The npx path does not ship
the `SessionStart` hook, so there is no background auto-install: the first
time you run the skill, its own setup step (step 0 in `SKILL.md`) installs
the three scripts to `~/.claude/` and registers the status line for you,
the same way the hook would. Every run after that is a no-op unless the
bundled scripts changed.

## Usage

Talk to the skill in plain language after the slash command; it parses the
request and runs the matching toggle. A few examples:

```
/statusline:statusline-in-nutshell show
/statusline:statusline-in-nutshell hide
/statusline:statusline-in-nutshell show model
/statusline:statusline-in-nutshell hide cost
/statusline:statusline-in-nutshell hide rate
/statusline:statusline-in-nutshell cost
/statusline:statusline-in-nutshell emoji
/statusline:statusline-in-nutshell emoji on
/statusline:statusline-in-nutshell emoji off
/statusline:statusline-in-nutshell status
/statusline:statusline-in-nutshell reset-all-time-cost
```

Plain language works too: "hide the cost line", "show everything",
"turn on emoji", "what's showing?".

- `show` turns all three lines (model, cost, rate) on.
- `hide` turns all three lines off. Since that leaves the status line
  blank, the skill asks for confirmation before doing it.
- `hide cost` (or `show cost`, `hide rate`, `show model`, and so on) turns
  one line off or on without touching the other two. Naming a line alone,
  with no on/off word, toggles it.
- `cost` (or any part name alone, with no on/off word) toggles that line:
  off if it was on, on if it was off.
- `emoji` toggles emoji labels (see the second example output above) on
  top of whichever lines are currently shown; `emoji on` / `emoji off`
  set it explicitly. It is independent of the show/hide state and
  defaults to off.
- `status` prints a table of the current on/off state for model, cost,
  rate, and emoji.
- `reset-all-time-cost` permanently resets the all-time cost counter to
  zero (today, week, and month are unaffected). It requires `ccusage` and
  asks for confirmation first, since it cannot be undone.

(npx install: drop the `statusline:` prefix, for example
`/statusline-in-nutshell hide cost`.)

## Requirements

- `bash`
- `jq`, required. The status line renderer reads JSON with it; the toggle
  script and the cost refresher read and write JSON with it. The toggle
  script exits with a clear "jq is required" error if it is missing.
- `ccusage`, optional. Without it, session cost (line 2's "session:"
  figure, taken directly from the Claude Code status line payload) still
  works. With it, a background refresh job additionally populates
  today/week/month/all-time cost windows and enables
  `reset-all-time-cost`.

Supported platforms: Linux, macOS, and WSL. The scripts are bash (not
plain POSIX shell) and stick to tools available in macOS's stock system
bash and BSD userland, so no GNU coreutils or Homebrew install is needed;
where GNU-only tools like `flock` or `timeout` would otherwise be used,
the scripts degrade gracefully without them. Native Windows (without WSL)
is still not supported. `reset-all-time-cost` and the today/week/month/
all-time cost windows additionally need `ccusage`, same as above.

## What gets written where

- The three scripts (`statusline.sh`, `statusline-toggle.sh`,
  `cost_cache_refresh.sh`) are copied to `~/.claude/`. If a copy already
  exists there and differs from the bundled version, the existing file is
  backed up to `<name>.bak` before being overwritten.
- The status line is registered as `~/.claude/settings.json`'s
  `statusLine` key. `settings.json` is backed up to `settings.json.bak`
  before any change. If `settings.json` already existed but was not valid
  JSON, its original bytes are preserved in `settings.json.bak` before the
  file is repaired, so nothing is lost.
- Your own settings, `~/.claude/statusline.config.json` (which parts and
  emoji mode are on or off) and the cost tracking files,
  `~/.claude/.cost_cache.json`, `~/.claude/.cost_ledger.json`, and
  `~/.claude/.cost_baseline.json` (the `reset-all-time-cost` snapshot), are
  never touched by the sync step. Only the toggle script writes
  `statusline.config.json`, and only `cost_cache_refresh.sh` writes the
  cost cache, ledger, and baseline.
- Two lock files coordinate concurrent runs and hold no user data:
  `~/.claude/.statusline-sync.lock` (sync hook) and
  `~/.claude/.cost_cache.lock` (cost refresher).
- Concurrent sessions starting at the same time are safe: the sync step is
  guarded with `flock` when available, so two `SessionStart` hooks running
  at once cannot race each other or clobber a backup. Stock macOS does not
  ship `flock(1)` (it is only available via Homebrew's util-linux); on
  such a system, the scripts proceed without a lock rather than failing.

## Uninstall

1. Remove the plugin: run `/plugin`, then remove the `statusline` plugin
   (and, if you want, the `statusline-in-nutshell` marketplace) from the
   interactive menu.
2. Back up your settings, then delete the three installed scripts and the
   `statusLine` key:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
rm ~/.claude/statusline.sh ~/.claude/statusline-toggle.sh ~/.claude/cost_cache_refresh.sh
jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

This leaves `statusline.config.json`, `.cost_cache.json`,
`.cost_ledger.json`, `.cost_baseline.json`, `.cost_cache.lock`, and
`.statusline-sync.lock` in place. Delete them by hand if you also want to
clear your saved toggle state, cost history, and lock files.

## License

MIT. See [LICENSE](LICENSE).
