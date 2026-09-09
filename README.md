# statusline-in-nutshell

A customized statusline for Claude Code, in place of the default footer, and
it comes in two layouts so you can pick how much of it you want to look at.

A new install starts on `simple`, which fits everything worth glancing at
into a single line from the model you are on and how hard it is thinking, the
advisor when you have one, how much context is left, how much of each rate
window you have spent and how long until it resets, and finally the repo and
branch you are working in.

```
Sonnet 5 (high) | adv Opus 5 | ctx 412.0k/1.0m | 5h 42% (2h36m) | 7d 18% (5d18h) | statusline-in-nutshell@main
```

Turn on emoji labels and the words give way to icons, which buys back a
little more room on the same line:

```
💡 Sonnet 5 (high) | 🎓 Opus 5 | ⏳ 412.0k/1.0m | 🕐 42% (2h36m) | 🔄 18% (5d18h) | 📂 statusline-in-nutshell 🌿 main
```

When you would rather see the whole picture, `detail` spreads the same
information across four lines and adds what simple leaves behind. Line 1
carries the model, effort level, advisor and context usage, this time with a
progress bar. Line 2 opens the spend out into today, this week, this month
and all time. Line 3 shows the rate limits with the clock time each window
resets at, and line 4 says where you are: the directory, the repository and
the git branch.

```
model: Sonnet 5 (high) | advisor: Opus 5 | context: 412.0k/1.0m tokens [████░░░░░░] 41% used
current session: 1.24$ | today: 3.87$ | week: 12.50$ | month: 41.02$ | all-time: 210.33$
5 hours session: 42% used (resets 6:20pm) | weekly session: 18% used (resets Jul 27, 9:00pm)
workspace: ~/Documents/statusline-in-nutshell | repo: Eakkapoom-Name/statusline-in-nutshell | branch: main
```

Emoji labels work the same way here:

```
💡 Sonnet 5 (high) | 🎓 Opus 5 | ⏳ 412.0k/1.0m tokens [████░░░░░░] 41% used
🪙 1.24$ | ⛅ 3.87$ | 📅 12.50$ | 🧾 41.02$ | 💳 210.33$
🕐 42% used (resets 6:20pm) | 🔄 18% used (resets Jul 27, 9:00pm)
📂 ~/Documents/statusline-in-nutshell | 🌐 Eakkapoom-Name/statusline-in-nutshell | 🌿 main
```

## What You Get

