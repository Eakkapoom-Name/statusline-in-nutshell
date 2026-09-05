# statusline-in-nutshell

A customized status line for Claude Code. It replaces the default footer with
four lines of your own. Line 1 shows the model, effort level, advisor model and
context usage. Line 2 shows your spend across several time windows. Line 3
shows how much of your rate limits you have used. Line 4 shows where you are:
the directory, the repository and the git branch.

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

- **Ubuntu.** macOS and WSL are under development. Treat them as experimental
  for now: some functions may be incompatible. On macOS, for example, the cost
  line only reports the current session, so today, week, month and all-time can
  stay empty.
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
    all runs `claude auth status`. Pro and Max get both the 5-hour and the
    weekly window, a Team seat with only a 5-hour limit gets that one, and
    API-key, Bedrock, Vertex and Foundry billing get no rate row.
  - Without it the verdict never lands, and line 3 falls back on what it can
    see: a metered session still omits the rows once it has had a response, but
    until then it can show a 0% row it should have left out, unless it was
    launched with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
    `ANTHROPIC_API_KEY`, `CLAUDE_CODE_USE_BEDROCK` or `CLAUDE_CODE_USE_VERTEX`.

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
and workspace on.

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

Turn all three on:

```bash
/nutshell:nutshell-show
```

Turn on the cost line only:

```bash
/nutshell:nutshell-show cost
```

Turn on the workspace line only:

```bash
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

Hide the cost line:

```bash
/nutshell:nutshell-hide cost
```

Hide the rate-limit line:

```bash
/nutshell:nutshell-hide session
```

Hide all three:

```bash
/nutshell:nutshell-hide all
```

> [!NOTE]
> Hiding is not the same as switching off. To get Claude Code's own footer
> back, including the keyboard hints it suppresses while a custom status line
> is registered, use [`/nutshell:nutshell-inactive`](#nutshellnutshell-inactive).

### /nutshell:nutshell-emoji

Switches between text labels and icons. Independent of which lines are shown,
off by default, and the only command that changes it.

Toggle it:

```bash
/nutshell:nutshell-emoji
```

Switch to icons:

```bash
/nutshell:nutshell-emoji on
```

Switch back to text labels:

```bash
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

Hand the row back:

```bash
/nutshell:nutshell-inactive
```

### /nutshell:nutshell-active

Takes the row back, with your line settings intact.

Take it back:

```bash
/nutshell:nutshell-active
```

Take over a status line registered by something else:

```bash
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

```bash
/nutshell:nutshell-status
```

### /nutshell:nutshell-reset-all-time-cost

Wipes the all-time cost counter for good. Today, week and month are untouched.
Needs `ccusage`, and asks for confirmation first because there is no undo.

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

```bash
/nutshell:nutshell-setup
```

> [!NOTE]
> The hook already does this at every session start. This is the mid-session
> repair, not something you normally run.

### /nutshell:nutshell-uninstall

Removes the status line and the installed scripts. It confirms first. See
[Uninstall](#uninstall) for what is kept and what a purge takes.

```bash
/nutshell:nutshell-uninstall
```

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
├── hooks/
│   ├── cost-refresh.sh
│   ├── hooks.json
│   └── sync.sh
└── skills/
    ├── nutshell-active/
    │   └── SKILL.md
    ├── nutshell-emoji/
    │   └── SKILL.md
    ├── nutshell-hide/
    │   └── SKILL.md
    ├── nutshell-inactive/
    │   └── SKILL.md
    ├── nutshell-reset-all-time-cost/
    │   └── SKILL.md
    ├── nutshell-setup/
    │   ├── scripts/
    │   │   ├── auth_cache_refresh.sh
    │   │   ├── cost_cache_refresh.sh
    │   │   ├── nutshell-lib.sh
    │   │   ├── statusline-toggle.sh
    │   │   └── statusline.sh
    │   └── SKILL.md
    ├── nutshell-show/
    │   └── SKILL.md
    ├── nutshell-status/
    │   └── SKILL.md
    └── nutshell-uninstall/
        └── SKILL.md
```

## License

MIT. See [LICENSE](LICENSE).
