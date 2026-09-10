#!/usr/bin/env bash
# statusline.sh: the Claude Code statusLine command.
#
# Reads the statusLine JSON payload from stdin and prints up to four lines:
#   1  model / effort / advisor / context bar   (always shown)
#   2  rate limits: current 5-hour window / current week / per-model week
#   3  cost: current session / today / weekly / monthly / all-time
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
#
# FORK COUNT IS THE BUDGET, and it is a correctness constraint, not a
# nicety. Claude Code cancels an in-flight statusline whenever a new
# update triggers (a new assistant message, /compact, a permission-mode
# change, the refreshInterval timer), so a render that is slower than the
# gap between triggers is killed every time and the user sees nothing at
# all. Forking is ~1ms on Linux and macOS but 150-210ms under the Cygwin
# bash that Git for Windows ships, where an earlier version of this script
# spent ~4s per render across ~50 forks and completed 0 renders out of 100.
# So: ONE jq call assembles every field from stdin and all five state
# files, rendering uses `printf -v` rather than `$(...)` (a command
# substitution is a fork), and the remaining external commands are counted
# and justified where they appear.

case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
. "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null || exit 0
nut_ensure_dirs

COST_CACHE_MAX_AGE=300
AUTH_CACHE_MAX_AGE=300
# A weekly window moves slowly and the probe is a network call, so this is
# the longest gate here rather than the shortest.
USAGE_CACHE_MAX_AGE=300

# This plugin's floor is stock bash 3.2 (macOS's /bin/bash), where `date`
# and `tr` are the only way to do these things. Bash 4.2+ (Linux, WSL,
# Git-for-Windows/Cygwin, a homebrew bash on macOS) can do the same work
# in-process with printf's %()T strftime and case-modifying expansion,
# saving a fork apiece. Gated on the version, not on a feature probe, so
# the check runs once instead of once per call.
NUT_FAST_STRFTIME=false
NUT_FAST_CASE_MOD=false
if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] 2>/dev/null; then
  NUT_FAST_STRFTIME=true
  NUT_FAST_CASE_MOD=true
elif [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] 2>/dev/null; then
  [ "${BASH_VERSINFO[1]:-0}" -ge 2 ] 2>/dev/null && NUT_FAST_STRFTIME=true
  NUT_FAST_CASE_MOD=true
fi

# Wall clock, read once and reused: on bash 3.2 this is the script's only
# `date` fork, and both bash and the jq program below must agree on "now"
# or a window could look live to one and expired to the other.
if [ "$NUT_FAST_STRFTIME" = true ]; then
  printf -v NOW '%(%s)T' -1
else
  NOW=$(date +%s 2>/dev/null)
fi
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac

CLAUDE_ORANGE='\033[38;2;217;119;87m'
ORANGE="$CLAUDE_ORANGE"
# The alternate accent, swapped in for ORANGE when config.json says
# "color": "blue". #8AB4F8, the Antigravity CLI accent.
BLUE='\033[38;2;138;180;248m'
GRAY='\033[38;5;240m'
RESET='\033[0m'
# Font-only colors matching the /effort picker's per-level colors.
EFFORT_LOW='\033[38;2;230;180;40m'      # low = warning (yellow)
EFFORT_MEDIUM='\033[38;2;80;200;120m'   # medium = success (green)
EFFORT_HIGH='\033[38;2;177;185;249m'    # high = permission (periwinkle)
EFFORT_XHIGH='\033[38;2;185;150;235m'   # xhigh = lavender
# max = the Claude brand color, pinned. It does NOT follow the accent: the
# effort colors are a fixed scale (yellow, green, periwinkle, lavender,
# orange), and letting the top of it move with the accent both breaks the
# scale and, under the blue accent, makes max indistinguishable from every
# other value on the row.
EFFORT_MAX="$CLAUDE_ORANGE"

# ---------------------------------------------------------------------------
# Formatting helpers.
#
# Every one of these sets a global instead of printing its result: a caller
# writing `x=$(helper)` would fork a subshell, which is the single most
# expensive thing this script can do. The variable each sets is named in
# its comment.
# ---------------------------------------------------------------------------

# Sets ECOLOR to the raw escape for an effort level. Raw, not expanded:
# every consumer passes it through printf's %b, which expands it there.
effort_color() {
  case "$1" in
    low)    ECOLOR="$EFFORT_LOW" ;;
    medium) ECOLOR="$EFFORT_MEDIUM" ;;
    high)   ECOLOR="$EFFORT_HIGH" ;;
    xhigh)  ECOLOR="$EFFORT_XHIGH" ;;
    max)    ECOLOR="$EFFORT_MAX" ;;
    *)      ECOLOR="$ORANGE" ;;
  esac
}

# Alias -> display name, into ADVISOR_NAME. settings.json only stores the
# bare alias and no runtime lookup exists for the resolved name, so this
# WILL drift on new model releases (opus was "Opus 4.8", now "Opus 5" as of
# 2026-07; fable was "Fable 5", now "Fable 5.1" as of 2026-09, Claude Code
# 2.1.255+).
advisor_display_name() {
  case "$1" in
    fable)  ADVISOR_NAME='Fable 5.1' ;;
    sonnet) ADVISOR_NAME='Sonnet 5' ;;
    opus)   ADVISOR_NAME='Opus 5' ;;
    haiku)  ADVISOR_NAME='Haiku 4.5' ;;
    *)      ADVISOR_NAME="$1" ;;
  esac
}

# Field label into LBL: word ("model:") or icon ("💡") per emoji_mode.
#
# Every icon must be a SINGLE codepoint whose East Asian Width is W (wide).
# Never one that needs a U+FE0F variation selector to reach its emoji form:
# the terminal measures the base codepoint, finds it Neutral, reserves one
# cell, and the font paints two, so the glyph overlaps what follows.
# U+1F5D3 FE0F and U+267B FE0F both did this and were replaced. Check a new
# icon with `python3 -c "import unicodedata as u; print(u.east_asian_width(C))"`,
# which must print W, and confirm it is one codepoint.
label() {
  LBL=""
  if [ "$emoji_mode" = true ]; then
    case "$1" in
      model)        LBL='💡' ;;
      advisor)      LBL='🎓' ;;
      context)      LBL='⏳' ;;
      cost_session) LBL='🪙' ;;
      cost_today)   LBL='⛅' ;;
      cost_week)    LBL='📅' ;;
      cost_month)   LBL='🧾' ;;
      cost_alltime) LBL='💳' ;;
      rate_five)    LBL='🕐' ;;
      rate_week)    LBL='🔄' ;;
      rate_model)   LBL='⚡' ;;
      workspace)    LBL='📂' ;;
      repo)         LBL='🌐' ;;
      branch)       LBL='🌿' ;;
    esac
  else
    case "$1" in
      model)        LBL='model:' ;;
      advisor)      LBL='advisor:' ;;
      context)      LBL='context:' ;;
      cost_session) LBL='current session:' ;;
      cost_today)   LBL='today:' ;;
      cost_week)    LBL='weekly:' ;;
      cost_month)   LBL='monthly:' ;;
      cost_alltime) LBL='all-time:' ;;
      rate_five)    LBL='5 hours session:' ;;
      rate_week)    LBL='weekly session:' ;;
      rate_model)   LBL='weekly fable:' ;;
      workspace)    LBL='workspace:' ;;
      repo)         LBL='repo:' ;;
      branch)       LBL='branch:' ;;
    esac
  fi
}