- [`/nutshell:nutshell-show`](#nutshellnutshell-show) turns the cost, session
  or workspace line on, one at a time or all three at once. Cost starts off
  on a new install, so this is how you ask for it.
- [`/nutshell:nutshell-hide`](#nutshellnutshell-hide) turns them off again,
  in either layout. The model part stays whatever you do, so the row never
  goes blank.
- [`/nutshell:nutshell-emoji`](#nutshellnutshell-emoji) switches between text
  labels and icons.
- [`/nutshell:nutshell-mode`](#nutshellnutshell-mode) moves between the
  one-line simple layout a new install starts on and the four-line detail
  one.
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

## Notice

- macOS runs on its stock tools. The scripts target bash 3.2 and the BSD
  userland, verified on macOS 26, and nothing has to come from Homebrew: the
  two tools stock macOS does not ship, `flock` and `timeout`, are carried by
  the plugin itself as of 0.3.4, so Linux, macOS and Windows all get the same
  locking and the same hang guard.
- Empty today, week, month or all-time fields mean `ccusage` is missing or too
  old, on any OS. Run [`/nutshell:nutshell-setup`](#nutshellnutshell-setup):
  its dependency check names the gap and the command that closes it.
- WSL is still under development. Some functions may be incompatible.

## Requirement

[`/nutshell:nutshell-setup`](#nutshellnutshell-setup) checks every item below
and prints the install command for your OS, so you do not have to work out
which one is missing.

- **`jq`** 1.6 or newer\
  Everything here reads and writes its JSON through it.
  The toggle script stops with a clear error if it is missing.
- **`ccusage`**\
  Fills in today, week, month and all-time cost, and makes
  `nutshell-reset-all-time-cost` available. Without it, only the current
  session's cost shows.
  - A release too old to report the `period` field leaves those windows just
    as empty. The setup check can run a real one-day query to confirm yours
    works.
- **`claude` on your `PATH`**\
  Runs the background probe that decides whether your account has rate limits
  at all. Without it, the rate windows can show a 0% row they should have
  left out.
  Claude Code itself installs this, so a gap here is a `PATH` problem rather
  than a missing program.

`flock` and `timeout` were listed here through 0.3.3 and you no longer need
either. The plugin serialises its own background refreshes with a lock file
it manages itself, and cuts a hung probe or a hung reset short with its own
watcher. Where GNU `timeout` happens to be installed it is still used, since
it needs no extra processes, and it is recognised by asking it for its
version rather than by its name alone: the bash that Git for Windows ships
carries Windows' own unrelated `timeout.exe` on its `PATH`.

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
and registers the statusline for you. There is nothing else to do; the status
line simply appears.

Confirm it with:

```bash
/nutshell:nutshell-status
```

You should see the statusline reported as active, the mode as `simple` on a
fresh install, model, session and workspace on, and cost off, which is where
a new install leaves it until you ask for it.

## Usage

Type the command for what you want, or just describe it in plain language:
"hide the cost line", "show everything", "turn on emoji", "what's showing?".
Each command has its own description, so a plain request lands on the right
one.

### /nutshell:nutshell-show

Turns a part back on, which means its line in `detail` and its segment in
`simple`. It takes `all`, `cost`, `session` or `workspace`, and with no
argument at all it turns all three on. It does not take `emoji`, which is
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
> back, including the keyboard hints it suppresses while a custom statusline
> is registered, use [`/nutshell:nutshell-inactive`](#nutshellnutshell-inactive).

### /nutshell:nutshell-emoji

Switches between text labels and icons. It applies to both layouts, does not
care which parts you have showing, starts off, and is the only command that
changes it.

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

### /nutshell:nutshell-mode

Moves between the two layouts. It takes `simple` or `detail`, and with no
argument at all it toggles to whichever one you are not on. A new install
starts on `simple`, while an install older than 0.3.4 stays on `detail`, so
an upgrade never changes the row under you.

Simple drops the context bar, the clock time each window resets at, and the
today, week, month and all-time spend, which is what lets the rest fit on one
line. Parts behave the same either way: hide the cost and it leaves its line
in detail and its segment in simple, and emoji labels apply to both.

Switch between them:

```bash
/nutshell:nutshell-mode
```

Switch to the one-line layout:

```bash
/nutshell:nutshell-mode simple
```

Switch back to the four-line layout:

```bash
/nutshell:nutshell-mode detail
```

### /nutshell:nutshell-inactive

Removes the `statusLine` registration from `settings.json`, so Claude Code
shows its own footer again. The choice is remembered, so the sync hook will not
put the statusline back at the next session start.

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

Take over a statusline registered by something else:

```bash
/nutshell:nutshell-active --force
```

> [!NOTE]
> Neither `active` nor `inactive` touches a statusline this plugin did not
> install. If `settings.json` registers something else, for example one written
> by Claude Code's own `/statusline`, `inactive` refuses to delete it and
> `active` refuses to overwrite it. `--force` takes over deliberately.

### /nutshell:nutshell-status

Prints where everything stands: whether the statusline is active, which
layout it is on, and the state of model (always on), cost, session,
workspace and emoji.

```bash
/nutshell:nutshell-status
```

### /nutshell:nutshell-reset-all-time-cost

Wipes the all-time cost counter for good. Today, week and month are untouched.
It asks for confirmation first because there is no undo.

```bash
/nutshell:nutshell-reset-all-time-cost
```

### /nutshell:nutshell-setup

Installs or repairs the scripts and the `statusLine` registration, and checks
the dependencies first.

The dependency check is a read-only report: what the plugin needs, what your
machine has, and the exact command that closes each gap on your OS. It needs
no `jq` itself, so it works on the machine it is diagnosing. Every install
command is shown and confirmed before it runs, `sudo` included, and Homebrew
is never installed on your behalf. Declining is a complete answer: the
install continues and the report says which line stays empty.

Then it runs the same sync script as the `SessionStart` hook, which re-copies
any file that differs from the bundled one and restores the registration.

The registration step is skipped, and reported rather than forced, in three
cases: the statusline is inactive, `settings.json` registers someone else's
statusline, or `settings.json` is not a JSON object.

```bash
/nutshell:nutshell-setup
```

> [!NOTE]
> The hook already syncs the scripts at every session start, but it never
> checks or installs dependencies. Run this when the statusline is missing,
> or when a line stays empty and you want to know why.

### /nutshell:nutshell-uninstall

Removes the statusline and the installed scripts. It confirms first. See
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

## License

MIT. See [LICENSE](LICENSE).
