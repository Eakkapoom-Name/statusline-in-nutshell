#!/usr/bin/env bash
# cost_cache_refresh.sh: background refresh of the cost windows shown on
# line 2, feeding ~/.claude/nutshell/state/cost_cache.json with today /
# this week (Sun-Sat) / this month / all-time spend.
#
# Usage: cost_cache_refresh.sh [--reset-all-time]
#
# Cost comes from `ccusage daily --json`, which scans the local transcript
# logs. But ccusage only sees logs that STILL EXIST, and Claude Code prunes
# old transcripts on a rolling (roughly monthly) window, so a day's cost
# silently disappears from ccusage once its log is deleted. To stop month
# and all-time from shrinking, ccusage is merged into a PERSISTENT per-day
# ledger (cost_ledger.json) with max-per-day: a day's recorded cost can only
# ever go up, never vanish. The four windows are then summed from the
# ledger, so they still roll over on the real calendar (midnight, Sunday,
# the 1st) but never lose history to pruning. The ledger can only protect
# history from its first run forward.
#
# Other tools can contribute spend through extra ledgers,
# state/ledger_<source>.json, in the same {"YYYY-MM-DD": cost} shape. This
# script never writes them: each source owns its file and is expected to be
# monotonic per day, which is what lets the all-time baseline treat the
# combined totals like the ledger. (The pre-0.3.1 path,
# ~/.claude/.cost_ledger_<source>.json, is no longer read.)
#
# `--reset-all-time` freezes the current combined per-day totals as the
# all-time baseline, so all-time drops to 0 and counts only spend from here
# forward. Because the ledger is monotonic, baselined days stay frozen and
# net to 0 while later spend counts in full, which is what makes a reset
# stick even though every refresh re-merges ccusage's still-visible days.
#
# ccusage takes seconds, so this runs in the background (spawned by
# statusline.sh and by the Stop hook) and is never awaited.

case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
. "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null || exit 0
nut_ensure_dirs

reset_all_time=0
[ "${1:-}" = "--reset-all-time" ] && reset_all_time=1

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Subtract N calendar days, GNU (-d) or BSD/macOS (-v). Calendar-day, not
# epoch-seconds: N*86400 lands on the wrong date across a DST transition.
days_ago_date() {
  date -d "-${1} days" "+%Y-%m-%d" 2>/dev/null || date -v-"${1}"d "+%Y-%m-%d" 2>/dev/null
}

# A normal (background) run skips when another refresh holds the lock; a
# reset run WAITS for it instead, so a user-triggered reset can never be
# silently skipped. flock is util-linux only (absent on stock macOS): when
# missing, proceed unlocked rather than fail. The redirection is guarded as
# well as the command: if the lock file cannot be opened (read-only home,
# full disk) the unguarded form left fd 9 closed and then ran flock against
# it, which failed on every run.
take_lock() {
  command -v flock >/dev/null 2>&1 && exec 9>"$NUT_COST_LOCK" 2>/dev/null || return 0
  if [ "$reset_all_time" -eq 1 ]; then
    flock 9
  else
    flock -n 9 || exit 0
  fi
}

