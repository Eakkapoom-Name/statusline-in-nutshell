#!/usr/bin/env bash
# hooks/cost-refresh.sh: Stop hook. Starts the background cost refresh the
# moment a turn's spend is complete.
#
# Cost only moves when an API response lands, and `Stop` fires when Claude
# finishes responding, so this is when the number on line 2 goes stale.
# Waiting for statusline.sh's own spawn gate instead means waiting out
# COST_CACHE_MAX_AGE (300s), which is why an idle-looking `today:` figure
# could sit minutes behind what ccusage would say.
#
# This computes nothing: it starts the same refresher statusline.sh starts
# and returns at once, so a Stop hook can never add latency to the end of a
# turn. Silent means silent: nothing on stdout (a Stop hook's stdout is
# shown to the user in transcript mode) and nothing on stderr either.
exec 2>/dev/null

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/skills/nutshell-setup/scripts/nutshell-lib.sh" || exit 0

REFRESH="$NUT_BIN_DIR/cost_cache_refresh.sh"
[ -f "$REFRESH" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# Mirrors the refresher's own guard: without ccusage there is nothing to run.
command -v ccusage >/dev/null 2>&1 || exit 0

# Mirror statusline.sh's two gates, for the same reasons. `disabled` means
# the user handed the row back to Claude Code, and inactive has to mean no
# tracking at all, not just no display. `cost: false` means line 2 is
# hidden, so a refresh would spend seconds of CPU on a number nobody can
# see. Both fail open on a missing or unreadable config (a missing key reads
# "null" here, never "true"/"false"), like the rest of the plugin.
IFS=' ' read -r cfg_disabled cfg_cost < <(
  jq -r '[(.disabled|tostring), (.cost|tostring)] | join(" ")' "$NUT_CONFIG" 2>/dev/null
)
[ "$cfg_disabled" = "true" ] && exit 0
[ "$cfg_cost" = "false" ] && exit 0

# Floor. Several turns can finish in quick succession (a subagent burst, a
# short back-and-forth), and each refresh re-reads transcripts for seconds.
# flock already stops two from overlapping, but without a floor every turn
# would still queue one more. 10s keeps the row within a turn of the truth
# while collapsing bursts into a single run. A negative age means the cache
# carries a future stamp (clock moved back): treat that as stale rather than
# blocking refreshes until the clock catches up, as statusline.sh does.
MIN_REFRESH_INTERVAL=10
mtime=$(nut_mtime "$NUT_COST_CACHE")
if [ -n "$mtime" ]; then
  age=$(( $(date +%s) - mtime ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$MIN_REFRESH_INTERVAL" ] && exit 0
fi

nut_spawn bash "$REFRESH"
exit 0
