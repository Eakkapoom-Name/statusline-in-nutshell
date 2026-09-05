# statusline-in-nutshell

A four-line status line for Claude Code. Line 1 shows the model, effort level,
advisor model and context usage. Line 2 shows your spend across several time
windows. Line 3 shows how much of your rate limits you have used. Line 4 shows
where you are: the directory, the repository and the git branch.

This plugin is for Claude Code users who want that in the footer without
editing `settings.json` by hand. Lines 2, 3 and 4 are switched on and off with
a slash command, and the whole row is handed back to Claude Code when you want
it gone.

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

## What You Get

- [`/nutshell:nutshell-show`](#nutshellnutshell-show) turns the cost, session
  or workspace line on, one at a time or all three at once.
- [`/nutshell:nutshell-hide`](#nutshellnutshell-hide) turns them off again.
  Line 1 cannot be hidden, so the row never goes blank.
- [`/nutshell:nutshell-emoji`](#nutshellnutshell-emoji) switches between text
  labels and icons.
- [`/nutshell:nutshell-inactive`](#nutshellnutshell-inactive) hands the row
  back to Claude Code and stops the work behind it.
- [`/nutshell:nutshell-active`](#nutshellnutshell-active) takes it back, with
  your line settings intact.
- [`/nutshell:nutshell-status`](#nutshellnutshell-status) prints what is on
  and what is off.
- [`/nutshell:nutshell-reset-all-time-cost`](#nutshellnutshell-reset-all-time-cost)
  wipes the all-time cost counter.
- [`/nutshell:nutshell-setup`](#nutshellnutshell-setup) installs or repairs
  the scripts and the registration.
- [`/nutshell:nutshell-uninstall`](#nutshellnutshell-uninstall) removes both.

## Requirements

- **Ubuntu.** macOS and WSL support is paused rather than dropped: there is
  currently no way to test on them. It will be picked up again once that
  changes.
- **`bash`.**
- **`jq`.** Required. Everything here reads and writes its JSON through it.
  The toggle script stops with a clear error if it is missing.
- **`ccusage`.** Optional.
  - Session cost still shows without it, because that figure comes straight
    from Claude Code's own status line payload.
  - With it, a background job also fills in today, week, month and all-time
    cost, and `nutshell-reset-all-time-cost` becomes available.
- **`claude` on your `PATH`.** Optional.
  - The background probe that decides whether your account has rate limits at
    all runs `claude auth status`.
  - Without it the verdict never lands, and line 3 falls back on what it can
    see: a metered session still omits the rows once it has had a response, but
    until then it can show a 0% row it should have left out, unless it was
    launched with one of the environment variables listed in
    [Why does my API-key tab show a rate row?](#why-does-my-api-key-tab-show-a-rate-row)

## Install

The marketplace is the only supported install. It updates itself whenever the
plugin version is bumped, and a `SessionStart` hook keeps the installed scripts
in sync for you.

Add the marketplace:

```bash
/plugin marketplace add Eakkapoom-Name/statusline-in-nutshell
```

Then install the plugin:

```bash
/plugin install nutshell@statusline-in-nutshell
```

Restart your session. The hook copies the scripts into `~/.claude/nutshell/bin/`
and registers the status line for you. There is nothing else to do; the status
line simply appears.

Confirm it with:

```bash
/nutshell:nutshell-status
```

You should see the status line reported as active, model on, and cost, session
and workspace on. Coming from an older install, read [Upgrading](#upgrading)
first.

## Usage

Type the command for what you want, or just describe it in plain language:
"hide the cost line", "show everything", "turn on emoji", "what's showing?".
Each command has its own description, so a plain request lands on the right
one.

### /nutshell:nutshell-show

Turns a line on. Takes `all`, `cost`, `session` or `workspace`, and with no
argument it turns all three on. It does not take `emoji`, which is
[its own command](#nutshellnutshell-emoji), and it does not take `model`,
which is always on.

Examples:

```bash
/nutshell:nutshell-show
/nutshell:nutshell-show cost
/nutshell:nutshell-show workspace
```

### /nutshell:nutshell-hide

Turns a line off, with the same arguments. The registration stays in place, so
the row is still yours and line 1 keeps rendering.

`session` is the rate-limit line, named for the 5-hour and weekly session
limits it tracks. `workspace` is the location line: the current directory with
your home folder shortened to `~`, the repository parsed from the `origin`
remote, and the branch read straight from `.git/HEAD`. Each part is
independent, so a folder outside any repository still shows its path, and if
none of the three resolve the line is left out rather than printed empty.

Examples:

```bash
/nutshell:nutshell-hide cost
/nutshell:nutshell-hide session
/nutshell:nutshell-hide all
```

> [!NOTE]
> Hiding is not the same as switching off. To get Claude Code's own footer
> back, including the keyboard hints it suppresses while a custom status line
> is registered, use [`/nutshell:nutshell-inactive`](#nutshellnutshell-inactive).

### /nutshell:nutshell-emoji

Switches between text labels and icons. Independent of which lines are shown,
off by default, and the only command that changes it.

Examples:

```bash
/nutshell:nutshell-emoji
/nutshell:nutshell-emoji on
/nutshell:nutshell-emoji off
```

### /nutshell:nutshell-inactive

Removes the `statusLine` registration from `settings.json`, so Claude Code
shows its own footer again. The choice is remembered, so the sync hook will not
put the status line back at the next session start.

It also stops the work behind the row: `statusline.sh` exits immediately while
inactive, printing nothing and spawning neither the background cost refresh nor
the auth probe. That covers a session that was already running when you turned
it off, in case Claude Code keeps invoking the old command until the session
restarts.

While inactive, `show`, `hide`, `emoji` and `reset-all-time-cost` refuse to
run, since nothing they change would be visible. `status`, `active` and
`uninstall` still work.

Examples:

```bash
/nutshell:nutshell-inactive
/nutshell:nutshell-status
```

### /nutshell:nutshell-active

Takes the row back, with your line settings intact.

Examples:

```bash
/nutshell:nutshell-active
/nutshell:nutshell-active --force
```

> [!NOTE]
> Neither `active` nor `inactive` touches a status line this plugin did not
> install. If `settings.json` registers something else, for example one written
> by Claude Code's own `/statusline`, `inactive` refuses to delete it and
> `active` refuses to overwrite it. `--force` takes over deliberately.

### /nutshell:nutshell-status

Prints the current on/off state of the status line itself and of model (always
on), cost, session, workspace and emoji.

Examples:

```bash
/nutshell:nutshell-status
```

### /nutshell:nutshell-reset-all-time-cost

Wipes the all-time cost counter for good. Today, week and month are untouched.
Needs `ccusage`, and asks for confirmation first because there is no undo.

Examples:

```bash
/nutshell:nutshell-reset-all-time-cost
```

### /nutshell:nutshell-setup

Installs or repairs the scripts and the `statusLine` registration. It runs the
same sync script as the `SessionStart` hook, which re-copies any file that
differs from the bundled one and restores the registration.

The registration step is skipped, and reported rather than forced, in three
cases: the status line is inactive, `settings.json` registers someone else's
status line, or `settings.json` is not a JSON object.

Examples:

```bash
/nutshell:nutshell-setup
```

> [!NOTE]
> The hook already does this at every session start. This is the mid-session
> repair, not something you normally run.

### /nutshell:nutshell-uninstall

Removes the status line and the installed scripts. It confirms first. See
[Uninstall](#uninstall) for what is kept and what a purge takes.

Examples:

```bash
/nutshell:nutshell-uninstall
```

## Typical Flows

### Quieting The Row For A Demo

Hand the row back, then take it back afterwards. Your line settings survive
the round trip.

```bash
/nutshell:nutshell-inactive
/nutshell:nutshell-active
```

### Repairing A Broken Status Line

A blank or stale row usually means the scripts are missing or the registration
was overwritten. Check what the plugin thinks is true, then run the repair.

```bash
/nutshell:nutshell-status
/nutshell:nutshell-setup
```

If `setup` reports that it skipped the registration, the reason is one of the
three in [its section](#nutshellnutshell-setup).

### Watching Cost Without The Rest

Line 1 is fixed, but the other three are yours.

```bash
/nutshell:nutshell-hide all
/nutshell:nutshell-show cost
```

## How It Stays Fresh

- The registration carries `refreshInterval: 1`, so the row re-renders once a
  second. Claude Code otherwise only re-runs a status line on assistant
  messages and a few UI events. See
  [Why every second?](#why-does-it-refresh-every-second)
- Cost is refreshed on a `Stop` hook, when Claude finishes responding, so the
  windows land within a few seconds of a turn.
- A ledger under `state/` records the highest figure ever seen for each day, so
  your history cannot shrink when Claude Code prunes old transcripts.
- Rate-limit readings are shared between your subscription sessions through
  `state/rate_cache.json`, so an idle tab does not freeze on an old number.
- A background `claude auth status` probe, cached per session and refreshed
  every 5 minutes, decides whether the rate row is shown at all.

## What Gets Written Where

Everything this plugin owns lives under one directory, so `~/.claude/` gains a
single `nutshell/` entry:

```
~/.claude/nutshell/
  bin/     nutshell-lib.sh  statusline.sh  statusline-toggle.sh
           cost_cache_refresh.sh  auth_cache_refresh.sh
  config.json
  state/   cost_cache.json  cost_ledger.json  cost_baseline.json
           rate_cache.json  auth_cache.json  ledger_<source>.json
  locks/   sync.lock  cost_cache.lock  auth_cache.lock
```

- `bin/` holds the five copied files: a shared library the other four source,
  the status line itself, the toggle script behind every command, and the two
  background refreshers. A file already there that differs from the bundled
  version is overwritten. Nothing writes a `.bak`, so a local edit is lost at
  the next sync; keep your copy elsewhere.
- `config.json` is written only by the toggle script, and never by the sync
  step.
- `state/` is written only by the job that owns each file: the cost refresher
  for the cost files, the status line for the rate cache, the auth probe for
  the auth cache. The sync step never touches any of it.
- `locks/` holds three lock files and no user data. Locking uses `flock` where
  it is available and is skipped otherwise, so a system without `flock` still
  works, just without the race protection.
- In `~/.claude/settings.json`, only the `statusLine` key is touched, through a
  temp file and a rename. A `settings.json` that does not exist yet is created
  as `{}` first. One that exists but is not a JSON object is left exactly as it
  is, and registration is skipped until you fix it.

## Upgrading

- **From before 0.3.0**, the plugin was called `nutshell-statusline`. Version
  0.3.0 renamed it to `nutshell`, so the commands read `/nutshell:nutshell-hide`
  rather than `/nutshell-statusline:...`. Remove the old one from the `/plugin`
  menu first, then install `nutshell@statusline-in-nutshell`. Your installed
  scripts, toggle settings and cost history are untouched by the swap.
- **From before 0.3.1**, everything sat loose in `~/.claude/` as thirteen
  files. The move into `~/.claude/nutshell/` happens by itself at your next
  session start: settings and cost history are moved rather than recreated, the
  scripts are installed fresh and the old copies deleted once the new ones are
  in place, and the registration is repointed. Nothing is asked of you, with one
  exception: an extra cost ledger written by another tool of yours moves from
  `~/.claude/.cost_ledger_<source>.json` to
  `~/.claude/nutshell/state/ledger_<source>.json`, and only the new path is read
  from then on, so repoint the tool or its spend stops counting. The same
  version also split the installed scripts into five files instead of three,
  adding a shared `nutshell-lib.sh` and a separate `auth_cache_refresh.sh`.
  Nothing changes in what the status line shows.
- **From an `npx skills add` install.** That path was supported through 0.3.0
  and is discontinued. Run `/nutshell-uninstall`, then install from the
  marketplace. Your toggle settings and cost history are kept.

```bash
npx skills remove nutshell-setup nutshell-status nutshell-show nutshell-hide nutshell-emoji nutshell-active nutshell-inactive nutshell-reset-all-time-cost nutshell-uninstall
```

## FAQ

### Why can line 1 not be hidden?

Because hiding every part would leave an empty row. The `statusLine`
registration stays in place while parts are merely hidden, and Claude Code keeps
its own footer hints suppressed while it is registered, so you would see
neither. Pinning line 1 on is what guarantees something renders.
[`/nutshell:nutshell-inactive`](#nutshellnutshell-inactive) is the way to get
the footer back.

### Why does it refresh every second?

Re-running the script does not recompute Claude Code's payload, but the advisor
name and the cost windows are read from disk, so a timer is the only way to
notice a change to either. Without it they would sit on old values through an
idle session. The sync hook restores `refreshInterval: 1` at every session
start, so opting out for good means editing `NUT_STATUSLINE_VALUE` in
`skills/nutshell-setup/scripts/nutshell-lib.sh`, the one place the registration
is written down.

### Why did my all-time cost not drop when old logs were pruned?

Claude Code prunes old transcript logs on a rolling window, and `ccusage` only
sees logs that still exist, so a day's spend would vanish from month and
all-time once its log went. `state/cost_ledger.json` records the highest figure
ever seen for each day, and the windows are summed from it, so a day can only
ever go up. It protects history from its first run forward, not before. The
week runs Sunday to Saturday, the month from the 1st, and today rolls over at
midnight, all on your local clock.

### When exactly does the cost refresh run?

On the `Stop` hook, which fires when Claude finishes responding, since that is
when the number can actually have moved. The hook starts the same background job
the status line starts and returns at once, so it never adds latency to a turn.
It skips entirely while the status line is inactive, while the cost line is
hidden, within 10 seconds of the last refresh, or when `jq`, `ccusage` or the
refresher itself is missing.

The refresh rescans only from the last day already recorded in the ledger
onward, since earlier days can no longer change. On a 447 MB transcript
directory that roughly halves the work. A missing or unreadable ledger falls
back to a full scan, and so does a reset.

### Can another tool feed the cost windows?

Yes. Any `~/.claude/nutshell/state/ledger_<source>.json` holding
`{"YYYY-MM-DD": cost}` is added, day by day, to what `ccusage` reports before
today, week, month and all-time are summed, and `reset-all-time-cost` resets
that spend too. The refresher only reads these files: one that is not a JSON
object is skipped, and inside one only date keys with numeric values count.
Meant for spend `ccusage` cannot see, for example a local OpenRouter proxy
recording the credits it was actually charged.

### Why is an idle tab's rate row still current?

Claude Code only refreshes a session's rate-limit numbers when that session gets
an API response, so an idle tab would otherwise show a reading from hours ago.
Each session publishes the freshest numbers it has seen to
`state/rate_cache.json` and displays the freshest any session has published. A
reading whose reset time has passed is discarded rather than shown: that window
falls back to 0% with no reset time, which is also the moment Claude Code drops
it from its own payload.

That cache is keyed by nothing, so two different subscription accounts on one
machine blend their readings.

### Why does my API-key tab show a rate row?

It should not, and normally does not. Pro and Max show both the 5-hour and the
weekly window, a Team seat with only a 5-hour limit shows just that one, and
API-key, Bedrock, Vertex and Foundry billing get no rate row at all. The
background `claude auth status` probe, cached in `state/auth_cache.json` and
refreshed every 5 minutes, tells the two apart, and the windows your plan has
are learned from the ones actually seen. A real reading always wins.

The verdict is answered per session, not per machine, because auth is whatever
a session was launched with. Run a Max session and an API-key or gateway session
side by side and each gets its own verdict, keyed by session id. The metered one
is also kept out of the shared rate cache entirely, reading and writing: its own
payload still renders, but it can neither show your subscription's percentages
nor overwrite them.

Until its first probe lands, roughly a render or two, a session that exports
`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`,
`CLAUDE_CODE_USE_BEDROCK` or `CLAUDE_CODE_USE_VERTEX` is treated as metered on
that evidence alone. `CLAUDE_CODE_USE_FOUNDRY` is not in that list, so a
Microsoft Foundry session waits for the probe like any other and can show a 0%
row until it lands.

### I ran /login mid-session. Does the row notice?

Yes. The verdict is re-taken when `~/.claude/.credentials.json` changes, which
every login, logout and token refresh does, and the instant a session marked
metered receives rate limits anyway. On a macOS install keeping credentials in
the Keychain there is no file to watch, so the 5 minute refresh is what notices.

### Why is the advisor name sometimes not what I picked?

It is translated from the bare alias in `settings.json` through a small built-in
table, since nothing exposes the resolved name at runtime. It covers `opus`,
`sonnet`, `fable` and `haiku` and will drift as those aliases point at new
releases. An alias it does not know is printed as written.

## Uninstall

Run [`/nutshell:nutshell-uninstall`](#nutshellnutshell-uninstall). It confirms
first, then cleans up. Do this before removing the plugin, since removing it
takes the command with it. Afterwards, remove the `nutshell` plugin from the
`/plugin` menu: otherwise its `SessionStart` hook reinstalls the scripts at the
next session.

By default the uninstall keeps `config.json`, your cost history, the rate-limit
cache and the auth cache. It still removes the three lock files, any loose
scripts left by a pre-0.3.1 install, and the `disabled` flag in the config it
keeps, so a later reinstall does not come back inactive.

Ask for a purge, or pass `--purge`, to wipe those too: the whole
`~/.claude/nutshell/` directory goes, including any `ledger_<source>.json`
written by another tool, along with the four `.bak` files that versions before
0.3.1 left in `~/.claude/`. Only the `statusLine` key is removed from
`settings.json`; the rest of the file is left alone. The directories are removed
with `rmdir`, never a recursive delete, so anything unexpected inside survives.

A non-purge uninstall keeps those `.bak` files on purpose: `settings.json.bak`
may be your only copy of the settings you had before installing. Nothing writes
a new one, so once they are gone they stay gone.

If you would rather not go through the skill, this is the rough equivalent of a
purge. Remove the plugin from `/plugin` afterwards, or the hook puts everything
back at the next session start. It does not sweep the files a pre-0.3.1 install
left loose in `~/.claude/`; the skill does.

```bash
rm -r ~/.claude/nutshell
jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

## Layout

```
.claude-plugin/
  marketplace.json                 marketplace manifest, source is this repo
  plugin.json                      plugin manifest, holds the version
hooks/
  hooks.json                       registers the two hooks below
  sync.sh                          SessionStart: installs scripts, registers the row
  cost-refresh.sh                  Stop: starts the background cost refresh
skills/
  nutshell-setup/
    SKILL.md
    scripts/
      nutshell-lib.sh              paths, the registration value, shared helpers
      statusline.sh                renders the four lines
      statusline-toggle.sh         the only writer of config.json
      cost_cache_refresh.sh        background ccusage refresh
      auth_cache_refresh.sh        background claude auth status probe
  nutshell-show/SKILL.md
  nutshell-hide/SKILL.md
  nutshell-emoji/SKILL.md
  nutshell-active/SKILL.md
  nutshell-inactive/SKILL.md
  nutshell-status/SKILL.md
  nutshell-reset-all-time-cost/SKILL.md
  nutshell-uninstall/SKILL.md
.gitignore
LICENSE
README.md
```

## License

MIT. See [LICENSE](LICENSE).
