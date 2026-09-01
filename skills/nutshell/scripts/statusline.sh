#!/usr/bin/env bash
# Claude Code statusLine script
# Reads the statusLine JSON payload from stdin and prints a single summary line.
# All optional fields are omitted gracefully (no blank labels) when absent.

# Pin the locale for this script. Two things depend on it and both are
# wrong in some locales: `date +%p` is empty where the locale defines no
# am/pm strings, which silently drops it from the reset time, and a locale
# with a comma decimal separator makes bash's printf '%.2f' reject the
# dot-decimal numbers jq hands us. C is defined everywhere and formats
# both the way the rest of this script assumes.
LC_ALL=C
export LC_ALL

input=$(cat)

# One jq call instead of one per field. `// ""` not `// empty` (empty is a
# zero-output generator, would drop the whole array on a null field).
# Delimiter is \x1f, not @tsv's tab: `read` collapses consecutive tab/space
# delimiters even when IFS is set to just one of them, silently shifting
# fields whenever one is empty (routine: absent .effort, absent .cost).
# \x1f isn't IFS whitespace, so it doesn't collapse.
IFS=$'\x1f' read -r model effort ctx_used ctx_used_tokens ctx_total_tokens cost five_pct five_reset week_pct week_reset five_hour_present week_present ws_dir repo_owner repo_name rate_raw < <(
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
      (.rate_limits.seven_day != null),
      (.workspace.current_dir // .cwd // ""),
      (.workspace.repo.owner // ""),
      (.workspace.repo.name // ""),
      (.rate_limits // {})
    ] | map(tostring) | join("\u001f")' <<< "$input" 2>/dev/null
)
advisor_raw=$(jq -r '.advisorModel // empty' "$HOME/.claude/settings.json" 2>/dev/null)

# Alias -> display name. settings.json only stores the bare alias, no
# runtime lookup exists for the resolved name, so this WILL drift on new
# model releases (opus was "Opus 4.8", now "Opus 5" as of 2026-07; fable
# was "Fable 5", now "Fable 5.1" as of 2026-09, Claude Code 2.1.255+).
advisor_display_name() {
  case "$1" in
    fable) printf 'Fable 5.1' ;;
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
show_workspace=true
# Emoji mode — replaces text labels ("model:", "session:", ...) with icons.
# Fail CLOSED (default off): unlike show_*, a missing/bad key must not
# silently switch the status line to icons the user didn't ask for.
emoji_mode=false
if [ -f "$STATUSLINE_CONFIG_FILE" ]; then
  # Raw value, not `.key // "true"` (// treats false as empty, would hide
  # it). Missing key -> "null" text, so show_* stays shown (fail open),
  # emoji stays off (fail closed). Duplicated in statusline-toggle.sh's
  # get_part()/get_emoji(); keep both in sync by hand.
  IFS=$'\x1f' read -r cfg_model cfg_cost cfg_rate cfg_workspace cfg_emoji < <(
    jq -r '[(.model|tostring), (.cost|tostring), (.rate|tostring), (.workspace|tostring), (.emoji|tostring)] | join("\u001f")' "$STATUSLINE_CONFIG_FILE" 2>/dev/null
  )
  [ "$cfg_model" = "false" ] && show_model=false
  [ "$cfg_cost" = "false" ] && show_cost=false
  [ "$cfg_rate" = "false" ] && show_rate=false
  [ "$cfg_workspace" = "false" ] && show_workspace=false
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
# A timestamp in the future (clock skew, a machine that had its time fixed,
# a hand-edited cache) makes the age negative, which is always below the
# threshold, so the refresh would never fire and the stale costs would stay
# on screen until the wall clock caught up. Treat a future timestamp as
# stale: the refresh rewrites updated_at and the cache self-heals.
[ "$cache_age" -lt 0 ] && cache_age="$COST_CACHE_MAX_AGE"
# The ccusage check mirrors cost_cache_refresh.sh's own guard. Without it the
# refresher exits immediately, the cache never becomes fresh, and cache_age
# stays above the threshold forever, so every single render spawns a process
# that can only exit. Harmless at one spawn per assistant message, but
# settings.json now sets refreshInterval, putting renders on a 1s clock.
if [ "$show_cost" = true ] && [ "$cache_age" -ge "$COST_CACHE_MAX_AGE" ] \
   && command -v ccusage >/dev/null 2>&1; then
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
#
# Every icon here must be a SINGLE codepoint whose East Asian Width is W
# (wide). Do not use an emoji that needs a U+FE0F variation selector to
# reach its emoji form: the terminal measures the base codepoint, finds it
# Neutral width, reserves one cell, and the font then paints two, so the
# glyph overlaps whatever follows it. U+1F5D3 FE0F and U+267B FE0F both
# did this and were replaced. Verify a new icon before adding it with
# `python3 -c "import unicodedata as u; print(u.east_asian_width(C))"`,
# which must print W, and confirm the character is one codepoint.
label() {
  if [ "$emoji_mode" = true ]; then
    case "$1" in
      model)        printf '💡' ;;
      advisor)      printf '🎓' ;;
      context)      printf '⏳' ;;
      cost_session) printf '🪙' ;;
      cost_today)   printf '⛅' ;;
      cost_week)    printf '📅' ;;
      cost_month)   printf '🧾' ;;
      cost_alltime) printf '💳' ;;
      rate_five)    printf '🕐' ;;
      rate_week)    printf '🔄' ;;
      workspace)    printf '📂' ;;
      repo)         printf '🌐' ;;
      branch)       printf '🌿' ;;
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
      workspace)    printf 'workspace:' ;;
      repo)         printf 'repo:' ;;
      branch)       printf 'branch:' ;;
    esac
  fi
}

