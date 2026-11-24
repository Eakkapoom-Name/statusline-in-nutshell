# statusline-in-nutshell

A customized statusline for Claude Code, in place of the default footer, in
two layouts.

A new install starts on `simple`, one line with the model and its effort, the
advisor when you have one, context used, how much of each rate window you have
spent and how long until it resets, and the repo and branch.

```
Sonnet 5 (high) | adv: Opus 5 | ctx: 412.0k/1.0m | 5h: 42% (2h36m) | 7d: 18% (5d18h) | fable: 61% (5d18h) | statusline-in-nutshell@main
```

Emoji labels swap the words for icons and buy back a little room:

```
💡 Sonnet 5 (high) | 🎓 Opus 5 | ⏳ 412.0k/1.0m | 🕐 42% (2h36m) | 🔄 18% (5d18h) | ⚡ 61% (5d18h) | 🌐 statusline-in-nutshell@main
```

The `fable` segment is the per-model weekly window, the one Claude Code's own
`/usage` dialog calls "Current week (Fable)". It is experimental, and it
appears only on an account that has such a window: no row, no placeholder,
nothing to switch off. The current session's cost is off on a new install;
switch it on and it joins the row after the rate windows, as `cost: 1.24$`
(or `🪙 1.24$` with icons).

`detail` spreads the same information across three lines and adds what simple
leaves out. Line 1 carries the model, effort, advisor and context usage with a
progress bar. Line 2 shows the rate limits with the clock time each window
resets at, then the session cost. Line 3 shows the directory, the repository
and the git branch.

```
model: Sonnet 5 (high) | advisor: Opus 5 | context: 412.0k/1.0m tokens [████░░░░░░] 41% used
5 hours session: 42% used (6:20pm) | weekly session: 18% used (Jul 27, 9:00pm) | weekly fable: 61% used (Jul 27, 9:00pm) | cost: 1.24$
workspace: ~/Documents/statusline-in-nutshell | repo: Eakkapoom-Name/statusline-in-nutshell | branch: main
```

Emoji labels work the same way here:

```
💡 Sonnet 5 (high) | 🎓 Opus 5 | ⏳ 412.0k/1.0m tokens [████░░░░░░] 41% used
🕐 42% used (6:20pm) | 🔄 18% used (Jul 27, 9:00pm) | ⚡ 61% used (Jul 27, 9:00pm) | 🪙 1.24$
📂 ~/Documents/statusline-in-nutshell | 🌐 Eakkapoom-Name/statusline-in-nutshell | 🌿 main
```

The cost is the figure Claude Code itself hands the statusline for the
current session, so nothing is scanned or estimated to produce it.

The context total is the model's window, unless you set an auto-compact
window for that model with `/autocompact` (or `CLAUDE_CODE_AUTO_COMPACT_WINDOW`).
Then the total, the percent and the bar count against that window instead,
so 250k used of a 600k window reads `250.0k/600.0k tokens` at 42%. Left on
`auto`, the row shows the model's window as before.

