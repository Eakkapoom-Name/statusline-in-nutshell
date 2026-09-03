#!/usr/bin/env bash
# Refreshes ~/.claude/nutshell/state/cost_cache.json with today / this-week (Sun-Sat) /
# this-month / all-time spend: what ccusage reports plus any extra ledgers.
#
# Cost is sourced from `ccusage daily --json` (which scans local transcript logs),
# but ccusage only sees logs that STILL EXIST: Claude Code prunes old transcript
# logs on a rolling (~monthly) window, so a day's cost silently disappears from
# ccusage once its log file is deleted. To stop month/all-time from shrinking as
# that happens, we merge ccusage into a PERSISTENT per-day ledger
# (~/.claude/nutshell/state/cost_ledger.json) using max-per-day: a day's recorded cost can only
# ever go up, never vanish. All four windows are then summed from the ledger, so
# they still roll over on the real calendar (midnight, Sunday, the 1st) but never
# lose history to log pruning.
#
# Caveat: the ledger can only protect history from its first run forward. Any cost
# ccusage had already lost before the ledger existed cannot be recovered.
#
# Other tools can contribute spend of their own through extra ledgers,
# ~/.claude/nutshell/state/ledger_<source>.json, in the same
# {"YYYY-MM-DD": cost} shape (the path before 0.3.1 was
# ~/.claude/.cost_ledger_<source>.json, and it is no longer read: a tool
# writing there must be repointed at the new one). A local OpenRouter proxy
# recording the credits it was actually charged is one such source. Their
# per-day values are added to the ccusage ledger's before the
# windows are summed. This script never writes them: each source owns its file,
# and each is expected to be monotonic per day (only ever adding), which is what
# lets the all-time baseline below treat the combined totals like the ledger.
#
# ccusage takes several seconds, so this runs in the background and is never awaited
# by statusline.sh.

# Pinned for the same reason as statusline.sh: date output and decimal
# formatting must not vary with the machine's locale, since the cache this
# writes is parsed back as dot-decimal numbers and %Y-%m-%d dates.
LC_ALL=C
export LC_ALL

# One directory for everything this plugin owns (0.3.1); see statusline.sh.
NUT_DIR="$HOME/.claude/nutshell"
CACHE_FILE="$NUT_DIR/state/cost_cache.json"
LEDGER_FILE="$NUT_DIR/state/cost_ledger.json"
BASELINE_FILE="$NUT_DIR/state/cost_baseline.json"
LOCK_FILE="$NUT_DIR/locks/cost_cache.lock"

# Create our own directories rather than trusting the sync hook to have done
# it. A missing locks/ is not a cosmetic problem: `exec 9>"$LOCK_FILE"` on a
# path whose directory does not exist fails, and a failed redirection on
# `exec` terminates the shell outright, so the whole refresh would die before
# writing anything. Guarded by a test so the common case costs no process:
# mkdir is not a builtin, and this runs on every render in statusline.sh.
[ -d "$NUT_DIR/state" ] && [ -d "$NUT_DIR/locks" ] \
  || mkdir -p "$NUT_DIR/state" "$NUT_DIR/locks" 2>/dev/null

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
  # Same-directory mktemp, not a fixed "${target}.tmp": where flock is absent
  # (stock macOS) two refreshes can run at once, and a shared fixed name lets
  # one truncate the file the other is about to validate and rename. mktemp
  # also keeps the rename on the same filesystem, so the mv stays atomic.
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
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
# The lock descriptor must be open before flock is called on it. Guard the
# redirection too, not just `command -v flock`: if $LOCK_FILE cannot be opened
# (read-only home, full disk) the unguarded form left fd 9 closed and then ran
# flock against it, which fails on every run. Degrade the same way a missing
# flock does, by proceeding unlocked.
locked=0
if command -v flock >/dev/null 2>&1 && exec 9>"$LOCK_FILE" 2>/dev/null; then
  locked=1
fi
if [ "$locked" -eq 1 ]; then
  if [ "$reset_all_time" -eq 1 ]; then
    flock 9
  else
    flock -n 9 || exit 0
  fi
