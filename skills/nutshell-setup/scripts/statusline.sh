#!/usr/bin/env bash
# statusline.sh: the Claude Code statusLine command.
#
# Reads the statusLine JSON payload from stdin and prints up to four lines:
#   1  model / effort / advisor / context bar   (always shown)
#   2  cost: current session / today / week / month / all-time
#   3  rate limits: current 5-hour window / current week
#   4  workspace: directory / repo / branch
# A line is dropped when it has nothing to say, and lines 2-4 can each be
# hidden through config.json (statusline-toggle.sh). Every optional field
# is omitted gracefully, never rendered as a blank label.
#
# Freshness, the one thing to understand about this script: Claude Code
# re-runs it once a second (refreshInterval) but does NOT recompute the
# payload. Advisor and cost are read from disk, so the timer alone keeps
# them current. rate_limits is per-session payload state that Claude Code
# refreshes only from that session's own API responses, so an idle tab
# would freeze at its last reading; the shared rate cache below fixes that.
# Anything slow (ccusage, `claude auth status`) runs in a background script
# and lands in a cache this script only reads.

case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
. "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null || exit 0
nut_ensure_dirs

COST_CACHE_MAX_AGE=300
AUTH_CACHE_MAX_AGE=300

ORANGE='\033[38;2;217;119;87m'
GRAY='\033[38;5;240m'
RESET='\033[0m'
# Font-only colors matching the /effort picker's per-level colors.
EFFORT_LOW='\033[38;2;230;180;40m'      # low = warning (yellow)
EFFORT_MEDIUM='\033[38;2;80;200;120m'   # medium = success (green)
EFFORT_HIGH='\033[38;2;177;185;249m'    # high = permission (periwinkle)
EFFORT_XHIGH='\033[38;2;185;150;235m'   # xhigh = lavender
EFFORT_MAX="$ORANGE"                    # max = Claude brand color (same as context bar)

# ---------------------------------------------------------------------------
# Formatting helpers (pure: arguments in, text out)
# ---------------------------------------------------------------------------

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

# Alias -> display name. settings.json only stores the bare alias and no
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

# Field label: word ("model:") or icon ("💡") depending on emoji_mode.
#
# Every icon must be a SINGLE codepoint whose East Asian Width is W (wide).
# Never one that needs a U+FE0F variation selector to reach its emoji form:
# the terminal measures the base codepoint, finds it Neutral, reserves one
# cell, and the font paints two, so the glyph overlaps what follows.
# U+1F5D3 FE0F and U+267B FE0F both did this and were replaced. Check a new
# icon with `python3 -c "import unicodedata as u; print(u.east_asian_width(C))"`,
# which must print W, and confirm it is one codepoint.
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
      cost_session) printf 'current session:' ;;
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

# Format a raw token count: 51800 -> "51.8k", 1000000 -> "1.0m", under 1000 as-is.
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

# Colored block bar for a percentage (0-100), e.g. "[███░░░░░░░]".
render_bar() {
  local pct="$1" width=10 filled empty bar i
  [ -z "$pct" ] && return
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { f = int((p/100)*w + 0.5); if (f > w) f = w; if (f < 0) f = 0; print f }')
  empty=$((width - filled))
  bar="[${ORANGE}"
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  bar+="${RESET}${GRAY}"
  for ((i = 0; i < empty; i++)); do bar+="░"; done
  bar+="${RESET}]"
  printf '%b' "$bar"
}

# `date` for a unix epoch with the given format, GNU (-d) or BSD (-r) style.
epoch_date() {
  date -d "@${1}" "$2" 2>/dev/null || date -r "${1}" "$2" 2>/dev/null
}

# Unix epoch -> local time like "3:45pm".
fmt_time() {
  [ -z "$1" ] && return
  epoch_date "$1" "+%l:%M%p" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//'
}

