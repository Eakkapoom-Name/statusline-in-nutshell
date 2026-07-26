#!/usr/bin/env bash
# Claude Code statusLine script
# Reads the statusLine JSON payload from stdin and prints a single summary line.
# All optional fields are omitted gracefully (no blank labels) when absent.

input=$(cat)

# One jq call instead of one per field. `// ""` not `// empty` (empty is a
# zero-output generator, would drop the whole array on a null field).
# Delimiter is \x1f, not @tsv's tab: `read` collapses consecutive tab/space
# delimiters even when IFS is set to just one of them, silently shifting
# fields whenever one is empty (routine: absent .effort, absent .cost).
# \x1f isn't IFS whitespace, so it doesn't collapse.
IFS=$'\x1f' read -r model effort ctx_used ctx_used_tokens ctx_total_tokens cost five_pct five_reset week_pct week_reset five_hour_present week_present < <(
  jq -r '[
      (.model.display_name // ""),
      (.effort.level // ""),
      (.context_window.used_percentage // ""),
      (.context_window.total_input_tokens // ""),
      (.context_window.context_window_size // ""),
      (.cost.total_cost_usd // ""),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // ""),
      (.rate_limits.five_hour != null),
      (.rate_limits.seven_day != null)
    ] | map(tostring) | join("\u001f")' <<< "$input" 2>/dev/null
)
advisor_raw=$(jq -r '.advisorModel // empty' "$HOME/.claude/settings.json" 2>/dev/null)

# Alias -> display name. settings.json only stores the bare alias, no
# runtime lookup exists for the resolved name, so this WILL drift on new
# model releases (opus was "Opus 4.8", now "Opus 5" as of 2026-07).
advisor_display_name() {
  case "$1" in
    fable) printf 'Fable 5' ;;
    sonnet) printf 'Sonnet 5' ;;
    opus) printf 'Opus 5' ;;
    haiku) printf 'Haiku 4.5' ;;
    *) printf '%s' "$1" ;;
  esac
}

advisor=""
[ -n "$advisor_raw" ] && advisor=$(advisor_display_name "$advisor_raw")

# Section visibility — the model / cost / usage-rate parts can each be hidden via
# ~/.claude/statusline.config.json (toggled by statusline-toggle.sh or the /statusline
# skill). Fail open: a missing file, missing key, or bad value means the part is shown,
# so the status line never silently goes blank.
STATUSLINE_CONFIG_FILE="$HOME/.claude/statusline.config.json"
show_model=true
show_cost=true
show_rate=true
# Emoji mode — replaces text labels ("model:", "session:", ...) with icons.
# Fail CLOSED (default off): unlike show_*, a missing/bad key must not
# silently switch the status line to icons the user didn't ask for.
emoji_mode=false
if [ -f "$STATUSLINE_CONFIG_FILE" ]; then
  # Raw value, not `.key // "true"` (// treats false as empty, would hide
  # it). Missing key -> "null" text, so show_* stays shown (fail open),
  # emoji stays off (fail closed). Duplicated in statusline-toggle.sh's
  # get_part()/get_emoji(); keep both in sync by hand.
  IFS=$'\x1f' read -r cfg_model cfg_cost cfg_rate cfg_emoji < <(
    jq -r '[(.model|tostring), (.cost|tostring), (.rate|tostring), (.emoji|tostring)] | join("\u001f")' "$STATUSLINE_CONFIG_FILE" 2>/dev/null
  )
  [ "$cfg_model" = "false" ] && show_model=false
  [ "$cfg_cost" = "false" ] && show_cost=false
  [ "$cfg_rate" = "false" ] && show_rate=false
  [ "$cfg_emoji" = "true" ] && emoji_mode=true
fi

# Today / weekly / monthly / all-time cost come from a background-refreshed
# cache (~/.claude/.cost_cache.json) since computing them via `ccusage` takes
# several seconds — too slow to run inline on every 1s status line render.
# Each window is recomputed from the real calendar on every refresh, so they
# roll over on their own (today at midnight, weekly on Sunday, monthly on the 1st).
COST_CACHE_FILE="$HOME/.claude/.cost_cache.json"
COST_CACHE_MAX_AGE=300

today_cost=""
weekly_cost=""
monthly_cost=""
all_time_cost=""
cache_updated_at=0
if [ -f "$COST_CACHE_FILE" ]; then
  # One jq call, five fields (same // "" and \x1f reasoning as above).
  IFS=$'\x1f' read -r today_cost weekly_cost monthly_cost all_time_cost cache_updated_at < <(
    jq -r '[(.today_cost // ""), (.weekly_cost // ""), (.monthly_cost // ""), (.all_time_cost // ""), (.updated_at // 0)] | map(tostring) | join("\u001f")' "$COST_CACHE_FILE" 2>/dev/null
  )
fi

# Invalid JSON in the cache file leaves cache_updated_at empty or non-numeric
# (jq -r prints nothing on a parse error). Fall back to 0 so the arithmetic
# below never errors, and the age comes out huge, which correctly triggers
# a repair refresh.
case "$cache_updated_at" in
  ''|*[!0-9]*) cache_updated_at=0 ;;