Both layouts draw their values in one accent color, orange by default, and
[`/nutshell:nutshell-color`](#nutshellnutshell-color) swaps it for a blue one.

## What You Get

- [`/nutshell:nutshell-setup`](#nutshellnutshell-setup) installs or repairs
  the scripts and the registration.
- [`/nutshell:nutshell-mode`](#nutshellnutshell-mode) moves between the
  one-line simple layout a new install starts on and the three-line detail
  one.
- [`/nutshell:nutshell-color`](#nutshellnutshell-color) switches the accent
  every value is drawn in between the orange theme and a blue one.
- [`/nutshell:nutshell-status`](#nutshellnutshell-status) prints what is on
  and what is off.
- [`/nutshell:nutshell-show`](#nutshellnutshell-show) turns the session, cost
  or workspace part on, one at a time or all three at once. Cost starts off
  on a new install, so this is how you ask for it.
- [`/nutshell:nutshell-hide`](#nutshellnutshell-hide) turns them off again,
  in either layout. The model part stays whatever you do, so the row never
  goes blank.
- [`/nutshell:nutshell-emoji`](#nutshellnutshell-emoji) switches between text
  labels and icons.
- [`/nutshell:nutshell-reset`](#nutshellnutshell-reset) puts the parts, emoji,
  layout and color back to what a new install starts with.
- [`/nutshell:nutshell-active`](#nutshellnutshell-active) takes it back, with
  your line settings intact.
- [`/nutshell:nutshell-inactive`](#nutshellnutshell-inactive) hands the row
  back to Claude Code and stops the work behind it.
- [`/nutshell:nutshell-uninstall`](#nutshellnutshell-uninstall) removes both.

## Notice

- macOS runs on its stock tools. The scripts target bash 3.2 and the BSD
  userland, and nothing has to come from Homebrew: the two tools stock macOS
  does not ship, `flock` and `timeout`, are carried by the plugin itself as of
  0.3.4, so Linux, macOS and Windows all get the same locking and the same
  hang guard. The current release has not been run on real Mac hardware yet.
- WSL is still under development. Some functions may be incompatible.

## Requirement

[`/nutshell:nutshell-setup`](#nutshellnutshell-setup) checks every item below
and prints the install command for your OS, so you do not have to work out
which one is missing.

- **`jq`** 1.6 or newer\
  Everything here reads and writes its JSON through it.
  The toggle script stops with a clear error if it is missing.
- **`claude` on your `PATH`**\
  Runs the background probe that decides whether your account has rate limits
  at all. Without it, the rate windows can show a 0% row they should have
  left out.
  Claude Code itself installs this, so a gap here is a `PATH` problem rather
  than a missing program.
- **`curl`**, optional\
  Fetches your account usage endpoint, the same one `/usage` reads. It
  supplies the per-model weekly window (the `fable` segment), and it is what
  lets the 5-hour and weekly percentages correct themselves while you are
  not typing. Without it that one segment never appears and the two
  percentages stay at their last reading until some session gets a reply. It
  is the only outbound network call anything here makes, and a metered
  session never makes it.

`flock` and `timeout`, listed here through 0.3.3, are no longer needed (see
[Notice](#notice)). Where GNU `timeout` is installed it is still used, since it
needs no extra processes. It is recognised by its version output rather than
its name, because the bash in Git for Windows carries Windows' own unrelated
`timeout.exe` on its `PATH`.

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
and registers the statusline, so it simply appears.

Confirm it with:

```bash
/nutshell:nutshell-status
```

A fresh install reports the statusline active, the mode `simple`, model,
session and workspace on, and cost off.

## Usage

Type the command for what you want, or just describe it in plain language:
"hide the cost", "show everything", "turn on emoji", "what's showing?".
Each command has its own description, so a plain request lands on the right
one.

### /nutshell:nutshell-setup

Installs or repairs the scripts and the `statusLine` registration, and checks
the dependencies first.

The dependency check is a read-only report: what the plugin needs, what your
machine has, and the exact command that closes each gap on your OS. It needs
no `jq` itself, so it works on the machine it is diagnosing.

Anything missing is then installed for you, on Linux, macOS, WSL and Windows,
after one question naming every package, its version and its channel. Nothing
is installed before you answer. If you decline, the install continues and the
report says which row stays empty. Four things are never installed for you:
Homebrew, a Node runtime, `bash`, and `claude` itself, which is Claude Code
and can only be a `PATH` problem. A fix needing a `sudo` password is handed
back to you rather than run, since a command asking for a password inside a
tool call has no terminal to ask on.

Then it runs the same sync script as the `SessionStart` hook, which re-copies
any file that differs from the bundled one and restores the registration.

The registration step is skipped, and reported rather than forced, in three
cases: the statusline is inactive, `settings.json` registers someone else's
statusline, or `settings.json` is not a JSON object. A `settings.json` with
comments, a trailing comma, a BOM or any other content that is not a plain
JSON object is never rewritten: nutshell leaves it byte for byte as it is and
names the file to fix.

```bash
/nutshell:nutshell-setup
```

> [!NOTE]
> The hook already syncs the scripts at every session start, but it never
> checks or installs dependencies: installing a package is a change to your
> machine, and a hook that fires at every session start must not make one.
> Run this when the statusline is missing, or when a line stays empty and you
> want to know why.

### /nutshell:nutshell-mode

Moves between the two layouts. It takes `simple` or `detail`, and with no
argument at all it toggles to whichever one you are not on. A new install
starts on `simple`, while an install older than 0.3.4 stays on `detail`, so
an upgrade never changes the row under you.

Simple drops the context bar and the clock time each window resets at, which
is what lets the rest fit on one line. Parts behave the same either way, the
session cost included, and emoji labels apply to both.

Switch between them:

```bash
/nutshell:nutshell-mode
```

Switch to the one-line layout:

```bash
/nutshell:nutshell-mode simple
```

Switch back to the three-line layout:

```bash
/nutshell:nutshell-mode detail
```

### /nutshell:nutshell-color

Switches the accent every value is drawn in. It takes `orange` or `blue`, and
with no argument at all it toggles. A fresh install starts on orange, and so
does an install upgrading from a version that had no color at all, so nobody's
row changes under them.

The accent covers the model name, the advisor, the context counts and the
filled half of its bar, the session cost, the rate percentages and their
reset times, and the location. Labels, separators and punctuation keep the
terminal's own foreground either way, and the five effort colors are
untouched, max effort included: the effort scale is fixed, and a max that
matched the accent would stop standing out.

This one is experimental, like the `fable` segment: it is a `config.json` key
with nothing else behind it, and it may change.

Switch it:

```bash
/nutshell:nutshell-color
```

Pick one:

```bash
/nutshell:nutshell-color blue
```

```bash
/nutshell:nutshell-color orange
```

> [!NOTE]
> The command prints nothing at all, whatever happens, and the color is not
> in what [`/nutshell:nutshell-status`](#nutshellnutshell-status) reports. The
> row itself is the only report there is.

### /nutshell:nutshell-status

Prints where everything stands: whether the statusline is active, which
layout it is on, and the state of session, cost, workspace and emoji. Model is
always on.

```bash
/nutshell:nutshell-status
```

### /nutshell:nutshell-show

Turns a part back on, which means its line in `detail` (for cost, its
segment at the end of the session line) and its segment in `simple`. It takes
`all`, `session`, `cost` or `workspace`, and with no argument at all it turns
all three on. It does not take `emoji`, which is
[its own command](#nutshellnutshell-emoji), and it does not take `model`,
which is always on.

Turn all three on:

```bash
/nutshell:nutshell-show
```

Turn on the cost only:

```bash
/nutshell:nutshell-show cost
```

Turn on the workspace line only:

```bash
/nutshell:nutshell-show workspace
```

### /nutshell:nutshell-hide

Turns a part off, with the same arguments. The registration stays in place, so
the row is still yours and line 1 keeps rendering.

`session` is the rate-limit line, named for the 5-hour and weekly session
limits it tracks. `cost` is the current session's spend at the end of that
line, which stays on its own when the rate windows are hidden. `workspace` is
the location line: the current directory with your home folder shortened to
`~`, the repository parsed from the `origin` remote, and the branch read
straight from `.git/HEAD`. Each part is independent, so a folder outside any
repository still shows its path, and if none of the three resolve the line is
left out rather than printed empty.

Hide the cost:

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

### /nutshell:nutshell-reset

Undoes every show, hide, emoji, mode and color change at once, putting back
the look a new install starts with: session and workspace shown, cost hidden,
text labels, the simple layout and the orange accent. Nothing else changes:
an inactive statusline stays inactive, `settings.json` is not touched, and the
caches and any cost history stay.

```bash
/nutshell:nutshell-reset
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

### /nutshell:nutshell-inactive

Removes the `statusLine` registration from `settings.json`, so Claude Code
shows its own footer again. The choice is remembered, so the sync hook will not
put the statusline back at the next session start.

It also stops the work behind the row: `statusline.sh` exits immediately while
inactive, printing nothing and spawning neither the background auth probe nor
the usage probe. That covers a session that was already running when you turned
it off, in case Claude Code keeps invoking the old command until the session
restarts.

While inactive, `show`, `hide`, `emoji`, `mode` and `color` refuse to
run, since nothing they change would be visible. `status`, `active`, `reset`
and `uninstall` still work.

Hand the row back:

```bash
/nutshell:nutshell-inactive
```

### /nutshell:nutshell-uninstall

Removes the statusline and the installed scripts. It confirms first. See
[Uninstall](#uninstall) for what is kept and what a purge takes.

```bash
/nutshell:nutshell-uninstall
```

## Uninstall

Run [`/nutshell:nutshell-uninstall`](#nutshellnutshell-uninstall) before
removing the plugin, since removing it takes the command with it. Afterwards, remove the `nutshell` plugin from the
`/plugin` menu: otherwise its `SessionStart` hook reinstalls the scripts at the
next session.

By default the uninstall keeps `config.json`, the shared rate-limit cache, the
account usage cache, the auth cache and any cost history an older version left
behind. It still removes every lock file, and the `disabled` flag in the
config it keeps, so a later reinstall does not come back inactive.

Ask for a purge, or pass `--purge`, to wipe those too: the whole
`~/.claude/nutshell/` directory goes, including the retired cost files and
any `ledger_<source>.json` written by another tool. Nothing outside
`~/.claude/nutshell/` is deleted, so a file such as a hand-written
`~/.claude/statusline.sh` survives. Only the
`statusLine` key is removed from `settings.json`; the rest of the file is left
alone. If that key registers a different statusline, not nutshell's, it stays
too, and the uninstall says so. The directories are removed with `rmdir`,
never a recursive delete, so anything unexpected inside survives.

Without the skill, this is the rough equivalent of a purge (then remove the
plugin from `/plugin` as above):

```bash
rm -r ~/.claude/nutshell
jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

## License

MIT. See [LICENSE](LICENSE).