# Unix epoch -> local time, prefixed with the date only when it is not today
# ("6:19am", or "Jul 11, 6:19am"). An unparseable epoch (both date flavours
# failed, e.g. an ISO-8601 string) yields nothing, so the caller drops the
# "(resets ...)" part instead of rendering "(resets , )".
fmt_reset() {
  local epoch="$1" reset_date today time_str
  [ -z "$epoch" ] && return
  reset_date=$(epoch_date "$epoch" "+%Y-%m-%d")
  [ -z "$reset_date" ] && return
  today=$(date "+%Y-%m-%d" 2>/dev/null)
  time_str=$(fmt_time "$epoch")
  if [ "$reset_date" != "$today" ]; then
    printf '%s, %s' "$(epoch_date "$epoch" "+%b %e" | sed 's/  */ /g')" "$time_str"
  else
    printf '%s' "$time_str"
  fi
}

# Current branch, read straight out of .git rather than by shelling out to
# git: the payload has no general branch field (worktree.branch exists only
# for --worktree sessions), parsing HEAD avoids a fork once a second, and it
# works on a machine with no git installed. Walks up from the starting
# directory the way git does, so a subdirectory of the repo still reports
# the branch.
git_branch() {
  local dir="$1" gitdir="" head=""
  [ -n "$dir" ] || return
  while [ -n "$dir" ]; do
    if [ -d "$dir/.git" ]; then
      gitdir="$dir/.git"
      break
    fi
    # A linked worktree has .git as a FILE holding "gitdir: <path>", and
    # that path is where HEAD actually lives.
    if [ -f "$dir/.git" ]; then
      gitdir=$(sed -n 's/^gitdir: //p' "$dir/.git" 2>/dev/null | head -1)
      break
    fi
    # ${dir%/*} returns the value UNCHANGED when it holds no slash, so a
    # slashless start would spin forever and hang the render. Claude Code
    # sends an absolute path; this guards a malformed payload.
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

# One "label X.XX$" cost item, value and $ colored. Nothing for an empty value.
cost_item() {
  local label_text="$1" value="$2"
  [ -z "$value" ] && return
  printf '%s %b%.2f$%b' "$label_text" "$ORANGE" "$value" "$RESET"
}

# One rate window, with the reset time when fmt_reset can produce one.
render_rate_window() {
  local key="$1" pct="$2" reset="$3" reset_str
  reset_str=$(fmt_reset "$reset")
  if [ -n "$reset_str" ]; then
    printf '%s %b%.0f%%%b used (resets %b%s%b)' "$(label "$key")" "$ORANGE" "$pct" "$RESET" "$ORANGE" "$reset_str" "$RESET"
  else
    printf '%s %b%.0f%%%b used' "$(label "$key")" "$ORANGE" "$pct" "$RESET"
  fi
}

# Join the positional arguments with " | ". No bash nameref (4.3+), which
# macOS's bundled bash 3.2 does not have.
join_segments() {
  local out="" seg
  for seg in "$@"; do
    if [ -z "$out" ]; then out="$seg"; else out="$out | $seg"; fi
  done
  printf '%s' "$out"
}

# $1 when it is a non-negative integer, else 0. A cache that is missing,
# invalid or hand-edited leaves a timestamp empty or non-numeric (jq -r
# prints nothing on a parse error); 0 keeps the age arithmetic valid and
# makes the age huge, which is the right answer for a broken cache.
as_epoch() {
  case "$1" in
    ''|*[!0-9]*) printf 0 ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

# The stdin payload, one jq call for every field. `// ""` not `// empty`
# (empty is a zero-output generator and would drop the whole array on a null
# field). The delimiter is \x1f, not @tsv's tab: `read` collapses
# consecutive tab/space delimiters even when IFS is set to just one of them,
# silently shifting fields whenever one is empty (routine: absent .effort,
# absent .cost). \x1f is not IFS whitespace, so it does not collapse.
read_payload() {
  local input
  input=$(cat)
  IFS=$'\x1f' read -r model effort ctx_used ctx_used_tokens ctx_total_tokens cost session_id \
      five_pct five_reset week_pct week_reset five_hour_present week_present \
      ws_dir repo_owner repo_name rate_raw < <(
    jq -r '[
        (.model.display_name // ""),
        (.effort.level // ""),
        (.context_window.used_percentage // ""),
        (.context_window.total_input_tokens // ""),
        (.context_window.context_window_size // ""),
        (.cost.total_cost_usd // ""),
        (.session_id // ""),
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
  # rate_raw is the whole rate_limits object, or "{}" when absent.
  case "$rate_raw" in ''|null) rate_raw='{}' ;; esac
}

# The advisor model is not in the payload and switching it is not a
# refresh trigger, so settings.json is the only source and the 1s timer the
# only way to notice a change.
read_advisor() {
  local raw
  raw=$(jq -r '.advisorModel // empty' "$NUT_SETTINGS" 2>/dev/null)
  advisor=""
  [ -n "$raw" ] && advisor=$(advisor_display_name "$raw")
}

# Part visibility from config.json. Fail open: a missing file, missing key
# or bad value means the part is shown, so the status line never silently
# goes blank. Emoji fails CLOSED (default off): a missing or bad key must
# not switch the labels to icons the user did not ask for.
#
# Raw values, not `.key // true`: jq's // treats false as empty and would
# un-hide a hidden part. A missing key reads "null", so the defaults hold.
# The session part falls back to its pre-v0.3.0 key "rate" via has(), not
# `//`, for the same reason; statusline-toggle.sh migrates the key on its
# next run.
#
# The model part is read but not acted on: it is pinned on, so line 1
# always renders and the row can never collapse to nothing (the statusLine
# key stays registered while parts are merely hidden, and Claude Code keeps
# its own footer hints suppressed, so the user would see nothing at all).
#
# Sets disabled=true when the user handed the row back to Claude Code with
# `statusline-toggle.sh off`. The caller must then exit before any output
# and before any background spawn: if Claude Code does not act on the
# deleted statusLine key mid-session, a session that already holds the
# registration keeps invoking this script once a second, and without the
# early exit the cost refresher and the auth probe would keep running for a
# row the user asked to hand back. Inactive has to mean no tracking, not
# just no display.
read_config() {
  local cfg_model cfg_cost cfg_session cfg_workspace cfg_emoji cfg_disabled
  show_cost=true
  show_rate=true
  show_workspace=true
  emoji_mode=false
  disabled=false
  [ -f "$NUT_CONFIG" ] || return 0
  IFS=$'\x1f' read -r cfg_model cfg_cost cfg_session cfg_workspace cfg_emoji cfg_disabled < <(
    jq -r '[(.model|tostring), (.cost|tostring), (if has("session") then .session else .rate end|tostring), (.workspace|tostring), (.emoji|tostring), (.disabled|tostring)] | join("\u001f")' "$NUT_CONFIG" 2>/dev/null
  )
  [ "$cfg_disabled" = "true" ] && disabled=true
  [ "$cfg_cost" = "false" ] && show_cost=false
  [ "$cfg_session" = "false" ] && show_rate=false
  [ "$cfg_workspace" = "false" ] && show_workspace=false
  [ "$cfg_emoji" = "true" ] && emoji_mode=true
  return 0
}

# ---------------------------------------------------------------------------
# Cost (line 2): a background-refreshed cache, since ccusage takes seconds
# ---------------------------------------------------------------------------

# Each window is recomputed from the real calendar on every refresh, so they
# roll over on their own (today at midnight, weekly on Sunday, monthly on
# the 1st). Spawns the refresher when the cache is older than
# COST_CACHE_MAX_AGE, missing, unparseable, or stamped in the future (clock
# skew would otherwise make the age negative, always below the threshold,
# and the stale numbers would stay until the wall clock caught up). The
# ccusage check mirrors the refresher's own guard: without it every 1s
# render would fork a process that can only exit.
read_cost_cache() {
  local cache_updated_at=0 cache_age
  today_cost=""
  weekly_cost=""
  monthly_cost=""
  all_time_cost=""
  if [ -f "$NUT_COST_CACHE" ]; then
    IFS=$'\x1f' read -r today_cost weekly_cost monthly_cost all_time_cost cache_updated_at < <(
      jq -r '[(.today_cost // ""), (.weekly_cost // ""), (.monthly_cost // ""), (.all_time_cost // ""), (.updated_at // 0)] | map(tostring) | join("\u001f")' "$NUT_COST_CACHE" 2>/dev/null
    )
  fi
  cache_updated_at=$(as_epoch "$cache_updated_at")
  cache_age=$(( $(date +%s) - cache_updated_at ))
  [ "$cache_age" -lt 0 ] && cache_age="$COST_CACHE_MAX_AGE"
  if [ "$show_cost" = true ] && [ "$cache_age" -ge "$COST_CACHE_MAX_AGE" ] \
     && command -v ccusage >/dev/null 2>&1; then
    nut_spawn bash "$NUT_BIN_DIR/cost_cache_refresh.sh"
  fi
}

# ---------------------------------------------------------------------------
# Auth verdict: subscription or metered billing, per session
# ---------------------------------------------------------------------------

# Which rate windows an account has is decided by two sources, and the
# payload always wins:
#
#  1. `claude auth status`, probed in the background by auth_cache_refresh.sh
#     and cached per session. It reports subscriptionType as a string on a
#     subscription and null on metered billing (the key is absent under
#     Bedrock). Team and Enterprise strings are unobserved, so the rule is
#     "string vs null", never a plan-name table. A subscriber who also
#     exports ANTHROPIC_API_KEY but declined it in /config reads as null
#     here while still drawing on the subscription; the payload override in
#     the rate block covers that after the first response.
#  2. Which windows the plan actually has is learned by observation: every
#     window that has ever been live is recorded in the rate cache under
#     `seen`, keyed by plan (a Team seat observed with five_hour and no
#     seven_day).
#
# auth_plan: "" = unknown (no cache, unreadable, or no subscription_type
# key), "none" = metered billing, anything else = the subscriptionType
# string. "none" cannot collide with a real plan name, since a null
# subscriptionType is mapped to it explicitly.
read_auth_verdict() {
  local auth_updated_at=0 auth_sig="" auth_cred_mtime
  auth_plan=""
  auth_age="$AUTH_CACHE_MAX_AGE"
  if [ "$show_rate" = true ] && [ -n "$session_id" ] && [ -f "$NUT_AUTH_CACHE" ]; then
    IFS=$'\x1f' read -r auth_plan auth_updated_at auth_sig < <(
      jq -r --arg s "$session_id" 'select(type == "object") | (.sessions[$s]? | objects) // {} | [
          (if has("subscription_type") then (.subscription_type // "none") else "" end),
          (.updated_at // 0),
          (.sig // "")
        ] | map(tostring) | join("\u001f")' "$NUT_AUTH_CACHE" 2>/dev/null
    )
  fi
  # A launcher that points this session at a non-Anthropic endpoint exports
  # one of these (that is how such a session gets its credentials at all),
  # so they settle "metered" for the render or two before the probe lands,
  # which would otherwise fail open and flash another account's numbers.
  # Only consulted while the probe has said nothing: a real verdict wins.
  if [ -z "$auth_plan" ] && { [ -n "${ANTHROPIC_BASE_URL:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
    || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] \
    || [ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]; }; then
    auth_plan=none
  fi
  auth_updated_at=$(as_epoch "$auth_updated_at")
  auth_age=$(( $(date +%s) - auth_updated_at ))
  [ "$auth_age" -lt 0 ] && auth_age="$AUTH_CACHE_MAX_AGE"
  # Two things beside age make a verdict stale, and both force a re-probe
  # rather than waiting out AUTH_CACHE_MAX_AGE:
  #  - .credentials.json's mtime moved since the probe: every /login, logout
  #    and account switch rewrites it (a token refresh too, which costs one
  #    extra probe). A macOS install keeping credentials in the Keychain has
  #    no such file, so there the age check is the only trigger.
  #  - the verdict says metered while the payload carries rate_limits, which
  #    only an account with limits ever gets, so the verdict is provably wrong.
  if [ -n "$auth_plan" ]; then
    auth_cred_mtime=$(nut_mtime "$NUT_CREDENTIALS")
    if [ "$auth_sig" != "$auth_cred_mtime" ]; then
      auth_age="$AUTH_CACHE_MAX_AGE"
    elif [ "$auth_plan" = none ] && [ "$rate_raw" != '{}' ]; then
      auth_age="$AUTH_CACHE_MAX_AGE"
    fi
  fi
}

# Re-probe in the background, same shape as the cost refresher: never on the
# render path, only when the session row is shown, only when `claude` is on
# PATH (a missing binary leaves the verdict unknown, which fails open).
spawn_auth_probe_if_stale() {
  if [ "$show_rate" = true ] && [ -n "$session_id" ] && [ "$auth_age" -ge "$AUTH_CACHE_MAX_AGE" ] \
     && command -v claude >/dev/null 2>&1; then
    nut_spawn bash "$NUT_BIN_DIR/auth_cache_refresh.sh" "$session_id"
  fi
}

# ---------------------------------------------------------------------------
# Rate limits (line 3): the payload merged with a shared cache
# ---------------------------------------------------------------------------

# Rate limits are PER-SESSION payload state, refreshed only from this
# session's own API responses, so an idle tab freezes at whatever it last
# saw (measured across five concurrent sessions: the idle ones sat 20
# minutes behind). The limits are account-wide, so every session publishes
# the freshest reading it has and renders the freshest reading any session
# has published, the way cost has always read a shared cache.
#
# Freshness is ordered by (resets_at, used_percentage), both "higher is
# fresher", and deliberately NOT by a wall-clock stamp: the payload carries
# no indication of when it was measured, so stamping it with `now` would let
# a stale idle tab overwrite a fresh reading. resets_at advances when the
# rolling window moves, and within one window used_percentage only grows.
#
# A metered session takes no part in the cache, neither reading nor writing.
# Sharing is only sound between sessions on the same account: an API-key or
# gateway tab reading the cache would render someone else's percentages
# (and a live reading outranks the auth verdict below, however confidently
# the probe said "metered"), and publishing its empty reading once a second
# would blank the line in the subscription tab. Its own payload still
# renders, so a gateway that does report limits is unaffected.
#
# Skipped entirely when the session line is hidden: that session neither
# reads nor writes the cache, and any session still showing the line
# maintains it.
resolve_rate_windows() {
  local rate_cache rate_new responded
  five_show=""
  week_show=""
  [ "$show_rate" = true ] || return 0

  if [ "$auth_plan" = none ]; then
    rate_cache='{}'
  else
    # Missing, empty, unreadable or non-object reads as no cache at all,
    # never as a reason to lose the payload's own numbers.
    rate_cache=$(jq -ce 'select(type == "object")' "$NUT_RATE_CACHE" 2>/dev/null) || rate_cache='{}'
    [ -n "$rate_cache" ] || rate_cache='{}'
  fi

  # First-response signal for the "never seen" rule below: any positive
  # session cost means at least one API response has landed. It survives
  # /compact and resets only on /clear, whereas total_input_tokens resets on
  # compact. awk, not a glob: "0.0123" must count, and a `case` on the
  # string cannot tell it from "0.0".
  responded=$(awk -v c="$cost" 'BEGIN { print (c + 0 > 0) ? "true" : "false" }')

  # Per window: live (payload or cache) -> show; auth says metered -> omit;
  # seen before on this plan -> 0% while waiting; never seen while some
  # other window has been, or never seen and this session has had a
  # response -> omit; otherwise (nothing learned yet, no response yet) ->
  # 0%, fail open like every other part. A window whose resets_at has passed
  # has rolled over (also the moment Claude Code drops it from the payload),
  # so it is discarded from the render and the cache alike rather than
  # carrying a percentage known to be wrong.
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
  # re-rendering once a second) does no disk writes at all.
  if [ -n "$rate_new" ] && [ "$rate_new" != "$rate_cache" ] && [ "$auth_plan" != none ]; then
    nut_write_atomic "$rate_new" "$NUT_RATE_CACHE"
  fi
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

build_line1() {
  local ecolor bar used_fmt total_fmt
  line1=()
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
  # used_percentage and no total_input_tokens yet (both documented as null
  # or 0 before the first API response). context_window_size comes from the
  # selected model, so it is there from the first render. Treat the missing
  # pair as a real zero and show 0% rather than a "warming up" placeholder.
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
}

build_line2() {
  line2=()
  [ -n "$cost" ] && line2+=("$(cost_item "$(label cost_session)" "$cost")")
  [ -n "$today_cost" ] && line2+=("$(cost_item "$(label cost_today)" "$today_cost")")
  [ -n "$weekly_cost" ] && line2+=("$(cost_item "$(label cost_week)" "$weekly_cost")")
  [ -n "$monthly_cost" ] && line2+=("$(cost_item "$(label cost_month)" "$monthly_cost")")
  [ -n "$all_time_cost" ] && line2+=("$(cost_item "$(label cost_alltime)" "$all_time_cost")")
}

# A window whose show flag is not exactly "false" renders (the jq call
# failed, or the session part is hidden and it never ran), so a broken cache
# can hide nothing. An omitted window never lands in line3; with both
# omitted the row is dropped by the same empty-array check as every row.
build_line3() {
  line3=()
  [ -z "$five_pct" ] && five_pct=0
  [ -z "$week_pct" ] && week_pct=0
  [ "$five_show" != false ] && line3+=("$(render_rate_window rate_five "$five_pct" "$five_reset")")
  [ "$week_show" != false ] && line3+=("$(render_rate_window rate_week "$week_pct" "$week_reset")")
}

# Where the session is, which repo, which branch. Each segment is
# independent: a directory outside any repo still shows its path, and a
# repo with no origin remote still shows its branch (repo.* comes from the
# origin remote and is absent without one).
build_line4() {
  local ws_display repo_display="" branch
  line4=()
  if [ -n "$ws_dir" ]; then
    # $HOME/x -> ~/x via case matching rather than sed, since a home path
    # can contain regex metacharacters.
    case "$ws_dir" in
      "$HOME")   ws_display="~" ;;
      "$HOME"/*) ws_display="~${ws_dir#"$HOME"}" ;;
      *)         ws_display="$ws_dir" ;;
    esac
    line4+=("$(printf '%s %b%s%b' "$(label workspace)" "$ORANGE" "$ws_display" "$RESET")")
  fi
  if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
    repo_display="$repo_owner/$repo_name"
  elif [ -n "$repo_name" ]; then
    repo_display="$repo_name"
  fi
  [ -n "$repo_display" ] && line4+=("$(printf '%s %b%s%b' "$(label repo)" "$ORANGE" "$repo_display" "$RESET")")
  branch=$(git_branch "$ws_dir")
  [ -n "$branch" ] && line4+=("$(printf '%s %b%s%b' "$(label branch)" "$ORANGE" "$branch" "$RESET")")
}

# Line 1 always renders (model cannot be hidden), so no combination of part
# settings produces no output at all. To hand the whole row back to Claude
# Code, run `statusline-toggle.sh off` instead.
print_lines() {
  echo "$(join_segments "${line1[@]}")"
  [ "$show_cost" = true ] && [ "${#line2[@]}" -gt 0 ] && echo "$(join_segments "${line2[@]}")"
  [ "$show_rate" = true ] && [ "${#line3[@]}" -gt 0 ] && echo "$(join_segments "${line3[@]}")"
  [ "$show_workspace" = true ] && [ "${#line4[@]}" -gt 0 ] && echo "$(join_segments "${line4[@]}")"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  read_payload
  read_advisor
  read_config
  # Leave before any output or any background job: see read_config.
  [ "$disabled" = true ] && exit 0
  read_cost_cache
  read_auth_verdict
  spawn_auth_probe_if_stale
  resolve_rate_windows
  build_line1
  build_line2
  build_line3
  build_line4
  print_lines
  exit 0
}

main
