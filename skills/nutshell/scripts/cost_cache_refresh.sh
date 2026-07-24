#!/usr/bin/env bash
# Refreshes ~/.claude/.cost_cache.json with today / this-week (Sun-Sat) /
# this-month / all-time Claude Code spend.
#
# Cost is sourced from `ccusage daily --json` (which scans local transcript logs),
# but ccusage only sees logs that STILL EXIST — Claude Code prunes old transcript
# logs on a rolling (~monthly) window, so a day's cost silently disappears from
# ccusage once its log file is deleted. To stop month/all-time from shrinking as
# that happens, we merge ccusage into a PERSISTENT per-day ledger
# (~/.claude/.cost_ledger.json) using max-per-day: a day's recorded cost can only
# ever go up, never vanish. All four windows are then summed from the ledger, so
# they still roll over on the real calendar (midnight, Sunday, the 1st) but never
# lose history to log pruning.
#
# Caveat: the ledger can only protect history from its first run forward. Any cost
# ccusage had already lost before the ledger existed cannot be recovered.
#
# ccusage takes several seconds, so this runs in the background and is never awaited
# by statusline.sh.

CACHE_FILE="$HOME/.claude/.cost_cache.json"
LEDGER_FILE="$HOME/.claude/.cost_ledger.json"
BASELINE_FILE="$HOME/.claude/.cost_baseline.json"
LOCK_FILE="$HOME/.claude/.cost_cache.lock"

# Run `date` for a unix epoch with the given format, GNU (-d) or BSD (-r) style.
epoch_date() {
  date -d "@${1}" "$2" 2>/dev/null || date -r "${1}" "$2" 2>/dev/null
}

# Subtract N calendar days, GNU (-d) or BSD/macOS (-v). Calendar-day, not
# epoch-seconds: N*86400 lands on the wrong date across a DST transition.
days_ago_date() {
  date -d "-${1} days" "+%Y-%m-%d" 2>/dev/null || date -v-"${1}"d "+%Y-%m-%d" 2>/dev/null
}

# Write $1 (JSON text) to file $2 atomically, but only if it is a non-empty
# JSON object. Protects the ledger/baseline/cache from being truncated (or
# replaced with garbage) if an upstream jq step silently produced empty or
# malformed output. On failure the existing file is left untouched and the
# temp file is removed.
safe_write_json() {
  local content="$1" target="$2" tmp
  tmp="${target}.tmp"
  printf '%s' "$content" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ] && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$target" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# `--reset-all-time` freezes the current ledger as the all-time baseline (see below),
# so all-time drops to 0 and then counts only spend from here forward. A normal
# (background) run skips when another refresh holds the lock; a reset run WAITS for
# the lock instead, so a user-triggered reset can never be silently skipped.
reset_all_time=0
[ "${1:-}" = "--reset-all-time" ] && reset_all_time=1

# flock is GNU/util-linux only (absent on macOS's stock userland); when it's
# missing, proceed without locking rather than failing, same degradation
# pattern as hooks/sync.sh.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if [ "$reset_all_time" -eq 1 ]; then
    flock 9
  else
    flock -n 9 || exit 0
  fi
fi

command -v ccusage >/dev/null 2>&1 || exit 0

json=$(ccusage daily --json 2>/dev/null) || exit 0

today=$(date +%Y-%m-%d)
days_since_sunday=$(date +%w)  # 0=Sun ... 6=Sat (portable across GNU/BSD date)
week_start=$(days_ago_date "$days_since_sunday")
month_prefix=$(date +%Y-%m)

# Existing ledger, or an empty object if it's missing / unreadable / corrupt.
ledger=$(jq -e . "$LEDGER_FILE" 2>/dev/null) || ledger='{}'

# ccusage's current per-day cost map: {"YYYY-MM-DD": cost, ...}
ccusage_days=$(printf '%s' "$json" | jq '[.daily[]? | {(.period): .totalCost}] | add // {}')

# Merge ccusage into the ledger, keeping the larger value for each day so a day's
# cost never decreases — even when its transcript log gets pruned and ccusage
# stops reporting it (that day simply isn't in $ccusage_days, so the ledger's value
# is kept as-is).
merged=$(jq -n --argjson a "$ledger" --argjson b "$ccusage_days" '
  reduce (($a + $b) | keys_unsorted[]) as $k
    ({}; .[$k] = ([($a[$k] // 0), ($b[$k] // 0)] | max))
')

# Persist the merged ledger atomically (sorted keys for a stable, readable
# file). Guarded by safe_write_json: an empty or non-object result (e.g. from
# an upstream jq failure) leaves the existing ledger untouched instead of
# truncating it.
ledger_out=$(printf '%s' "$merged" | jq -S .)
safe_write_json "$ledger_out" "$LEDGER_FILE"

# On an explicit reset, freeze the just-merged ledger as the all-time baseline.
if [ "$reset_all_time" -eq 1 ]; then
  safe_write_json "$ledger_out" "$BASELINE_FILE"
fi

# All-time counts only per-day spend ABOVE the baseline snapshot (no baseline file =>
# the whole ledger, the default). Because the ledger is monotonic (max-per-day),
# baselined days stay frozen and net to 0, while later spend — a higher value on a
# baselined day, or a brand-new day absent from the baseline — counts in full. That
# is what makes a reset stick even though every refresh re-merges ccusage's still-
# visible days.
baseline=$(jq -e . "$BASELINE_FILE" 2>/dev/null) || baseline='{}'

# Sum the four windows from the merged ledger (all-time net of the baseline).
result=$(printf '%s' "$merged" | jq \
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
safe_write_json "$cache_out" "$CACHE_FILE"