# Sum two per-day maps key by key, adding ($op = "+") or keeping the larger
# value ($op = "max").
merge_days() {  # a b op
  jq -n --argjson a "$1" --argjson b "$2" --arg op "$3" '
    reduce (($a + $b) | keys_unsorted[]) as $k
      ({}; .[$k] = (if $op == "max" then ([($a[$k] // 0), ($b[$k] // 0)] | max)
                    else (($a[$k] // 0) + ($b[$k] // 0)) end))
  '
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

take_lock
command -v ccusage >/dev/null 2>&1 || exit 0

today=$(date +%Y-%m-%d)
days_since_sunday=$(date +%w)  # 0=Sun ... 6=Sat, portable across GNU/BSD date
week_start=$(days_ago_date "$days_since_sunday")
# Neither GNU `date -d` nor BSD `date -v` worked, so week_start is empty.
# The weekly sum selects on `.key >= $week_start`, and every date string is
# >= "", so an empty value would silently report the ALL-TIME total as this
# week's spend. Fall back to today: under-reporting a partial week is wrong
# in a way the user can spot, over-reporting it as all-time is not.
[ -n "$week_start" ] || week_start="$today"
month_prefix=$(date +%Y-%m)

# Existing ledger, or an empty object if it is missing / unreadable / corrupt.
ledger=$(jq -e . "$NUT_COST_LEDGER" 2>/dev/null) || ledger='{}'

# Scope the ccusage scan. A full `ccusage daily --json` re-reads every
# transcript in ~/.claude/projects (measured 5-14s against 763 files /
# 447MB), and almost all of that re-derives days that can no longer change.
# Only days from the ledger's newest entry onward can still move: earlier
# ones are already recorded, and the max-per-day merge keeps a day the scan
# did not return. So a scan starting at the ledger's last date is exactly as
# correct as a full one. Starting there rather than at today is what
# finalises the previous day after midnight, whose last scan only ever saw
# it partially. Full scan with no ledger to start from, and on a reset,
# which freezes the whole history as the baseline. A ledger date ahead of
# today (clock moved backwards) is clamped so the scan can never skip today.
#
# Do NOT reach for ccusage's --offline to make this faster: its offline
# pricing table lacked the models this account runs, so today came back 0.
since_compact=""
if [ "$reset_all_time" -eq 0 ]; then
  ledger_last=$(printf '%s' "$ledger" | jq -r '[keys[] | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))] | max // empty' 2>/dev/null)
  if [ -n "$ledger_last" ]; then
    [ "$ledger_last" \> "$today" ] && ledger_last="$today"
    since_compact=$(printf '%s' "$ledger_last" | tr -d '-')
  fi
fi
if [ -n "$since_compact" ]; then
  json=$(ccusage daily --since "$since_compact" --json 2>/dev/null) || exit 0
else
  json=$(ccusage daily --json 2>/dev/null) || exit 0
fi

# ccusage's per-day cost map: {"YYYY-MM-DD": cost, ...}. An empty window
# (ccusage returns {"daily": []}) merges to nothing and leaves the ledger alone.
ccusage_days=$(printf '%s' "$json" | jq '[.daily[]? | {(.period): .totalCost}] | add // {}')

# Merge into the ledger with max-per-day, and persist it (sorted keys, for a
# stable, readable file). nut_write_json_object leaves the existing ledger
# untouched when the result is empty or not an object.
merged=$(merge_days "$ledger" "$ccusage_days" max)
nut_write_json_object "$(printf '%s' "$merged" | jq -S .)" "$NUT_COST_LEDGER"

# Fold in the extra ledgers. A file that is not a JSON object is skipped
# whole, and inside one only date keys with numeric values count, so a
# foreign, half-written or corrupt file cannot poison the sums. The ccusage
# ledger persisted above stays free of them.
combined=$merged
for extra_file in "$NUT_EXTRA_LEDGER_PREFIX"*.json; do
  [ -f "$extra_file" ] || continue
  extra=$(jq -e 'select(type == "object")
    | with_entries(select((.key | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
                          and (.value | type == "number")))' "$extra_file" 2>/dev/null) || continue
  combined=$(merge_days "$combined" "$extra" +)
done

# On a reset, freeze the combined totals as the baseline, so extra-ledger
# spend up to now is reset along with ccusage's.
if [ "$reset_all_time" -eq 1 ]; then
  nut_write_json_object "$(printf '%s' "$combined" | jq -S .)" "$NUT_COST_BASELINE"
fi

# All-time counts only per-day spend ABOVE the baseline (no baseline file:
# the whole ledger). A higher value on a baselined day, or a brand-new day,
# counts in full.
baseline=$(jq -e . "$NUT_COST_BASELINE" 2>/dev/null) || baseline='{}'

result=$(printf '%s' "$combined" | jq \
  --arg today "$today" \
  --arg week_start "$week_start" \
  --arg month_prefix "$month_prefix" \
  --argjson baseline "$baseline" \
  '{
    today_cost: (.[$today] // 0),
    weekly_cost: ([to_entries[] | select(.key >= $week_start and .key <= $today) | .value] | add // 0),
    monthly_cost: ([to_entries[] | select(.key | startswith($month_prefix)) | .value] | add // 0),
    all_time_cost: ([to_entries[] | (.value - ($baseline[.key] // 0)) | select(. > 0)] | add // 0)
  }')

cache_out=$(jq -n --argjson ts "$(date +%s)" --argjson r "$result" '{updated_at: $ts} + $r')
nut_write_json_object "$cache_out" "$NUT_COST_CACHE"

# Always 0, like every background job here: nothing awaits this except
# `reset-all-time`, which reports the reset as done once the run completes.
exit 0