esac

cache_age=$(( $(date +%s) - cache_updated_at ))
if [ "$show_cost" = true ] && [ "$cache_age" -ge "$COST_CACHE_MAX_AGE" ]; then
  ( nohup bash "$HOME/.claude/cost_cache_refresh.sh" >/dev/null 2>&1 & disown ) 2>/dev/null
fi

ORANGE='\033[38;2;217;119;87m'
GRAY='\033[38;5;240m'
RESET='\033[0m'

# Font-only colors matching the /effort picker's per-level colors.
EFFORT_LOW='\033[38;2;230;180;40m'      # low = warning (yellow)
EFFORT_MEDIUM='\033[38;2;80;200;120m'   # medium = success (green)
EFFORT_HIGH='\033[38;2;177;185;249m'    # high = permission (periwinkle)
EFFORT_XHIGH='\033[38;2;185;150;235m'   # xhigh = lavender
EFFORT_MAX="$ORANGE"                    # max = Claude brand color (same as context bar)

# Pick the font color for a given effort level string.
effort_color() {
  case "$1" in
    low) printf '%b' "$EFFORT_LOW" ;;
    medium) printf '%b' "$EFFORT_MEDIUM" ;;
    high) printf '%b' "$EFFORT_HIGH" ;;
    xhigh) printf '%b' "$EFFORT_XHIGH" ;;
    max) printf '%b' "$EFFORT_MAX" ;;
    *) printf '%b' "$ORANGE" ;;
  esac
}

# Field label — word ("model:") or icon ("🧠") depending on emoji_mode,
# toggled via `/statusline emoji` (~/.claude/statusline.config.json → "emoji").
label() {
  if [ "$emoji_mode" = true ]; then
    case "$1" in
      model)        printf '💡' ;;
      advisor)      printf '🎓' ;;
      context)      printf '⏳' ;;
      cost_session) printf '🪙' ;;
      cost_today)   printf '⛅' ;;
      cost_week)    printf '📅' ;;
      cost_month)   printf '🗓️' ;;
      cost_alltime) printf '💳' ;;
      rate_five)    printf '🕐' ;;
      rate_week)    printf '♻️' ;;
    esac
  else
    case "$1" in
      model)        printf 'model:' ;;
      advisor)      printf 'advisor:' ;;
      context)      printf 'context:' ;;
      cost_session) printf 'session:' ;;
      cost_today)   printf 'today:' ;;
      cost_week)    printf 'week:' ;;
      cost_month)   printf 'month:' ;;
      cost_alltime) printf 'all-time:' ;;
      rate_five)    printf '5 hours session:' ;;
      rate_week)    printf 'weekly session:' ;;
    esac
  fi
}

# Format a raw token count: 51800 -> "51.8k", 1000000 -> "1.0m". Values under 1000 print as-is.
fmt_tokens() {
  local n="$1"
  [ -z "$n" ] && return
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    awk -v n="$n" 'BEGIN { printf "%.1fm", n/1000000 }'
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    awk -v n="$n" 'BEGIN { printf "%.1fk", n/1000 }'
  else
    printf '%s' "$n"
  fi
}

# Render a colored block-bar for a percentage (0-100), e.g. "[███░░░░░░░]".
render_bar() {
  local pct="$1"
  local width=10
  [ -z "$pct" ] && return
  local filled
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { f = int((p/100)*w + 0.5); if (f > w) f = w; if (f < 0) f = 0; print f }')
  local empty=$((width - filled))
  local bar="[${ORANGE}"
  local i
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  bar+="${RESET}${GRAY}"
  for ((i = 0; i < empty; i++)); do bar+="░"; done
  bar+="${RESET}]"
  printf '%b' "$bar"
}

# five_pct/five_reset/week_pct/week_reset/five_hour_present/week_present are
# already set by the combined stdin jq call near the top of the script.

# Run `date` for a unix epoch with the given format, GNU (-d) or BSD (-r) style.
epoch_date() {
  local epoch="$1" fmt="$2"
  date -d "@${epoch}" "$fmt" 2>/dev/null || date -r "${epoch}" "$fmt" 2>/dev/null
}

# Convert a unix epoch (seconds) to a human-readable local time like "3:45pm".
fmt_time() {
  local epoch="$1"
  [ -z "$epoch" ] && return
  epoch_date "$epoch" "+%l:%M%p" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//'
}

# Convert a unix epoch to a local time, prefixed with the date only if that
# date differs from today (e.g. "6:19am", or "Jul 11, 6:19am" if not today).
fmt_reset() {
  local epoch="$1"
  [ -z "$epoch" ] && return
  local reset_date today time_str
  reset_date=$(epoch_date "$epoch" "+%Y-%m-%d")
  # Unparseable epoch (both GNU -d and BSD -r failed, e.g. an ISO-8601
  # string instead of unix seconds): omit the reset time entirely, rather
  # than falling through to the not-today branch and rendering a
  # malformed "(resets , )" from two empty date/time strings.
  [ -z "$reset_date" ] && return
  today=$(date "+%Y-%m-%d" 2>/dev/null)
  time_str=$(fmt_time "$epoch")
  if [ "$reset_date" != "$today" ]; then
    printf '%s, %s' "$(epoch_date "$epoch" "+%b %e" | sed 's/  */ /g')" "$time_str"
  else
    printf '%s' "$time_str"
  fi
}