# Both context token counts -> USED_FMT and TOTAL_FMT ("51.8k", "1.0m",
# under 1000 as-is). One awk call for the pair rather than one each.
#
# awk stays here deliberately, as the script's only unavoidable formatting
# fork. %.1f must round the IEEE double nearest to n/1000, and only real
# float arithmetic does that: 1050/1000 is 1.05000000000000004 and rounds
# UP to 1.1, while 1450/1000 is 1.44999999999999996 and rounds DOWN to 1.4.
# Integer round-half-up gets the second case wrong, and bash's own printf
# cannot be used as a substitute either - under Cygwin `printf '%.1f' 1.05`
# answers 1.0, disagreeing with the correctly-rounded 1.1. Rendering a
# token count a tenth off is not worth a wrong number, so awk keeps the job.
fmt_tokens_pair() {
  USED_FMT=""
  TOTAL_FMT=""
  if [ -z "$1" ] && [ -z "$2" ]; then return; fi
  IFS=$'\x1f' read -r USED_FMT TOTAL_FMT < <(
    awk -v u="$1" -v t="$2" '
      function fmt(n) {
        if (n == "") return ""
        if (n !~ /^[0-9]+$/) return n
        if (n >= 1000000) return sprintf("%.1fm", n / 1000000)
        if (n >= 1000) return sprintf("%.1fk", n / 1000)
        return n
      }
      BEGIN { printf "%s\037%s", fmt(u), fmt(t) }
    ' 2>/dev/null
  )
}

# A path into PATHOUT with every "/" left in the default foreground and the
# segments between them in the accent. The separators are punctuation, the
# same argument the "@" before a branch gets, and a long path reads as a
# path rather than one unbroken block of color.
#
# All bash: the loop is parameter substitution only, so this costs no fork
# however deep the path is.
color_path() {
  local rest="$1" part out=""
  while :; do
    case "$rest" in
      */*) part="${rest%%/*}"; rest="${rest#*/}"
         out="${out}${ORANGE}${part}${RESET}/" ;;
      *) break ;;
    esac
  done
  printf -v PATHOUT '%b' "${out}${ORANGE}${rest}${RESET}"
}

# Colored block bar for a percentage (0-100) into BAR, e.g. "[███░░░░░░░]".
#
# Integer arithmetic replaces the awk this used to fork. Equivalent because
# the awk was int(p/100*w + 0.5) with w fixed at 10, i.e. round(p/10), and
# for any p >= 0 round(floor(p)/10) == round(p/10): the fraction dropped by
# floor can never carry p across a .5 boundary in p/10, since crossing one
# needs a whole unit of p. Verified against the awk over a sweep of
# boundary values (0, 4.9, 5, 44.9, 45, 64.5, 65, 95.5, 99.9, 100, 105).
render_bar() {
  local pct="$1" width=10 filled empty i bar pct_int
  BAR=""
  [ -z "$pct" ] && return
  case "$pct" in -*) pct_int=0 ;; *) pct_int=${pct%%.*} ;; esac
  case "$pct_int" in ''|*[!0-9]*) pct_int=0 ;; esac
  filled=$(( (pct_int * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled="$width"
  empty=$((width - filled))
  bar="[${ORANGE}"
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  bar+="${RESET}${GRAY}"
  for ((i = 0; i < empty; i++)); do bar+="░"; done
  bar+="${RESET}]"
  printf -v BAR '%b' "$bar"
}

# strftime for a unix epoch into EPOCHOUT; returns 1 when it cannot. Bash's
# own printf on 4.2+, GNU (-d) or BSD (-r) `date` on 3.2. Callers pass the
# `date` convention of a leading "+" either way; the fast path strips it,
# since printf's %()T takes the bare spec. A non-numeric epoch (an
# ISO-8601 string, say) fails the guard and yields nothing, which is what
# "both date flavours failed" used to produce.
epoch_date() {
  EPOCHOUT=""
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$NUT_FAST_STRFTIME" = true ]; then
    printf -v EPOCHOUT "%(${2#+})T" "$1" 2>/dev/null || return 1
  else
    EPOCHOUT=$(date -d "@${1}" "$2" 2>/dev/null || date -r "${1}" "$2" 2>/dev/null)
  fi
  [ -n "$EPOCHOUT" ] || return 1
}

# Unix epoch -> local time like "3:45pm", into TIMESTR. %l pads the hour
# with a leading space, which is stripped here rather than by a sed.
fmt_time() {
  local t
  TIMESTR=""
  [ -z "$1" ] && return
  epoch_date "$1" "+%l:%M%p" || return
  t="${EPOCHOUT# }"
  if [ "$NUT_FAST_CASE_MOD" = true ]; then
    # ${t,,} through eval, not written literally. The runtime gate above
    # already keeps it away from bash 3.2, but bash parses a whole function
    # body before running any of it, and the ,, operator did not exist
    # before 4.0 - so a literal would risk a PARSE error on macOS's stock
    # bash even though that branch is never taken. Inside a single-quoted
    # string it is just text to the parser, and only the shells that
    # understand it ever evaluate it. No fork either way.
    eval 'TIMESTR="${t,,}"'
  else
    TIMESTR=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  fi
}

# Unix epoch -> RESETSTR: local time, prefixed with the date only when it
# is not today ("6:19am", or "Jul 11, 6:19am"). An unparseable epoch yields
# nothing, so the caller drops the parenthesised clock entirely rather than
# rendering "( , )".
fmt_reset() {
  local epoch="$1" reset_date today
  RESETSTR=""
  RESETDATE=""
  [ -z "$epoch" ] && return
  epoch_date "$epoch" "+%Y-%m-%d" || return
  reset_date="$EPOCHOUT"
  if [ "$NUT_FAST_STRFTIME" = true ]; then
    printf -v today '%(%Y-%m-%d)T' -1
  else
    today=$(date "+%Y-%m-%d" 2>/dev/null)
  fi
  fmt_time "$epoch"
  if [ "$reset_date" != "$today" ]; then
    # "%e" pads a single-digit day with a space ("Sep  9"); collapse it the
    # way the old `sed 's/  */ /g'` did.
    epoch_date "$epoch" "+%b %e"
    # The date half is kept apart from the time half so the caller can leave
    # the comma between them in the default fg, the way every other piece of
    # punctuation in a row is.
    RESETDATE="${EPOCHOUT//  / }"
    RESETSTR="$RESETDATE, $TIMESTR"
  else
    RESETSTR="$TIMESTR"
  fi
}

# Current branch into BRANCH, read straight out of .git rather than by
# shelling out to git: the payload has no general branch field
# (worktree.branch exists only for --worktree sessions), and this works on
# a machine with no git installed. Walks up from the starting directory the
# way git does, so a subdirectory of the repo still reports the branch.
# `read < file` is a redirection, not a fork, so the sed/head/cut this used
# to pipe through are gone.
git_branch() {
  local dir="$1" gitdir="" head=""
  BRANCH=""
  GITROOT=""
  [ -n "$dir" ] || return
  while [ -n "$dir" ]; do
    if [ -d "$dir/.git" ]; then
      gitdir="$dir/.git"
      GITROOT="$dir"
      break
    fi
    # A linked worktree has .git as a FILE holding "gitdir: <path>", and
    # that path is where HEAD actually lives.
    if [ -f "$dir/.git" ]; then
      IFS= read -r head < "$dir/.git" 2>/dev/null
      case "$head" in
        'gitdir: '*) gitdir="${head#gitdir: }"; GITROOT="$dir" ;;
        *)           gitdir="" ;;
      esac
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
  head=""
  IFS= read -r head < "$gitdir/HEAD" 2>/dev/null
  case "$head" in
    'ref: refs/heads/'*) BRANCH="${head#ref: refs/heads/}" ;;
    '') return ;;
    # Detached HEAD holds a bare SHA. Show it short, the way git log does.
    *) BRANCH="${head:0:7}" ;;
  esac
}

