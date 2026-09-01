---
name: nutshell
description: Use when the user wants to show or hide parts of their Claude Code status line, or toggle emoji labels.
argument-hint: "[show|hide|model|cost|rate] | emoji | status | reset-all-time-cost | uninstall"
---

# Status Line Section Toggle

`~/.claude/statusline.config.json` controls three parts of
`~/.claude/statusline.sh`, plus an independent `emoji` label toggle
(default off).

| Part | Keyword | Content |
|------|---------|---------|
| model | `model` | model name, advisor, context bar |
| cost | `cost` | session/today/week/month/all-time spend |
| rate | `rate` | session + week rate limits |
| workspace | `workspace` | current directory, repo, git branch |

## What to do

0. If any of `statusline.sh`, `statusline-toggle.sh`,
   `cost_cache_refresh.sh` is missing from `~/.claude/`, or differs
   from this skill's own bundled `scripts/` copy, install silently
   (it ships with the skill in both install paths): copy the
   missing/changed scripts to `~/.claude/` (back up any existing one
   to `<name>.bak` first), `chmod +x` them. Also, if
   `~/.claude/settings.json` lacks
   `"statusLine": {"type": "command", "command": "bash ~/.claude/statusline.sh", "refreshInterval": 1}`
   (key absent, or present but different), back up settings.json and
   add/update it via `jq`, UNLESS `statusline.config.json` has
   `"disabled": true` (the user handed the row back to Claude Code with
   `off`), in which case leave settings.json alone. All three keys are
   required: without
   `refreshInterval` the status line only re-runs on assistant messages
   and a few UI events, so disk-sourced segments (advisor, cost, rate)
   stay stale while the session is idle. Never touch `statusline.config.json`,
   `.cost_cache.json`, `.cost_ledger.json`, `.cost_baseline.json`,
   `.rate_cache.json`, `.auth_cache.json`.
1. "turn the status line off", "give me the default status line back",
   "disable it" -> `bash ~/.claude/statusline-toggle.sh off`. "turn it back
   on", "restore it" -> `... on`. These are NOT the same as `hide`/`show`:
   `off` removes the settings.json registration so Claude Code shows its own
   footer, while `all off` keeps ours registered and prints a blank row.
2. Otherwise parse the request into a part
   (`model`/`cost`/`rate`/`workspace`/`emoji`/`all`) and action:
   - "show X" / "hide X" -> on / off.
   - bare `show` -> all parts on. Bare `hide` -> all parts off.
   - bare part name alone -> toggle.
3. Run (never hand-edit the config):
   - `bash ~/.claude/statusline-toggle.sh <part> off|on|toggle`
   - `bash ~/.claude/statusline-toggle.sh all off|on`
   - `bash ~/.claude/statusline-toggle.sh emoji [off|on]`
   - `bash ~/.claude/statusline-toggle.sh on|off`
   - `bash ~/.claude/statusline-toggle.sh status`
4. Report the script's output verbatim (`part: state` line(s), or the
   `status` table preformatted). No prose, no unchanged-part mentions.
5. Before a toggle that leaves every part off, ask: "Hiding all parts will
   leave the status line blank. Do you want to proceed?" Wait for yes/no.
6. Reply to any yes/no confirmation with exactly "Abort." or "Done." —
   nothing else. Never restate the question, never add prose, even for a
   stray yes/no with no pending action.

## Resetting all-time cost

Irreversible (today/week/month unaffected). Requires `ccusage`; without
it, tell the user this feature is unavailable. Ask first: "This
permanently resets your all-time cost. Today/week/month stay unaffected.
Proceed?" Only after yes, run
`bash ~/.claude/statusline-toggle.sh reset-all-time --yes`.
Without `--yes` it only warns and does nothing.

## Uninstalling

Triggered by requests like "uninstall", "remove the status line". Ask
first: "This removes the status line registration and deletes the
installed scripts from ~/.claude/. Your toggle config and cost history
are kept. Proceed?" (If the user explicitly asked to also wipe config
and cost history, fold that in: "...deletes the installed scripts from
~/.claude/, and also wipes your toggle config and cost history. Proceed?")
Wait for yes/no, reply exactly "Done." or "Abort.".

If this is a marketplace/plugin install, first tell the user to remove
the `nutshell-statusline` plugin via the `/plugin` menu, since its
`SessionStart` hook would otherwise reinstall the scripts next session.
npx installs have no hook, so no step is needed before the script; after
it finishes, tell the user to run `npx skills remove nutshell` to remove
the skill itself.

Only after yes, run `bash ~/.claude/statusline-toggle.sh uninstall --yes`
(or `bash ~/.claude/statusline-toggle.sh uninstall --yes --purge` if the
user asked to also wipe config/cost history). Without `--yes` it only
warns and does nothing.