line1=()
line2=()
line3=()

if [ -n "$model" ]; then
  if [ -n "$effort" ]; then
    ecolor=$(effort_color "$effort")
    line1+=("$(printf '%s %b%s%b (%b%s%b)' "$(label model)" "$ORANGE" "$model" "$RESET" "$ecolor" "$effort" "$RESET")")
  else
    line1+=("$(printf '%s %b%s%b' "$(label model)" "$ORANGE" "$model" "$RESET")")
  fi
fi

if [ -n "$advisor" ]; then
  line1+=("$(printf '%s %b%s%b' "$(label advisor)" "$ORANGE" "$advisor" "$RESET")")
fi

if [ -n "$ctx_used" ]; then
  bar=$(render_bar "$ctx_used")
  if [ -n "$ctx_used_tokens" ] && [ -n "$ctx_total_tokens" ]; then
    used_fmt=$(fmt_tokens "$ctx_used_tokens")
    total_fmt=$(fmt_tokens "$ctx_total_tokens")
    line1+=("$(printf '%s %b%s%b/%b%s%b tokens %s %b%.0f%%%b used' "$(label context)" "$ORANGE" "$used_fmt" "$RESET" "$ORANGE" "$total_fmt" "$RESET" "$bar" "$ORANGE" "$ctx_used" "$RESET")")
  else
    line1+=("$(printf '%s %s %b%.0f%%%b used' "$(label context)" "$bar" "$ORANGE" "$ctx_used" "$RESET")")
  fi
else
  line1+=("$(label context) warming up")
fi

# "warming up" only if the rate_limits object exists but its percentage
# hasn't landed yet. If the object is absent (e.g. metered API-key billing
# has no rate limits at all), skip it so the row stays hidden instead of
# showing "warming up" forever.
if [ -n "$five_pct" ]; then
  reset_str=$(fmt_reset "$five_reset")
  if [ -n "$reset_str" ]; then
    line3+=("$(printf '%s %b%.0f%%%b used (resets %b%s%b)' "$(label rate_five)" "$ORANGE" "$five_pct" "$RESET" "$ORANGE" "$reset_str" "$RESET")")
  else
    line3+=("$(printf '%s %b%.0f%%%b used' "$(label rate_five)" "$ORANGE" "$five_pct" "$RESET")")
  fi
elif [ "$five_hour_present" = "true" ]; then
  line3+=("$(label rate_five) warming up")
fi

if [ -n "$week_pct" ]; then
  reset_str=$(fmt_reset "$week_reset")
  if [ -n "$reset_str" ]; then
    line3+=("$(printf '%s %b%.0f%%%b used (resets %b%s%b)' "$(label rate_week)" "$ORANGE" "$week_pct" "$RESET" "$ORANGE" "$reset_str" "$RESET")")
  else
    line3+=("$(printf '%s %b%.0f%%%b used' "$(label rate_week)" "$ORANGE" "$week_pct" "$RESET")")
  fi
elif [ "$week_present" = "true" ]; then
  line3+=("$(label rate_week) warming up")
fi

# Render one "label X.XX$" cost item, value+$ colored. label_text is already
# fully formed by label() (word + colon, or a bare icon in emoji mode).
cost_item() {
  local label_text="$1" value="$2"
  [ -z "$value" ] && return
  printf '%s %b%.2f$%b' "$label_text" "$ORANGE" "$value" "$RESET"
}

[ -n "$cost" ] && line2+=("$(cost_item "$(label cost_session)" "$cost")")
[ -n "$today_cost" ] && line2+=("$(cost_item "$(label cost_today)" "$today_cost")")
[ -n "$weekly_cost" ] && line2+=("$(cost_item "$(label cost_week)" "$weekly_cost")")
[ -n "$monthly_cost" ] && line2+=("$(cost_item "$(label cost_month)" "$monthly_cost")")
[ -n "$all_time_cost" ] && line2+=("$(cost_item "$(label cost_alltime)" "$all_time_cost")")

# Join segments (passed as positional args) with " | ". Avoids a bash
# nameref (introduced in 4.3), which macOS's bundled bash 3.2 does not
# support.
join_segments() {
  local out="" seg
  for seg in "$@"; do
    if [ -z "$out" ]; then out="$seg"; else out="$out | $seg"; fi
  done
  printf '%s' "$out"
}

[ "$show_model" = true ] && echo "$(join_segments "${line1[@]}")"
[ "$show_cost" = true ] && echo "$(join_segments "${line2[@]}")"
[ "$show_rate" = true ] && [ "${#line3[@]}" -gt 0 ] && echo "$(join_segments "${line3[@]}")"

# All three sections hidden -> print one empty line so the status line area
# stays reserved instead of vanishing entirely (no output at all).
if [ "$show_model" = false ] && [ "$show_cost" = false ] && [ "$show_rate" = false ]; then
  echo ""
fi
exit 0