# One "label X.XX$" cost item into SEG, value and $ colored. SEG is left
# empty for an empty value; every caller already guards on that.
cost_item() {
  SEG=""
  [ -z "$2" ] && return
  printf -v SEG '%s %b%.2f$%b' "$1" "$ORANGE" "$2" "$RESET"
}

# One rate window into SEG, with the reset time when fmt_reset produces one.
render_rate_window() {
  local pct="$2"
  fmt_reset "$3"
  label "$1"
  if [ -n "$RESETDATE" ]; then
    printf -v SEG '%s %b%.0f%%%b used (%b%s%b, %b%s%b)' \
      "$LBL" "$ORANGE" "$pct" "$RESET" \
      "$ORANGE" "$RESETDATE" "$RESET" "$ORANGE" "$TIMESTR" "$RESET"
  elif [ -n "$RESETSTR" ]; then
    printf -v SEG '%s %b%.0f%%%b used (%b%s%b)' \
      "$LBL" "$ORANGE" "$pct" "$RESET" "$ORANGE" "$RESETSTR" "$RESET"
  else
    printf -v SEG '%s %b%.0f%%%b used' "$LBL" "$ORANGE" "$pct" "$RESET"
  fi
}

# Join the positional arguments with " | " into JOINED. No bash nameref
# (4.3+), which macOS's bundled bash 3.2 does not have.
join_segments() {
  local seg
  JOINED=""
  for seg in "$@"; do
    if [ -z "$JOINED" ]; then JOINED="$seg"; else JOINED="$JOINED | $seg"; fi
  done
}

# $1 into AS_EPOCH when it is a non-negative integer, else 0. A cache that
# is missing, invalid or hand-edited leaves a timestamp empty or
# non-numeric; 0 keeps the age arithmetic valid and makes the age huge,
# which is the right answer for a broken cache.
as_epoch() {
  case "$1" in
    ''|*[!0-9]*) AS_EPOCH=0 ;;
    *) AS_EPOCH="$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Input: one jq call for everything
#
# The payload from stdin plus all five files (config.json, settings.json,
# and the cost / auth / rate caches) are parsed, and the rate-window merge
# is computed, by a single jq invocation. This used to be five separate jq
# calls plus a sixth for the merge; on Windows that alone was ~2s.
#
# Each file arrives as TEXT (--rawfile) and is parsed inside jq by
# `fromjson` under `try`, not via --slurpfile: --slurpfile aborts the whole
# invocation on one malformed file, which would take every unrelated
# segment down with it. Parsed-per-file keeps the old behaviour where a
# corrupt cache costs only its own fields. A file that does not exist is
# passed as an empty string instead, since --rawfile on a missing path is
# itself an error.
#
# The \x1f delimiter is not @tsv's tab: `read` collapses consecutive
# tab/space delimiters even with IFS set to one of them, silently shifting
# fields whenever one is empty (routine here: absent .effort, absent
# .cost). \x1f is not IFS whitespace, so it does not collapse.
# ---------------------------------------------------------------------------

NUT_JQ_PROG='
def obj($s): (try ($s | fromjson) catch null) as $v
  | if ($v | type) == "object" then $v else {} end;
obj($praw)    as $pl  |
obj($cfgraw)  as $cfg |
obj($setraw)  as $set |
obj($costraw) as $cc  |
obj($authraw) as $au  |
obj($rateraw) as $rc  |
obj($usageraw) as $us |