# Current branch, read straight out of .git instead of shelling out to git.
# The payload has no general branch field: worktree.branch exists only for
# --worktree sessions and is absent for hook-based worktrees, so there is
# nothing to read for an ordinary checkout. Parsing HEAD avoids forking a
# process once a second, and works on a machine with no git installed.
#
# Walks up from the starting directory the way git itself does, so it still
# reports the branch when the session's cwd is a subdirectory of the repo.
git_branch() {
  local dir="$1" gitdir="" head=""
  [ -n "$dir" ] || return
  while [ -n "$dir" ]; do
    if [ -d "$dir/.git" ]; then
      gitdir="$dir/.git"
      break
    fi
    # A linked worktree (git worktree add) has .git as a FILE holding
    # "gitdir: <path>", and that path is where HEAD actually lives.
    if [ -f "$dir/.git" ]; then
      gitdir=$(sed -n 's/^gitdir: //p' "$dir/.git" 2>/dev/null | head -1)
      break
    fi
    # ${dir%/*} returns the value UNCHANGED when it holds no slash, so a
    # slashless starting directory would spin here forever and hang the
    # render. Claude Code sends an absolute current_dir, so this is a guard
    # against a malformed payload rather than a path seen in practice.
    case "$dir" in
      */*) dir=${dir%/*} ;;
      *)   dir="" ;;
    esac
  done
  [ -n "$gitdir" ] && [ -r "$gitdir/HEAD" ] || return
  head=$(head -1 "$gitdir/HEAD" 2>/dev/null)
  case "$head" in
    'ref: refs/heads/'*) printf '%s' "${head#ref: refs/heads/}" ;;
    '') return ;;
    # Detached HEAD holds a bare SHA. Show it short, the way git log does.
    *) printf '%s' "$(printf '%s' "$head" | cut -c1-7)" ;;
  esac
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
line4=()

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

# A fresh session, and the window right after /compact, has no
# used_percentage and no total_input_tokens yet (both are documented as
# null / 0 before the first API response). context_window_size is not in
# that group: it comes from the selected model, so it is there from the
# first render. Treat the missing pair as a real zero and show 0% rather
# than a "warming up" placeholder, which said less than the number does.
[ -z "$ctx_used" ] && ctx_used=0
[ -z "$ctx_used_tokens" ] && ctx_used_tokens=0

bar=$(render_bar "$ctx_used")
if [ -n "$ctx_total_tokens" ]; then
  used_fmt=$(fmt_tokens "$ctx_used_tokens")
  total_fmt=$(fmt_tokens "$ctx_total_tokens")
  line1+=("$(printf '%s %b%s%b/%b%s%b tokens %s %b%.0f%%%b used' "$(label context)" "$ORANGE" "$used_fmt" "$RESET" "$ORANGE" "$total_fmt" "$RESET" "$bar" "$ORANGE" "$ctx_used" "$RESET")")
else
  line1+=("$(printf '%s %s %b%.0f%%%b used' "$(label context)" "$bar" "$ORANGE" "$ctx_used" "$RESET")")
fi

# Which rate windows this account has. The payload carries rate_limits only
# for a Claude.ai subscription (Pro, Max, Team, Enterprise) and only after
# the session's first API response, and each window can be absent on its
# own: a Team seat observed so far has five_hour with no seven_day. Metered
# billing (API key, Bedrock, Vertex, Foundry) never gets the object at all,
# and a 0% row there is a lie, so those windows are omitted rather than
# zeroed. Two sources decide, and the payload always wins:
#
#  1. `claude auth status` (JSON, documented) reports subscriptionType as
#     a string on a subscription and null on metered billing. It costs
#     ~170ms, far too slow for a 1s render, so it runs in the background
#     and lands in ~/.claude/.auth_cache.json, refreshed every
#     AUTH_CACHE_MAX_AGE seconds. Values seen: "max"; null under
#     ANTHROPIC_API_KEY; the key is absent entirely under Bedrock. Team
#     and Enterprise strings are unobserved, so the rule is "string vs
#     null", never a plan-name table. A subscriber who also exports
#     ANTHROPIC_API_KEY but declined it in /config reads as null here
#     while still drawing on the subscription; the payload override
#     below covers that after the first response.
#  2. Which windows the plan actually has is learned by observation, not
#     looked up: every window that has ever been live is recorded in the
#     shared rate cache under `seen`, keyed by subscriptionType so a plan
#     change relearns from scratch. A window that is absent after this
#     session's first response, and was never seen on this plan, is one
#     the plan does not have. cost.total_cost_usd > 0 is the
#     first-response signal: it survives /compact and resets only on
#     /clear, whereas total_input_tokens resets on compact.
#
# Per window: live (payload or cache) -> show; auth says metered -> omit;
# seen before on this plan -> 0% while waiting; never seen while some other
# window has been, or never seen and this session has had a response ->
# omit; otherwise (nothing learned yet and no response yet) -> 0%, fail
# open like every other part.
# The reset time stays optional: fmt_reset returns empty for an absent or
# unparseable resets_at, and that branch drops the "(resets ...)" part.
#
# five_hour_present / week_present from the top jq call are superseded by
# the `seen` bookkeeping and are kept only so the field list stays stable.
AUTH_CACHE_FILE="$HOME/.claude/.auth_cache.json"
AUTH_CACHE_MAX_AGE=600
# auth_plan: "" = unknown (no cache, unreadable, or no subscription_type
# key), "none" = metered billing, anything else = the subscriptionType
# string. "none" cannot collide with a real plan name that jq would have
# emitted as-is, because a null subscriptionType is mapped to it explicitly.
auth_plan=""
auth_updated_at=0
if [ "$show_rate" = true ] && [ -f "$AUTH_CACHE_FILE" ]; then
  IFS=$'\x1f' read -r auth_plan auth_updated_at < <(
    jq -r 'select(type == "object") | [
        (if has("subscription_type") then (.subscription_type // "none") else "" end),
        (.updated_at // 0)
      ] | map(tostring) | join("\u001f")' "$AUTH_CACHE_FILE" 2>/dev/null
  )
fi
case "$auth_updated_at" in
  ''|*[!0-9]*) auth_updated_at=0 ;;
esac
auth_age=$(( $(date +%s) - auth_updated_at ))
[ "$auth_age" -lt 0 ] && auth_age="$AUTH_CACHE_MAX_AGE"
# Refresh in the background, same shape as the cost refresher: never on the
# render path, only when the rate row is shown, only when `claude` is on
# PATH (a missing binary just leaves the cache unknown, which fails open).
# The lock keeps five idle sessions from each spawning their own probe in
# the same second; where flock is missing the worst case is a few redundant
# 170ms processes. `timeout` guards a hung probe where it exists, and is
# skipped where it does not.
#
# A failed probe (non-zero exit, timeout, non-JSON output, or an older
# Claude Code with no `auth status` subcommand at all) still bumps
# updated_at, keeping whatever subscription_type the cache already held.
# Without that, a persistently failing probe would leave the cache stale
# forever and this block would fork `claude` again on every 1s render, the
# same storm the ccusage guard above exists to prevent. Keeping the old
# verdict means a transient error never turns a known plan into an
# unknown one; a cache that never had a verdict stays unknown and fails
# open.
if [ "$show_rate" = true ] && [ "$auth_age" -ge "$AUTH_CACHE_MAX_AGE" ] \
   && command -v claude >/dev/null 2>&1; then
  ( nohup bash -c '
      f="$1"
      if command -v flock >/dev/null 2>&1 && exec 9>"$f.lock" 2>/dev/null; then
        flock -n 9 || exit 0
      fi
      now=$(date +%s)
      if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 15 claude auth status 2>/dev/null) || out=""
      else
        out=$(claude auth status 2>/dev/null) || out=""
      fi
      new=""
      [ -n "$out" ] && new=$(printf "%s" "$out" | jq -c --argjson now "$now" \
        "select(type == \"object\") | {subscription_type: (.subscriptionType // null), updated_at: \$now}" 2>/dev/null)
      if [ -z "$new" ]; then
        new=$(jq -c --argjson now "$now" "select(type == \"object\") | .updated_at = \$now" "$f" 2>/dev/null)
        [ -n "$new" ] || new="{\"updated_at\":$now}"
      fi
      tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || exit 0
      printf "%s" "$new" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
    ' auth-refresh "$AUTH_CACHE_FILE" >/dev/null 2>&1 & disown ) 2>/dev/null
fi

# First-response signal for the "never seen" rule above. Any positive
# session cost means at least one API response has landed. awk, not a
# glob: "0.0123" must count, and a plain `case` on the string cannot tell
# it from "0.0".
responded=$(awk -v c="$cost" 'BEGIN { print (c + 0 > 0) ? "true" : "false" }')

# Rate limits are PER-SESSION payload state: Claude Code only refreshes them
# from this session's own API responses, and refreshInterval re-running the
# script cannot make it recompute the payload. An idle tab therefore freezes
# at whatever it last saw. Measured across five concurrent sessions, the idle
# ones sat 20 minutes behind the active one, showing both a stale percentage
# and a stale reset time. Cost never had this problem because it reads a
# SHARED on-disk cache, so rate now gets the same treatment: every session
# publishes the freshest reading it has, and renders the freshest reading any
# session has published. The limits are account-wide, so the newest reading
# from any session is the best estimate for all of them.
#
# Freshness is ordered by (resets_at, used_percentage), both "higher is
# fresher", and deliberately NOT by a wall-clock stamp. The payload carries no
# indication of when it was measured, so stamping it with `now` would let a
# stale idle tab overwrite a fresh reading. resets_at advances when the
# rolling window moves, and within one window used_percentage only ever grows,
# so the pair orders two readings correctly with no timestamp at all.
#
# Skipped entirely when the rate line is hidden: that session neither reads
# nor writes the cache, and any session still showing the line maintains it.
RATE_CACHE_FILE="$HOME/.claude/.rate_cache.json"
if [ "$show_rate" = true ]; then
  # Missing, empty, unreadable or non-object cache reads as no cache at all,
  # never as a reason to lose the payload's own numbers.
  rate_cache=$(jq -ce 'select(type == "object")' "$RATE_CACHE_FILE" 2>/dev/null) || rate_cache='{}'
  [ -n "$rate_cache" ] || rate_cache='{}'
  case "$rate_raw" in ''|null) rate_raw='{}' ;; esac

  # The cache also carries `seen`: {plan, windows}, the windows that have
  # ever been live on the current plan (see the auth cache comment above).
  # It is bookkeeping for the show/omit decision, not a reading, and an
  # older statusline.sh that only knows the window keys ignores it.
  IFS=$'\x1f' read -r five_show five_pct five_reset week_show week_pct week_reset rate_new < <(
    jq -nr --argjson now "$(date +%s)" --argjson p "$rate_raw" --argjson c "$rate_cache" \
       --arg plan "$auth_plan" --argjson responded "$responded" '
      # Keep only a window that carries a usable numeric resets_at.
      def clean($o):
        if ($o | type) == "object" and ($o.resets_at | type) == "number"
        then {used_percentage: (($o.used_percentage | numbers) // 0), resets_at: $o.resets_at}
        else null end;
      def fresher($a; $b):
        if $a == null then $b
        elif $b == null then $a
        elif [$a.resets_at, $a.used_percentage] >= [$b.resets_at, $b.used_percentage] then $a
        else $b end;
      def pick($w): fresher(clean($p[$w]); clean($c[$w]));
      # A window whose resets_at has passed has rolled over, which is also the
      # moment Claude Code drops it from the payload. Discard it so the line
      # falls back to a truthful 0% with no reset time, rather than carrying a
      # percentage that is known to be wrong, and drop it from the cache too.
      def live($w): pick($w) | if . != null and .resets_at > $now then . else null end;
      live("five_hour") as $f | live("seven_day") as $s |
      # Windows seen on this plan: what the cache remembers, if it was
      # recorded under the same plan, plus whatever is live right now.
      (($c.seen | objects) // {}) as $seen |
      (if ($seen.plan // "") == $plan then (($seen.windows | arrays) // []) else [] end
        + (if $f == null then [] else ["five_hour"] end)
        + (if $s == null then [] else ["seven_day"] end)
        | unique) as $windows |
      # Show/omit per window. Order matters: a live reading is shown no
      # matter what the auth probe said, so a false "metered" verdict can
      # only ever cost the pre-first-response 0%, never a real number.
      # Once any window has been seen on this plan the plan is known, and
      # a window missing from that set stays omitted even before the first
      # response, so a Team seat does not flash a weekly 0% at every start.
      def show($w; $v):
        if $v != null then true
        elif $plan == "none" then false
        elif ($windows | index($w)) != null then true
        elif ($windows | length) > 0 then false
        elif $responded then false
        else true end;
      ( (if $f == null then {} else {five_hour: $f} end)
        + (if $s == null then {} else {seven_day: $s} end)
        + (if ($windows | length) == 0 then {} else {seen: {plan: $plan, windows: $windows}} end)
      ) as $merged |
      [ show("five_hour"; $f), ($f.used_percentage // ""), ($f.resets_at // ""),
        show("seven_day"; $s), ($s.used_percentage // ""), ($s.resets_at // ""),
        ($merged | tojson) ] | map(tostring) | join("\u001f")
    ' 2>/dev/null
  )

  # Publish only on a real change, so the common case (five idle sessions
  # re-rendering once a second) does no disk writes at all. Same-directory
  # mktemp + mv, since several sessions read this file concurrently and a
  # torn read would drop the rate line's numbers.
  if [ -n "$rate_new" ] && [ "$rate_new" != "$rate_cache" ]; then
    rate_tmp=$(mktemp "$RATE_CACHE_FILE.XXXXXX" 2>/dev/null)
    if [ -n "$rate_tmp" ]; then
      printf '%s' "$rate_new" > "$rate_tmp" 2>/dev/null \
        && mv "$rate_tmp" "$RATE_CACHE_FILE" 2>/dev/null \
        || rm -f "$rate_tmp" 2>/dev/null
    fi
  fi
fi

[ -z "$five_pct" ] && five_pct=0
[ -z "$week_pct" ] && week_pct=0

# A window whose show flag is not exactly "true" (the jq call failed, or the
# rate part is hidden and the call never ran) falls back to the old
# always-render behaviour, so a broken cache can hide nothing. An omitted
# segment simply never lands in line3; when both are omitted the row is
# dropped by the same empty-array check every other row uses.
render_rate_window() {
  local key="$1" pct="$2" reset="$3" reset_str
  reset_str=$(fmt_reset "$reset")
  if [ -n "$reset_str" ]; then
    printf '%s %b%.0f%%%b used (resets %b%s%b)' "$(label "$key")" "$ORANGE" "$pct" "$RESET" "$ORANGE" "$reset_str" "$RESET"
  else
    printf '%s %b%.0f%%%b used' "$(label "$key")" "$ORANGE" "$pct" "$RESET"
  fi
}

[ "$five_show" != false ] && line3+=("$(render_rate_window rate_five "$five_pct" "$five_reset")")
[ "$week_show" != false ] && line3+=("$(render_rate_window rate_week "$week_pct" "$week_reset")")

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

# Location row: where the session is, which repo it belongs to, and the
# branch. Each segment is independent, so a directory outside any git repo
# still shows its path, and a repo with no origin remote still shows its
# branch. repo.* comes from the origin remote and is absent without one.
if [ -n "$ws_dir" ]; then
  # $HOME/x -> ~/x via case matching rather than sed, since a home path can
  # contain characters that are regex metacharacters.
  case "$ws_dir" in
    "$HOME")   ws_display="~" ;;
    "$HOME"/*) ws_display="~${ws_dir#"$HOME"}" ;;
    *)         ws_display="$ws_dir" ;;
  esac
  line4+=("$(printf '%s %b%s%b' "$(label workspace)" "$ORANGE" "$ws_display" "$RESET")")
fi

repo_display=""
if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
  repo_display="$repo_owner/$repo_name"
elif [ -n "$repo_name" ]; then
  repo_display="$repo_name"
fi
[ -n "$repo_display" ] && line4+=("$(printf '%s %b%s%b' "$(label repo)" "$ORANGE" "$repo_display" "$RESET")")

branch=$(git_branch "$ws_dir")
[ -n "$branch" ] && line4+=("$(printf '%s %b%s%b' "$(label branch)" "$ORANGE" "$branch" "$RESET")")

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
[ "$show_cost" = true ] && [ "${#line2[@]}" -gt 0 ] && echo "$(join_segments "${line2[@]}")"
[ "$show_rate" = true ] && [ "${#line3[@]}" -gt 0 ] && echo "$(join_segments "${line3[@]}")"
[ "$show_workspace" = true ] && [ "${#line4[@]}" -gt 0 ] && echo "$(join_segments "${line4[@]}")"

# Every section hidden -> print one empty line so the status line area
# stays reserved instead of vanishing entirely (no output at all).
if [ "$show_model" = false ] && [ "$show_cost" = false ] && [ "$show_rate" = false ] \
   && [ "$show_workspace" = false ]; then
  echo ""
fi
exit 0
