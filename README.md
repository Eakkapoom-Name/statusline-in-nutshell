# statusline-in-nutshell

A four-line status line for Claude Code. Line 1 shows the model, effort
level, advisor model and context usage. Line 2 shows your spend across
several time windows. Line 3 shows how much of your rate limits you have
used. Line 4 shows where you are: the directory, the repository and the git
branch. Each line can be switched on or off with a slash command, so you
never have to edit JSON by hand.

```
model: Sonnet 5 (high) | advisor: Opus 5 | context: 412.0k/1.0m tokens [████░░░░░░] 41% used
current session: 1.24$ | today: 3.87$ | week: 12.50$ | month: 41.02$ | all-time: 210.33$
5 hours session: 42% used (resets 6:19am) | weekly session: 18% used (resets Jul 27, 6:00pm)
workspace: ~/Documents/statusline-in-nutshell | repo: Eakkapoom-Name/statusline-in-nutshell | branch: main
```

Emoji mode replaces the text labels with icons:

```
💡 Sonnet 5 (high) | 🎓 Opus 5 | ⏳ 412.0k/1.0m tokens [████░░░░░░] 41% used
🪙 1.24$ | ⛅ 3.87$ | 📅 12.50$ | 🧾 41.02$ | 💳 210.33$
🕐 42% used (resets 6:19am) | 🔄 18% used (resets Jul 27, 6:00pm)
📂 ~/Documents/statusline-in-nutshell | 🌐 Eakkapoom-Name/statusline-in-nutshell | 🌿 main
```

## Platform support

Ubuntu only for now. macOS and WSL support is paused rather than dropped:
there is currently no way to test on them. It will be picked up again once
that changes.

## Install

**Marketplace (recommended).** This path updates itself whenever the plugin
version is bumped, and a `SessionStart` hook keeps the installed scripts in
sync for you.

Add the marketplace:

```bash
/plugin marketplace add Eakkapoom-Name/statusline-in-nutshell
```

Then install the plugin:

```bash
/plugin install nutshell@statusline-in-nutshell
```

Restart your session. The hook copies the scripts into `~/.claude/` and
registers the status line in the background. There is nothing else to do;
the status line simply appears.

If you installed an earlier version, the plugin was called
`nutshell-statusline`. Version 0.3.0 renamed it to `nutshell` so the
commands read `/nutshell:nutshell-hide` rather than
`/nutshell-statusline:...`. Remove the old one from the `/plugin` menu
first, then install `nutshell@statusline-in-nutshell`. Your installed
scripts, toggle settings and cost history are untouched by the swap.

**npx (no marketplace).** This path installs the skills directly and gives
you flat commands such as `/nutshell-show`, `/nutshell-hide cost` and
`/nutshell-status` instead of `/nutshell:nutshell-show`.

```bash
npx skills add Eakkapoom-Name/statusline-in-nutshell --agent claude-code
```

There is no background hook on this path. The first command you run installs
everything, because every skill checks for the scripts and calls
`/nutshell-setup` when they are missing. After that, an update to this
repository will not reach your machine until you run `/nutshell-setup` again.
If you want updates to land automatically, use the marketplace install
instead.

## Usage

Type the command for what you want, or just describe it in plain language:
"hide the cost line", "show everything", "turn on emoji", "what's showing?".
Each command has its own description, so a plain request lands on the right
one. If you installed with npx, drop the `nutshell:` prefix, for example
`/nutshell-hide cost`.

- `/nutshell:nutshell-show` turns all four lines on. `show all` does the
  same.
- `/nutshell:nutshell-hide` turns all four lines off, as does `hide all`.
  This leaves the status line blank, so the skill asks you to confirm first.
- `/nutshell:nutshell-show model` turns the model line on without touching
  the others. The same works for `cost`, `session` and `workspace`.
- `/nutshell:nutshell-hide cost` turns the cost line off without touching
  the others.
- `/nutshell:nutshell-hide session` turns the rate-limit line off. It is
  called `session` because it tracks your 5-hour and weekly session limits.
- `/nutshell:nutshell-hide workspace` turns the location line off. That line
  shows the current directory (with your home folder shortened to `~`), the
  repository parsed from the `origin` remote, and the branch read straight
  from `.git/HEAD`. Each part is independent, so a folder outside any
  repository still shows its path. If none of the three resolve, the line is
  left out rather than printed empty.
- `/nutshell:nutshell-emoji` toggles emoji mode. It is independent of which
  lines are shown, it is off by default, and this is the only command that
  changes it: `show` and `hide` do not take `emoji`.
- `/nutshell:nutshell-emoji on` switches to icons.
- `/nutshell:nutshell-emoji off` switches back to text labels.
- `/nutshell:nutshell-inactive` hands the row back to Claude Code. It removes
  the `statusLine` registration from `settings.json`, so Claude Code shows
  its own footer again, including the keyboard hints it hides while a custom
  status line is active. This is not the same as hiding every line, which
  keeps the registration and prints a blank row. The choice is remembered,
  so the sync hook will not put the status line back at the next session
  start. While inactive, `show`, `hide`, `emoji` and `reset-all-time-cost`
  refuse to run, since nothing they change would be visible; `status`,
  `active` and `uninstall` still work.
- `/nutshell:nutshell-active` takes the row back, with your line settings
  intact. Neither of these touches a status line this plugin did not
  install: if `settings.json` registers something else, for example one
  written by Claude Code's own `/statusline`, `nutshell-inactive` refuses to
  delete it and `nutshell-active` refuses to overwrite it. Use
  `/nutshell:nutshell-active --force` to take over deliberately.
  `settings.json` is backed up before either change.
- `/nutshell:nutshell-status` prints the current on/off state of the status
  line itself and of model, cost, session, workspace and emoji.
