---
name: statusline-in-nutshell
description: Use when the user wants to show or hide parts of their Claude Code status line, or toggle emoji labels.
argument-hint: [show|hide|model|cost|rate] | emoji | status | reset-all-time-cost
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

## What to do

0. If any of `statusline.sh`, `statusline-toggle.sh`,
   `cost_cache_refresh.sh` is missing from `~/.claude/`, or differs
   from this skill's own bundled `scripts/` copy, install silently
   (it ships with the skill in both install paths): copy the
   missing/changed scripts to `~/.claude/` (back up any existing one
   to `<name>.bak` first), `chmod +x` them. Also, if
   `~/.claude/settings.json` lacks
   `"statusLine": {"type": "command", "command": "bash ~/.claude/statusline.sh"}`
   (key absent, or present but different), back up settings.json and
   add/update it via `jq`. Never touch `statusline.config.json`,
   `.cost_cache.json`, `.cost_ledger.json`, `.cost_baseline.json`.
1. Parse the request into a part (`model`/`cost`/`rate`/`emoji`/`all`) and
   action:
   - "show X" / "hide X" -> on / off.
   - bare `show` -> all three on. Bare `hide` -> all three off.
   - bare part name alone -> toggle.
2. Run (never hand-edit the config):
   - `bash ~/.claude/statusline-toggle.sh <part> off|on|toggle`
   - `bash ~/.claude/statusline-toggle.sh all off|on`
   - `bash ~/.claude/statusline-toggle.sh emoji [off|on]`
   - `bash ~/.claude/statusline-toggle.sh status`
3. Report the script's output verbatim (`part: state` line(s), or the
   `status` table preformatted). No prose, no unchanged-part mentions.
4. Before a toggle that leaves all three off, ask: "Hiding all parts will
   leave the status line blank. Do you want to proceed?" Wait for yes/no.
5. Acknowledge any yes/no confirmation briefly ("Abort." / "Done."), then
   act or stop.

## Resetting all-time cost

Irreversible (today/week/month unaffected). Requires `ccusage`; without
it, tell the user this feature is unavailable. Ask first: "This
permanently resets your all-time cost. Today/week/month stay unaffected.
Proceed?" Only after yes, run
`bash ~/.claude/statusline-toggle.sh reset-all-time --yes`.
Without `--yes` it only warns and does nothing.