fi

command -v ccusage >/dev/null 2>&1 || exit 0

today=$(date +%Y-%m-%d)
days_since_sunday=$(date +%w)  # 0=Sun ... 6=Sat (portable across GNU/BSD date)
week_start=$(days_ago_date "$days_since_sunday")
# Neither GNU `date -d` nor BSD `date -v` worked, so week_start is empty. The
# weekly sum below selects on `.key >= $week_start`, and every date string is
# >= "", so an empty value would silently report the ALL-TIME total as this
# week's spend. Fall back to today: under-reporting a partial week is wrong in
# a way the user can spot, over-reporting it as all-time is not.
[ -n "$week_start" ] || week_start="$today"
month_prefix=$(date +%Y-%m)

# Existing ledger, or an empty object if it's missing / unreadable / corrupt.
ledger=$(jq -e . "$LEDGER_FILE" 2>/dev/null) || ledger='{}'

# Scope the ccusage scan. A full `ccusage daily --json` re-reads every
# transcript in ~/.claude/projects: measured 4.9s against 763 files / 447MB on
# the author's machine, which is why this runs in the background at all and
# why the cache it feeds is allowed to be minutes old. Almost all of that work
# is re-deriving days that can no longer change.
#
# Only days from the ledger's newest entry onward can still move: earlier ones
# are already recorded, and the merge below keeps a day the scan did not
# return (it takes the max per day, and an absent day is simply not in
# $ccusage_days). So a scan that starts at the ledger's last date is exactly
# as correct as a full one, while costing about a third of the time. Starting
# there rather than at today is what finalises the previous day after
# midnight: the last scan before the rollover only ever saw a partial day.
#
# Full scan when there is no ledger to start from, and on --reset-all-time,
# which freezes the whole per-day history as the baseline and therefore needs
# all of it. A ledger date ahead of today (clock moved backwards) is clamped,
# so a skewed stamp can never scope the scan into the future and skip today.
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

# ccusage's current per-day cost map: {"YYYY-MM-DD": cost, ...}
ccusage_days=$(printf '%s' "$json" | jq '[.daily[]? | {(.period): .totalCost}] | add // {}')

# Merge ccusage into the ledger, keeping the larger value for each day so a day's
# cost never decreases, even when its transcript log gets pruned and ccusage
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

# Fold in the extra ledgers (see the header). A file that is not a JSON object
# is skipped whole, and inside one only date keys with numeric values count, so
# a foreign, half-written or corrupt file cannot poison the sums. The ccusage
# ledger persisted above stays free of them.
combined=$merged
for extra_file in "$NUT_DIR/state/ledger_"*.json; do
  [ -f "$extra_file" ] || continue
  extra=$(jq -e 'select(type == "object")
    | with_entries(select((.key | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
                          and (.value | type == "number")))' "$extra_file" 2>/dev/null) || continue
  combined=$(jq -n --argjson a "$combined" --argjson b "$extra" '
    reduce (($a + $b) | keys_unsorted[]) as $k
      ({}; .[$k] = (($a[$k] // 0) + ($b[$k] // 0)))
  ')
done

# On an explicit reset, freeze the combined per-day totals as the all-time
# baseline, so extra-ledger spend up to now is reset along with ccusage's.
if [ "$reset_all_time" -eq 1 ]; then
  safe_write_json "$(printf '%s' "$combined" | jq -S .)" "$BASELINE_FILE"
fi

# All-time counts only per-day spend ABOVE the baseline snapshot (no baseline file =>
# the whole ledger, the default). Because the ledger is monotonic (max-per-day),
# baselined days stay frozen and net to 0, while later spend (a higher value on a
# baselined day, or a brand-new day absent from the baseline) counts in full. That
# is what makes a reset stick even though every refresh re-merges ccusage's still-
# visible days.
baseline=$(jq -e . "$BASELINE_FILE" 2>/dev/null) || baseline='{}'

# Sum the four windows from the combined per-day totals (all-time net of the
# baseline).
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
safe_write_json "$cache_out" "$CACHE_FILE"