- `/nutshell:nutshell-reset-all-time-cost` wipes the all-time cost counter
  for good. Today, week and month are untouched. This needs `ccusage`, and
  the skill asks for confirmation first because there is no undo.
- `/nutshell:nutshell-setup` installs or repairs the scripts and the
  `statusLine` registration. It is also the fix when something looks wrong:
  it re-copies any script that differs from the bundled one and restores the
  registration. On the marketplace path the hook already does this at every
  session start; on the npx path it is what picks up an update.
- `/nutshell:nutshell-uninstall` removes the status line and the installed
  scripts. See the Uninstall section below.

## Requirements

- `bash`.
- `jq`, required. Everything here reads and writes its JSON through it. The
  toggle script stops with a clear error if it is missing.
- `ccusage`, optional. Session cost still shows without it, because that
  figure comes straight from Claude Code's own status line payload. With it,
  a background job also fills in today, week, month and all-time cost, and
  `nutshell-reset-all-time-cost` becomes available.

## What gets written where

- The three scripts (`statusline.sh`, `statusline-toggle.sh` and
  `cost_cache_refresh.sh`) are copied to `~/.claude/`. If one is already
  there and differs from the bundled version, it is backed up to
  `<name>.bak` first.
- The status line is registered under the `statusLine` key in
  `~/.claude/settings.json`, with `refreshInterval: 1`. `settings.json` is
  backed up before any change. If it was already broken JSON, the original
  bytes still land in the backup before the file is repaired.
- The 1-second refresh interval is deliberate. Claude Code only re-runs a
  status line on assistant messages and a few UI events, so the advisor and
  cost segments would otherwise sit on old values while the session is
  idle. The timer re-runs the script on a clock instead. On the plugin path
  the sync hook restores this value at every session start; to opt out for
  good, install via `npx` instead or edit `hooks/sync.sh`.
- Your own state is never touched by the sync step: the config file
  `statusline.config.json`, the cost files (`.cost_cache.json`,
  `.cost_ledger.json`, `.cost_baseline.json`), the rate-limit cache
  (`.rate_cache.json`) and the auth cache (`.auth_cache.json`). Only the
  toggle script writes the config, only the cost refresher writes the cost
  files, and only the status line itself writes the rate and auth caches.
- Other tools can feed the cost windows. Any `~/.claude/.cost_ledger_<source>.json`
  holding `{"YYYY-MM-DD": cost}` is added, day by day, to what `ccusage`
  reports before today, week, month and all-time are summed, and
  `nutshell-reset-all-time-cost` resets that spend too. The refresher only reads these
  files: one that is not a JSON object is skipped, and inside one only date
  keys with numeric values count. Meant for spend `ccusage` cannot see, for
  example a local OpenRouter proxy recording the credits it was actually
  charged.
- `.rate_cache.json` is shared between your subscription sessions. Claude
  Code only refreshes a session's rate-limit numbers when that session gets
  an API response, so an idle tab would otherwise show a reading from hours
  ago. Each session publishes the freshest numbers it has seen and displays
  the freshest any session has published. A window whose reset time has
  passed is dropped rather than shown.
- The rate row follows your plan. Pro and Max show both the 5-hour and the
  weekly window, a Team seat with only a 5-hour limit shows just that one,
  and API-key, Bedrock, Vertex and Foundry billing get no rate row at all.
  A background `claude auth status` probe, cached in `.auth_cache.json` and
  refreshed every 5 minutes, tells the two apart, and the windows your plan
  has are learned from the ones actually seen. A real reading always wins.
- That probe is answered per session, not per machine, because auth is
  whatever a session was launched with. Run a Max session and an API-key or
  gateway session side by side and each gets its own verdict, keyed by
  session id. The metered one is also kept out of the shared rate cache
  entirely, reading and writing: its own payload still renders, but it can
  neither show your subscription's percentages nor overwrite them. Until its
  first probe lands, roughly a render or two, a session that exports
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` is
  treated as metered on that evidence alone.
- A `/login` mid-session is noticed too: the verdict is re-taken when
  `~/.claude/.credentials.json` changes (every login, logout and token refresh
  rewrites it), and the instant a session marked metered receives rate limits
  anyway. On a macOS install keeping credentials in the Keychain there is no
  file to watch, so the 5 minute refresh is what notices.
- Three lock files keep concurrent runs from stepping on each other:
  `.statusline-sync.lock` for the sync hook, `.cost_cache.lock` for the
  cost refresher and `.auth_cache.json.lock` for the auth probe. None of
  them holds user data. Locking uses `flock` where it is available and is
  skipped otherwise, so a system without `flock` still works, just without
  the race protection.

## Uninstall

Run `/nutshell:nutshell-uninstall`, or `/nutshell-uninstall` on the npx install.
It confirms first, then cleans up.

If you installed from the marketplace, remove the `nutshell` plugin from the
`/plugin` menu first. Otherwise its `SessionStart` hook reinstalls the
scripts at the next session.

If you installed with npx, run the uninstall first, then remove the skills
themselves:

```bash
npx skills remove nutshell-setup nutshell-status nutshell-show nutshell-hide nutshell-emoji nutshell-active nutshell-inactive nutshell-reset-all-time-cost nutshell-uninstall
```

By default the uninstall keeps `statusline.config.json`, your cost history,
the rate-limit cache and the auth cache. Ask for a purge, or pass `--purge`,
to wipe those too. `settings.json` is backed up to `settings.json.bak`
first.

If you would rather not go through the skill, the manual fallback is:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
rm ~/.claude/statusline.sh ~/.claude/statusline-toggle.sh ~/.claude/cost_cache_refresh.sh
jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

## License

MIT. See [LICENSE](LICENSE).