# Part visibility. Raw tostring values, not `.key // true`: jq treats false
# as empty, so `//` would un-hide a hidden part. A missing key reads
# "null", which is neither "false" nor "true", so the bash defaults hold -
# shown for the parts, off for emoji, active for disabled. The session part
# falls back to its pre-v0.3.0 key "rate" via has(), for the same reason.
# Hidden on a first install, for the same reason and by the same test as
# $cfg_mode below: an empty $cfg is a config.json that does not exist yet.
# A config that exists without the key keeps failing open to shown, so an
# upgrade never loses a row it already had.
(if ($cfg | length) == 0 then "false" else ($cfg.cost | tostring) end) as $cfg_cost |
((if ($cfg | has("session")) then $cfg.session else $cfg.rate end) | tostring) as $cfg_session |
($cfg.workspace | tostring) as $cfg_workspace |
($cfg.emoji | tostring) as $cfg_emoji |
# Two different defaults, and the difference is deliberate. An EMPTY $cfg is
# a config.json that does not exist yet, which is a first install (sync.sh
# registers the statusline, statusline-toggle.sh writes the config later),
# and a first install starts on the one-line layout. A config that exists
# but carries no mode key was written before 0.3.4, and that is an upgrade:
# it stays on the four-line layout its owner already had. An unparseable
# config also lands here as empty, which is the same answer a fresh install
# gets, and no worse than any other fail-open default in this file.
# The accent color. Anything but the exact word "blue" reads as orange, so
# a hand-edited value can never leave the row in a color nobody chose, and a
# config written before this key existed keeps the look it had.
(if ($cfg.color | tostring) == "blue" then "blue" else "orange" end) as $cfg_color |
(if ($cfg | length) == 0 then "simple"
 else (($cfg.mode // "detail") | tostring) end) as $cfg_mode |
($cfg.disabled | tostring) as $cfg_disabled |
($cfg_session != "false") as $showrate |

# Payload. `// ""` not `// empty` (empty is a zero-output generator and
# would drop the whole array on a null field).
($pl.model.display_name // "")                 as $model |
($pl.effort.level // "")                       as $effort |
($pl.context_window.used_percentage // "")     as $ctxu |
($pl.context_window.total_input_tokens // "")  as $ctxut |
($pl.context_window.context_window_size // "") as $ctxtt |
($pl.cost.total_cost_usd // "")                as $cost |
($pl.session_id // "")                         as $sid |
($pl.workspace.current_dir // $pl.cwd // "")   as $ws |
($pl.workspace.repo.owner // "")               as $ro |
($pl.workspace.repo.name // "")                as $rn |
(($pl.rate_limits // {}) | if type == "object" then . else {} end) as $p |
(($p | length) > 0) as $rate_has |
($set.advisorModel // "") as $adv |
($pl.version // "") as $ccver |

# Per-model weekly window, from the cache usage_cache_refresh.sh writes.
# Keyed by the display name the server itself sends; "Fable" is the only one rendered,
# and a cache without it (any other plan, or a probe that never ran) leaves
# all three fields empty and the segment is skipped.
(($us.models? | objects) // {}) as $um |
(($um["Fable"] | objects) // {}) as $fab |
(($fab.resets_at | numbers) // 0) as $fab_reset |
(($fab | length) > 0 and $fab_reset > $now) as $fab_live |
($us.updated_at // 0) as $u_upd |

# Token counts formatted here in exact integer arithmetic, so the common
# render needs no awk fork at all. Rounding one decimal place from a
# thousands remainder is round(frac/100) = (frac + 50) / 100 in integer
# division, which is EXACT unless the discarded part is exactly one half -
# that is, unless frac % 100 == 50. Only then does the answer depend on
# which side of the tie the IEEE double for n/1000 actually falls, which
# integer maths cannot know; $tok_tie flags those and bash re-does both
# values with awk. Ties are 1 value in 100, so awk is skipped almost always.
def fmt_tok($n):
  if ($n | type) != "number" then ($n | tostring)
  elif $n >= 1000000 then
    (($n / 1000000) | floor) as $w | ($n % 1000000) as $frac |
    ((($frac + 50000) / 100000) | floor) as $t |
    (if $t >= 10 then "\($w + 1).0m" else "\($w).\($t)m" end)
  elif $n >= 1000 then
    (($n / 1000) | floor) as $w | ($n % 1000) as $frac |
    ((($frac + 50) / 100) | floor) as $t |
    (if $t >= 10 then "\($w + 1).0k" else "\($w).\($t)k" end)
  else ($n | tostring) end;
def is_tie($n):
  if ($n | type) != "number" then false
  elif $n >= 1000000 then (($n % 1000000) % 100000) == 50000
  elif $n >= 1000 then (($n % 1000) % 100) == 50
  else false end;
fmt_tok($ctxut) as $used_fmt |
fmt_tok($ctxtt) as $total_fmt |
(is_tie($ctxut) or is_tie($ctxtt)) as $tok_tie |

($cc.today_cost // "")    as $c_today |
($cc.weekly_cost // "")   as $c_week |
($cc.monthly_cost // "")  as $c_month |
($cc.all_time_cost // "") as $c_all |
($cc.updated_at // 0)     as $c_upd |

# Auth verdict, per session: "" = unknown (no cache entry, or no
# subscription_type key), "none" = metered billing, anything else = the
# subscriptionType string. "none" cannot collide with a real plan name,
# since a null subscriptionType is mapped to it explicitly. $envmetered
# carries the ANTHROPIC_*/CLAUDE_CODE_USE_* check, which settles "metered"
# for the render or two before the probe lands and is only consulted while
# the probe has said nothing.
(if ($showrate and $sid != "")
   then ((($au.sessions[$sid]?) | objects) // {})
   else null end) as $ae |
(if $ae == null then ""
   else (if ($ae | has("subscription_type")) then ($ae.subscription_type // "none") else "" end)
 end) as $ap0 |
(if $ap0 == "" and $envmetered == "true" then "none" else $ap0 end) as $plan |
(if $ae == null then 0  else ($ae.updated_at // 0) end) as $a_upd |
(if $ae == null then "" else ($ae.sig // "") end)       as $a_sig |

# A metered session takes no part in the shared cache, neither reading nor
# writing; nor does one whose session line is hidden.
(if ($plan == "none") or ($showrate | not) then {} else $rc end) as $c |
((($pl.cost.total_cost_usd | numbers) // 0) > 0) as $responded |
($cost | tostring) as $costs |

# Keep only a window that carries a usable numeric resets_at.
def clean($o):
  if ($o | type) == "object" and ($o.resets_at | type) == "number"
  then {used_percentage: (($o.used_percentage | numbers) // 0), resets_at: $o.resets_at}
  else null end;
clean($p.five_hour) as $pf | clean($p.seven_day) as $ps |
# This session is fresh when its payload carries limits and its cost grew
# since the signature on file. A session with no signature on file, a
# non-numeric one, or a cost that fell (reset by /clear) records the new
# signature and waits for its next response.
(if $pf == null and $ps == null then "" else $costs end) as $sig |
(($c.sessions | objects) // {}) as $sessions |
(($sessions[$sid]? | objects | .sig | strings) // null) as $stored |
(try ($sig | tonumber) catch null) as $sn |
(if $stored == null then null else (try ($stored | tonumber) catch null) end) as $tn |
($sid != "" and $sig != "") as $carries |
($carries and $sn != null and $tn != null and $sn > $tn) as $fresh |
($carries and ($fresh | not) and $sig != $stored) as $record |
# A fresh session renders and publishes its own reading, falling back to
# the cache for a window its payload lacks or has expired; an idle one
# renders the cache, falling back to its own reading likewise.
def live($v): if $v != null and $v.resets_at > $now then $v else null end;
def pick($w; $pw):
  if $fresh then (live($pw) // live(clean($c[$w])))
  else (live(clean($c[$w])) // live($pw)) end;
pick("five_hour"; $pf) as $f | pick("seven_day"; $ps) as $s |
# Windows seen on this plan: what the cache remembers, if it was recorded
# under the same plan, plus whatever is live right now.
(($c.seen | objects) // {}) as $seen |
(if ($seen.plan // "") == $plan then (($seen.windows | arrays) // []) else [] end
  + (if $f == null then [] else ["five_hour"] end)
  + (if $s == null then [] else ["seven_day"] end)
  | unique) as $windows |
# The sessions map only changes on a publish or a (re)sighting, never on an
# idle render: prune week-old (or future-stamped) entries and record this
# session only then.
(if $fresh or $record then
   ($sessions | with_entries(select((.value.at? | numbers) != null
       and .value.at > ($now - 604800) and .value.at <= $now)))
   + {($sid): {sig: $sig, at: $now}}
 else $sessions end) as $sessions_new |
# Show/omit per window. Order matters: a live reading is shown no matter
# what the auth probe said, so a false "metered" verdict can only ever cost
# the pre-first-response 0%, never a real number. Once any window has been
# seen on this plan the plan is known, and a window missing from that set
# stays omitted even before the first response, so a Team seat does not
# flash a weekly 0% at every start.
def show($w; $v):
  if $v != null then true
  elif $plan == "none" then false
  elif ($windows | index($w)) != null then true
  elif ($windows | length) > 0 then false
  elif $responded then false
  else true end;
( (if $f == null then {} else {five_hour: $f} end)
  + (if $s == null then {} else {seven_day: $s} end)
  + (if $fresh then {measured_at: $now}
     elif ($c.measured_at | type) == "number" then {measured_at: $c.measured_at}
     else {} end)
  + (if ($windows | length) == 0 then {} else {seen: {plan: $plan, windows: $windows}} end)
  + (if ($sessions_new | length) == 0 then {} else {sessions: $sessions_new} end)
) as $merged |

[ $model, $effort, $ctxu, $ctxut, $ctxtt, $cost, $sid, $ws, $ro, $rn, $rate_has,
  $adv, $used_fmt, $total_fmt, $tok_tie,
  $cfg_cost, $cfg_session, $cfg_workspace, $cfg_emoji, $cfg_disabled,
  $c_today, $c_week, $c_month, $c_all, $c_upd,
  $plan, $a_upd, $a_sig,
  (if $showrate then show("five_hour"; $f) else "" end),
  (if $showrate then ($f.used_percentage // "") else "" end),
  (if $showrate then ($f.resets_at // "") else "" end),
  (if $showrate then show("seven_day"; $s) else "" end),
  (if $showrate then ($s.used_percentage // "") else "" end),
  (if $showrate then ($s.resets_at // "") else "" end),
  (if $showrate then ($merged | tojson) else "" end),
  (if $showrate then (($merged | tojson) != ($c | tojson)) else false end),
  $u_upd, $ccver, $cfg_color,
  # Both empty unless the window is present AND still open. An expired one
  # is dropped rather than frozen: Claude Code does the same with its own
  # windows, and a stale weekly number is worse than no number. Nothing here
  # ever renders a placeholder 0%.
  (if $fab_live then (($fab.percent | numbers) // 0) else "" end),
  # The reset stamp comes from the plan weekly window, not from the usage
  # endpoint: the two describe the same weekly reset but sit minutes apart
  # (different clocks, different rounding), and one row showing two weekly
  # resets reads as a bug. The endpoint stamp is the fallback for a session
  # whose weekly window has already been dropped from the payload.
  (if $fab_live then ((($s.resets_at | numbers) // $fab_reset)) else "" end),
  $cfg_mode
] | map(tostring) | join($sep)
'

# --rawfile for a file that exists, an empty --arg for one that does not.
nut_jq_file_arg() {
  if [ -f "$2" ]; then
    NUT_JQ_ARGS+=( --rawfile "$1" "$2" )
  else
    NUT_JQ_ARGS+=( --arg "$1" "" )
  fi
}

read_all() {
  local payload envmetered

  # `read -d ''` consumes stdin whole with no fork; $(cat) cost one.
  IFS= read -r -d '' payload

  # A launcher that points this session at a non-Anthropic endpoint exports
  # one of these (that is how such a session gets its credentials at all),
  # so they settle "metered" for the render or two before the probe lands,
  # which would otherwise fail open and flash another account's numbers.
  envmetered=false
  if [ -n "${ANTHROPIC_BASE_URL:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
     || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] \
     || [ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]; then
    envmetered=true
  fi

  # The \x1f field separator is passed in rather than written into the jq
  # program, so no invisible control byte lives in this file.
  #
  # -j (no trailing newline) is load-bearing on Windows, not a tidy-up. A
  # jq installed from WinGet or the official .exe is a NATIVE Windows
  # binary, so its stdout goes through CRLF translation and `jq -r` ends
  # its output with "\r\n". `read` strips only the "\n", leaving a "\r"
  # glued to the LAST field, which then silently fails every exact-string
  # comparison made against it. With -j there is no trailing newline to
  # translate and nothing to strip. (This bit the pre-refactor script,
  # where the last field of each of its five reads carried the "\r": the
  # cost cache's timestamp parsed as non-numeric so the refresher spawned
  # on every render, config's "disabled" read as "true\r" so
  # `statusline-toggle.sh off` did not take effect, and the rate cache was
  # rewritten every render because its own serialisation never compared
  # equal to itself.)
  NUT_JQ_ARGS=( -nrj --argjson now "$NOW" --arg envmetered "$envmetered" \
                --arg praw "$payload" --arg sep $'\x1f' )
  nut_jq_file_arg cfgraw  "$NUT_CONFIG"
  nut_jq_file_arg setraw  "$NUT_SETTINGS"
  nut_jq_file_arg costraw "$NUT_COST_CACHE"
  nut_jq_file_arg authraw "$NUT_AUTH_CACHE"
  nut_jq_file_arg rateraw "$NUT_RATE_CACHE"
  nut_jq_file_arg usageraw "$NUT_USAGE_CACHE"

  # Defaults for the case where jq is missing or errors: every part shown,
  # emoji off, active. The statusline degrades to what the payload alone
  # can say rather than going blank.
  model=""; effort=""; ctx_used=""; ctx_used_tokens=""; ctx_total_tokens=""
  cost=""; session_id=""; ws_dir=""; repo_owner=""; repo_name=""; rate_has=false
  advisor_raw=""; used_fmt_jq=""; total_fmt_jq=""; tok_tie=false
  cfg_cost=""; cfg_session=""; cfg_workspace=""; cfg_emoji=""; cfg_disabled=""
  today_cost=""; weekly_cost=""; monthly_cost=""; all_time_cost=""; cost_updated_at=0
  auth_plan=""; auth_updated_at=0; auth_sig=""
  five_show=""; five_pct=""; five_reset=""
  week_show=""; week_pct=""; week_reset=""
  rate_new=""; rate_changed=false
  usage_updated_at=0; cc_version=""; cfg_color="orange"; fable_pct=""; fable_reset=""
  cfg_mode="detail"

  IFS=$'\x1f' read -r model effort ctx_used ctx_used_tokens ctx_total_tokens \
      cost session_id ws_dir repo_owner repo_name rate_has \
      advisor_raw used_fmt_jq total_fmt_jq tok_tie \
      cfg_cost cfg_session cfg_workspace cfg_emoji cfg_disabled \
      today_cost weekly_cost monthly_cost all_time_cost cost_updated_at \
      auth_plan auth_updated_at auth_sig \
      five_show five_pct five_reset week_show week_pct week_reset \
      rate_new rate_changed \
      usage_updated_at cc_version cfg_color fable_pct fable_reset \
      cfg_mode < <(jq "${NUT_JQ_ARGS[@]}" "$NUT_JQ_PROG" 2>/dev/null)

  # Belt and braces behind the -j above: only the final field could ever
  # pick up a stray carriage return, so strip one if some other jq build
  # still manages to emit it. Both of the last two are stripped, and which
  # one is last has changed once already: rate_changed gates a disk write,
  # and cfg_mode is compared against an exact string, so a trailing \r there
  # would silently force the detail layout on the one platform (Git for
  # Windows, native jq, CRLF stdout) this guard exists for.
  rate_changed="${rate_changed%$'\r'}"
  cfg_mode="${cfg_mode%$'\r'}"

  # Fail open exactly as the old per-part reads did.
  show_cost=true
  show_rate=true
  show_workspace=true
  emoji_mode=false
  disabled=false
  [ "$cfg_disabled" = "true" ] && disabled=true
  [ "$cfg_cost" = "false" ] && show_cost=false
  [ "$cfg_session" = "false" ] && show_rate=false
  [ "$cfg_workspace" = "false" ] && show_workspace=false
  [ "$cfg_emoji" = "true" ] && emoji_mode=true
  # The accent every value is drawn in. ORANGE is set at file scope, before
  # any config has been read, so the swap happens here rather than there.
  # EFFORT_MAX is deliberately not touched: it holds CLAUDE_ORANGE and stays
  # there whatever the accent is.
  [ "$cfg_color" = blue ] && ORANGE="$BLUE"
  # Anything but the exact word "simple" renders the four lines, so a
  # hand-edited or truncated value can never produce a row nobody expects.
  [ "$cfg_mode" = "simple" ] || cfg_mode="detail"

  advisor=""
  if [ -n "$advisor_raw" ]; then
    advisor_display_name "$advisor_raw"
    advisor="$ADVISOR_NAME"
  fi
}

# ---------------------------------------------------------------------------
# Background work: never on the render path
# ---------------------------------------------------------------------------

# Each cost window is recomputed from the real calendar on every refresh,
# so they roll over on their own (today at midnight, weekly on Sunday,
# monthly on the 1st). Spawns the refresher when the cache is older than
# COST_CACHE_MAX_AGE, missing, unparseable, or stamped in the future (clock
# skew would otherwise make the age negative, always below the threshold,
# and the stale numbers would stay until the wall clock caught up). The
# ccusage check mirrors the refresher's own guard: without it every render
# would fork a process that can only exit.
spawn_cost_refresh_if_stale() {
  local cache_age
  as_epoch "$cost_updated_at"
  cache_age=$(( NOW - AS_EPOCH ))
  [ "$cache_age" -lt 0 ] && cache_age="$COST_CACHE_MAX_AGE"
  if [ "$show_cost" = true ] && [ "$cache_age" -ge "$COST_CACHE_MAX_AGE" ] \
     && command -v ccusage >/dev/null 2>&1; then
    nut_spawn bash "$NUT_BIN_DIR/cost_cache_refresh.sh"
  fi
}

# Re-probe the auth verdict in the background, same shape as the cost
# refresher: only when the session row is shown, only when `claude` is on
# PATH and the probe script is installed (either missing leaves the verdict
# unknown, which fails open, rather than forking a doomed job every render).
#
# Two things beside age make a verdict stale, and both force a re-probe
# rather than waiting out AUTH_CACHE_MAX_AGE:
#  - .credentials.json's mtime moved since the probe: every /login, logout
#    and account switch rewrites it (a token refresh too, which costs one
#    extra probe). A macOS install keeping credentials in the Keychain has
#    no such file, so there the age check is the only trigger. This is the
#    one `stat` fork on the render path, and it is skipped entirely until a
#    verdict exists to invalidate.
#  - the verdict says metered while the payload carries rate_limits, which
#    only an account with limits ever gets, so the verdict is provably wrong.
spawn_auth_probe_if_stale() {
  local auth_age auth_cred_mtime
  as_epoch "$auth_updated_at"
  auth_age=$(( NOW - AS_EPOCH ))
  [ "$auth_age" -lt 0 ] && auth_age="$AUTH_CACHE_MAX_AGE"
  if [ -n "$auth_plan" ]; then
    auth_cred_mtime=$(nut_mtime "$NUT_CREDENTIALS")
    if [ "$auth_sig" != "$auth_cred_mtime" ]; then
      auth_age="$AUTH_CACHE_MAX_AGE"
    elif [ "$auth_plan" = none ] && [ "$rate_has" = true ]; then
      auth_age="$AUTH_CACHE_MAX_AGE"
    fi
  fi
  if [ "$show_rate" = true ] && [ -n "$session_id" ] && [ "$auth_age" -ge "$AUTH_CACHE_MAX_AGE" ] \
     && command -v claude >/dev/null 2>&1 && [ -f "$NUT_BIN_DIR/auth_cache_refresh.sh" ]; then
    nut_spawn bash "$NUT_BIN_DIR/auth_cache_refresh.sh" "$session_id"
  fi
}

# Refresh the per-model weekly window in the background. The gate is the
# same shape as the other two, with two extra conditions that are the whole
# reason this stays cheap and quiet:
#  - the session part has to be shown, since that is what this rides on
#  - the verdict must not be "none": a metered session has no claude.ai plan
#    and the endpoint has nothing to say about it, so it is never called.
# An unknown verdict (no probe yet) does not spawn either, so the first
# render of a fresh session never fires a network call: the auth probe lands
# first and this follows on a later render.
spawn_usage_probe_if_stale() {
  local usage_age
  as_epoch "$usage_updated_at"
  usage_age=$(( NOW - AS_EPOCH ))
  [ "$usage_age" -lt 0 ] && usage_age="$USAGE_CACHE_MAX_AGE"
  if [ "$show_rate" = true ] && [ -n "$auth_plan" ] && [ "$auth_plan" != none ] \
     && [ "$usage_age" -ge "$USAGE_CACHE_MAX_AGE" ] \
     && command -v curl >/dev/null 2>&1 \
     && [ -f "$NUT_BIN_DIR/usage_cache_refresh.sh" ]; then
    nut_spawn bash "$NUT_BIN_DIR/usage_cache_refresh.sh" "$cc_version"
  fi
}

# Write the shared rate cache only on a real change, so the common case
# (several idle sessions re-rendering once a second) does no disk writes at
# all. Besides a publish or a sighting, that is an expired window being
# dropped, a `seen` plan changing, or a window the cache lacks being filled
# from this session's own reading. jq decided `rate_changed` by comparing
# the merged object against the one it read, so no second compare is needed
# here.
write_rate_cache_if_changed() {
  if [ "$show_rate" = true ] && [ "$rate_changed" = true ] \
     && [ -n "$rate_new" ] && [ "$auth_plan" != none ]; then
    nut_write_atomic "$rate_new" "$NUT_RATE_CACHE"
  fi
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

build_line1() {
  local seg
  line1=()
  if [ -n "$model" ]; then
    label model
    if [ -n "$effort" ]; then
      effort_color "$effort"
      printf -v seg '%s %b%s%b (%b%s%b)' \
        "$LBL" "$ORANGE" "$model" "$RESET" "$ECOLOR" "$effort" "$RESET"
    else
      printf -v seg '%s %b%s%b' "$LBL" "$ORANGE" "$model" "$RESET"
    fi
    line1+=("$seg")
  fi
  if [ -n "$advisor" ]; then
    label advisor
    printf -v seg '%s %b%s%b' "$LBL" "$ORANGE" "$advisor" "$RESET"
    line1+=("$seg")
  fi
  # A fresh session, and the window right after /compact, has no
  # used_percentage and no total_input_tokens yet (both documented as null
  # or 0 before the first API response). context_window_size comes from the
  # selected model, so it is there from the first render. Treat the missing
  # pair as a real zero and show 0% rather than a "warming up" placeholder.
  [ -z "$ctx_used" ] && ctx_used=0
  [ -z "$ctx_used_tokens" ] && ctx_used_tokens=0
  render_bar "$ctx_used"
  if [ -n "$ctx_total_tokens" ]; then
    # jq already formatted both counts exactly; awk is only needed for the
    # one-in-a-hundred value whose rounding lands on a true decimal tie.
    if [ "$tok_tie" = true ]; then
      fmt_tokens_pair "$ctx_used_tokens" "$ctx_total_tokens"
    else
      USED_FMT="$used_fmt_jq"
      TOTAL_FMT="$total_fmt_jq"
    fi
    label context
    printf -v seg '%s %b%s%b/%b%s%b tokens %s %b%.0f%%%b used' \
      "$LBL" "$ORANGE" "$USED_FMT" "$RESET" "$ORANGE" "$TOTAL_FMT" "$RESET" \
      "$BAR" "$ORANGE" "$ctx_used" "$RESET"
  else
    label context
    printf -v seg '%s %s %b%.0f%%%b used' "$LBL" "$BAR" "$ORANGE" "$ctx_used" "$RESET"
  fi
  line1+=("$seg")
}

build_line2() {
  line2=()
  if [ -n "$cost" ]; then
    label cost_session; cost_item "$LBL" "$cost"; line2+=("$SEG")
  fi
  if [ -n "$today_cost" ]; then
    label cost_today; cost_item "$LBL" "$today_cost"; line2+=("$SEG")
  fi
  if [ -n "$weekly_cost" ]; then
    label cost_week; cost_item "$LBL" "$weekly_cost"; line2+=("$SEG")
  fi
  if [ -n "$monthly_cost" ]; then
    label cost_month; cost_item "$LBL" "$monthly_cost"; line2+=("$SEG")
  fi
  if [ -n "$all_time_cost" ]; then
    label cost_alltime; cost_item "$LBL" "$all_time_cost"; line2+=("$SEG")
  fi
}

# A window whose show flag is not exactly "false" renders (the jq call
# failed, or the session part is hidden and the flags were never set), so a
# broken cache can hide nothing. An omitted window never lands in line3;
# with both omitted the row is dropped by the same empty-array check as
# every row.
build_line3() {
  line3=()
  [ -z "$five_pct" ] && five_pct=0
  [ -z "$week_pct" ] && week_pct=0
  if [ "$five_show" != false ]; then
    render_rate_window rate_five "$five_pct" "$five_reset"
    line3+=("$SEG")
  fi
  if [ "$week_show" != false ]; then
    render_rate_window rate_week "$week_pct" "$week_reset"
    line3+=("$SEG")
  fi
  # The per-model window is additive: it renders only when the probe has
  # actually seen one, and its absence changes nothing else on the row.
  if [ -n "$fable_pct" ]; then
    render_rate_window rate_model "$fable_pct" "$fable_reset"
    line3+=("$SEG")
  fi
}

# Where the session is, which repo, which branch. Each segment is
# independent: a directory outside any repo still shows its path, and a
# repo with no origin remote still shows its branch (repo.* comes from the
# origin remote and is absent without one).
build_line4() {
  local ws_display repo_display="" seg
  line4=()
  if [ -n "$ws_dir" ]; then
    # $HOME/x -> ~/x via case matching rather than sed, since a home path
    # can contain regex metacharacters.
    case "$ws_dir" in
      "$HOME")   ws_display="~" ;;
      "$HOME"/*) ws_display="~${ws_dir#"$HOME"}" ;;
      *)         ws_display="$ws_dir" ;;
    esac
    label workspace
    color_path "$ws_display"
    printf -v seg '%s %s' "$LBL" "$PATHOUT"
    line4+=("$seg")
  fi
  if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
    repo_display="$repo_owner/$repo_name"
  elif [ -n "$repo_name" ]; then
    repo_display="$repo_name"
  fi
  if [ -n "$repo_display" ]; then
    label repo
    color_path "$repo_display"
    printf -v seg '%s %s' "$LBL" "$PATHOUT"
    line4+=("$seg")
  fi
  git_branch "$ws_dir"
  if [ -n "$BRANCH" ]; then
    label branch
    # A branch name can carry slashes too ("feature/x"), and they are the
    # same punctuation as a path separator.
    color_path "$BRANCH"
    printf -v seg '%s %s' "$LBL" "$PATHOUT"
    line4+=("$seg")
  fi
}

# ---------------------------------------------------------------------------
# Simple mode (config "mode": "simple")
#
# One row instead of four. The fields are the ten worth keeping: model and
# effort, advisor, context, the current session's cost, both rate windows
# with a countdown, and where the session is. Everything cut is cut for
# width, and the arithmetic is worth stating: the same ten fields carrying
# the detail row's word labels measure 216 terminal cells, which is not a
# status row, it is a paragraph. Dropping the labels and merging workspace
# with repo brings it to about 112.
#
# Labels go, so ORDER carries the meaning and is fixed: model, advisor,
# context, cost, 5h, 7d, location. Two exceptions keep their word, because
# without them the field is unreadable rather than merely unlabelled: the
# advisor (otherwise two identical model names sit side by side) and the
# context counts. Emoji mode needs neither, an icon is already a label.
# ---------------------------------------------------------------------------

# Time from now until $1 (epoch) as a compact duration into CDSTR: "4d1h"
# over a day, "4h56m" under one, "35m" under an hour. Empty for a missing,
# unparseable or already-passed timestamp, which is also what the detail
# row does with one: a window whose reset has passed is dropped from the
# payload by Claude Code, so this is the same event seen from here.
fmt_countdown() {
  local left days hours mins
  CDSTR=""
  case "$1" in ''|*[!0-9]*) return ;; esac
  [ "$NOW" -gt 0 ] || return
  left=$(( $1 - NOW ))
  [ "$left" -gt 0 ] || return
  days=$(( left / 86400 ))
  hours=$(( (left % 86400) / 3600 ))
  mins=$(( (left % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then
    printf -v CDSTR '%dd%dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf -v CDSTR '%dh%dm' "$hours" "$mins"
  else
    printf -v CDSTR '%dm' "$mins"
  fi
}

# One rate window for the simple row: "5h 42% (4h56m)", or the icon in
# place of the "5h". The window is omitted on exactly the same rules as
# the detail row, so a metered session shows neither here nor there.
simple_rate() {  # label_key short_name pct reset
  local pct="$3"
  SEG=""
  [ -z "$pct" ] && pct=0
  fmt_countdown "$4"
  label "$1"
  [ "$emoji_mode" = true ] || LBL="$2"
  if [ -n "$CDSTR" ]; then
    printf -v SEG '%s %b%.0f%%%b (%b%s%b)' "$LBL" "$ORANGE" "$pct" "$RESET" "$ORANGE" "$CDSTR" "$RESET"
  else
    printf -v SEG '%s %b%.0f%%%b' "$LBL" "$ORANGE" "$pct" "$RESET"
  fi
}

# Where the session is, in one segment. At a repo root that is the repo
# name; in a subdirectory it is the repo name plus the path below it, which
# says more than either half alone; outside a repo it is the abbreviated
# path, since there is no name to use. The branch joins with "@" in words
# mode and with its own icon in emoji mode.
simple_location() {
  local name="" rel="" display=""
  SEG=""
  git_branch "$ws_dir"
  if [ -n "$GITROOT" ]; then
    name="$repo_name"
    [ -n "$name" ] || name="${GITROOT##*/}"
    if [ "$ws_dir" = "$GITROOT" ]; then
      display="$name"
    else
      rel="${ws_dir#"$GITROOT"/}"
      display="$name/$rel"
    fi
  elif [ -n "$ws_dir" ]; then
    case "$ws_dir" in
      "$HOME")   display="~" ;;
      "$HOME"/*) display="~${ws_dir#"$HOME"}" ;;
      *)         display="$ws_dir" ;;
    esac
  fi
  [ -n "$display" ] || return
  # The repo globe, not the workspace folder: this one segment is the repo
  # and its branch, which is what the detail row uses the globe for.
  label repo
  color_path "$display"
  if [ "$emoji_mode" = true ] && [ -n "$BRANCH" ]; then
    # One "<location>@<branch>" segment in both label styles, so the row has
    # the same shape either way and emoji mode costs one icon, not two.
    printf -v SEG '%s %s@' "$LBL" "$PATHOUT"
    color_path "$BRANCH"
    SEG="$SEG$PATHOUT"
  elif [ "$emoji_mode" = true ]; then
    printf -v SEG '%s %s' "$LBL" "$PATHOUT"
  elif [ -n "$BRANCH" ]; then
    # The "@" is punctuation, not a value: it stays in the default fg, the
    # same as the labels and the " | " separators, so only the repo and the
    # branch carry the brand color.
    printf -v SEG '%s@' "$PATHOUT"
    color_path "$BRANCH"
    SEG="$SEG$PATHOUT"
  else
    printf -v SEG '%s' "$PATHOUT"
  fi
}

# The whole row. Every part toggle still applies: cost off drops the cost,
# session off drops both windows, workspace off drops the location. Model
# is pinned on, so this can never be empty.
build_simple() {
  local seg
  simple=()
  if [ -n "$model" ]; then
    if [ "$emoji_mode" = true ]; then
      label model
      if [ -n "$effort" ]; then
        effort_color "$effort"
        printf -v seg '%s %b%s%b (%b%s%b)' "$LBL" "$ORANGE" "$model" "$RESET" "$ECOLOR" "$effort" "$RESET"
      else
        printf -v seg '%s %b%s%b' "$LBL" "$ORANGE" "$model" "$RESET"
      fi
    elif [ -n "$effort" ]; then
      effort_color "$effort"
      printf -v seg '%b%s%b (%b%s%b)' "$ORANGE" "$model" "$RESET" "$ECOLOR" "$effort" "$RESET"
    else
      printf -v seg '%b%s%b' "$ORANGE" "$model" "$RESET"
    fi
    simple+=("$seg")
  fi
  if [ -n "$advisor" ]; then
    label advisor
    [ "$emoji_mode" = true ] || LBL="adv:"
    printf -v seg '%s %b%s%b' "$LBL" "$ORANGE" "$advisor" "$RESET"
    simple+=("$seg")
  fi
  # Counts, not the percentage bar: the bar costs twelve cells and the counts
  # are the number a user acts on.
  [ -z "$ctx_used_tokens" ] && ctx_used_tokens=0
  if [ -n "$ctx_total_tokens" ]; then
    if [ "$tok_tie" = true ]; then
      fmt_tokens_pair "$ctx_used_tokens" "$ctx_total_tokens"
    else
      USED_FMT="$used_fmt_jq"
      TOTAL_FMT="$total_fmt_jq"
    fi
    label context
    [ "$emoji_mode" = true ] || LBL="ctx:"
    printf -v seg '%s %b%s%b/%b%s%b' "$LBL" "$ORANGE" "$USED_FMT" "$RESET" "$ORANGE" "$TOTAL_FMT" "$RESET"
    simple+=("$seg")
  fi
  # No cost segment at all in this layout, whatever the cost part says: the
  # detail row carries the five cost windows, and the one that fits here (the
  # current session) is the least useful of them. The part toggle still
  # governs the cost REFRESH, so switching it off in simple mode also stops
  # the ccusage scan, exactly as it does in detail.
  if [ "$show_rate" = true ]; then
    if [ "$five_show" != false ]; then
      simple_rate rate_five 5h: "$five_pct" "$five_reset"; simple+=("$SEG")
    fi
    if [ "$week_show" != false ]; then
      simple_rate rate_week 7d: "$week_pct" "$week_reset"; simple+=("$SEG")
    fi
    if [ -n "$fable_pct" ]; then
      simple_rate rate_model fable: "$fable_pct" "$fable_reset"; simple+=("$SEG")
    fi
  fi
  if [ "$show_workspace" = true ]; then
    simple_location
    [ -n "$SEG" ] && simple+=("$SEG")
  fi
}

# Line 1 always renders (model cannot be hidden), so no combination of part
# settings produces no output at all. To hand the whole row back to Claude
# Code, run `statusline-toggle.sh off` instead.
print_lines() {
  join_segments "${line1[@]}"
  printf '%s\n' "$JOINED"
  # The rate windows print above the cost windows. The arrays keep their
  # build order (line2 is cost, line3 is the rate windows); only the order
  # they are printed in swapped.
  if [ "$show_rate" = true ] && [ "${#line3[@]}" -gt 0 ]; then
    join_segments "${line3[@]}"; printf '%s\n' "$JOINED"
  fi
  if [ "$show_cost" = true ] && [ "${#line2[@]}" -gt 0 ]; then
    join_segments "${line2[@]}"; printf '%s\n' "$JOINED"
  fi
  if [ "$show_workspace" = true ] && [ "${#line4[@]}" -gt 0 ]; then
    join_segments "${line4[@]}"; printf '%s\n' "$JOINED"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  read_all
  # Leave before any output, any write and any background job. Inactive has
  # to mean no tracking, not just no display: if Claude Code does not act on
  # the deleted statusLine key mid-session, a session that already holds the
  # registration keeps invoking this script, and without the early exit the
  # cost refresher and the auth probe would keep running for a row the user
  # asked to hand back. Reading the files above has no side effects.
  [ "$disabled" = true ] && exit 0
  spawn_cost_refresh_if_stale
  spawn_auth_probe_if_stale
  spawn_usage_probe_if_stale
  write_rate_cache_if_changed
  if [ "$cfg_mode" = simple ]; then
    build_simple
    join_segments "${simple[@]}"
    printf '%s\n' "$JOINED"
    exit 0
  fi
  build_line1
  build_line2
  build_line3
  build_line4
  print_lines
  exit 0
}

main
