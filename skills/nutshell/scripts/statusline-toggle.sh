#!/usr/bin/env bash
# statusline-toggle.sh — show/hide the three status-line sections, and toggle emoji labels.
#
# The status line (statusline.sh) is divided into three parts:
#   model  — model name / advisor / context bar               (line 1)
#   cost   — session / today / week / month / all-time spend   (line 2)
#   rate   — usage rate: current session + current week limits (line 3)
#
# Independently of those, "emoji" swaps text labels ("model:", "session:", ...)
# for icons everywhere. Default OFF (fail-closed) — unlike model/cost/rate,
# which fail open (missing key = shown), a missing/bad emoji key must not
# silently switch the status line to icons the user didn't ask for.
#
# Usage:
#   statusline-toggle.sh <part> <on|off|toggle>   # part = model | cost | rate
#   statusline-toggle.sh all <on|off>
#   statusline-toggle.sh emoji [on|off|toggle]    # no arg = toggle
#   statusline-toggle.sh status
#
# Changes take effect within ~1s (statusline refreshInterval), no restart needed.

set -euo pipefail

CONFIG="$HOME/.claude/statusline.config.json"
REFRESH="$HOME/.claude/cost_cache_refresh.sh"
PARTS=(model cost rate)

usage() {
  cat <<'EOF'
Usage:
  statusline-toggle.sh <part> <on|off|toggle>   # part = model | cost | rate
  statusline-toggle.sh all <on|off>
  statusline-toggle.sh emoji [on|off|toggle]    # no arg = toggle; default off
  statusline-toggle.sh status
  statusline-toggle.sh reset-all-time --yes     # reset all-time cost to 0 (keeps today/week/month)

Parts:
  model  model name / advisor / context bar               (line 1)
  cost   session / today / week / month / all-time spend   (line 2)
  rate   usage rate: current session + current week limits (line 3)
  emoji  replace text labels with icons across all shown parts (default off)
EOF
}

# Ensure the config exists and is valid JSON; recreate with defaults otherwise.
ensure_config() {
  if [ ! -f "$CONFIG" ] || ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    printf '{\n  "model": true,\n  "cost": true,\n  "rate": true,\n  "emoji": false\n}\n' > "$CONFIG"
  fi
  # Backfill "emoji" for configs written before emoji mode existed.
  if ! jq -e 'has("emoji")' "$CONFIG" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp "${CONFIG}.XXXXXX")"
    jq '. + {emoji: false}' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
}

# Read a part's current value ("true"/"false"); missing key defaults to true.
# Don't use `.key // true` — jq's // treats a literal `false` as empty and would
# wrongly return true, so read the raw value and only "false" counts as off.
# Duplicated in statusline.sh (no shared lib file); keep both in sync.
get_part() {
  local v
  v="$(jq -r ".${1}" "$CONFIG" 2>/dev/null)"
  [ "$v" = "false" ] && echo false || echo true
}

# Set a part to a JSON bool, writing atomically so statusline.sh never sees a
# half-written file.
set_part() {
  local part="$1" val="$2" tmp
  tmp="$(mktemp "${CONFIG}.XXXXXX")"
  jq --argjson v "$val" ".${part} = \$v" "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# Read emoji's current value ("true"/"false"); missing/bad key defaults to
# false (fail-closed — opposite of get_part's fail-open default).
get_emoji() {
  local v
  v="$(jq -r '.emoji' "$CONFIG" 2>/dev/null)"
  [ "$v" = "true" ] && echo true || echo false
}

# Full box-drawn table — only for the explicit "status" command.
print_status() {
  local p state names=(Part model cost rate emoji) states=(Status) name_w=0 state_w=0
  local top sep bot i

  for p in "${PARTS[@]}"; do
    if [ "$(get_part "$p")" = "false" ]; then states+=("off"); else states+=("on"); fi
  done
  if [ "$(get_emoji)" = "true" ]; then states+=("on"); else states+=("off"); fi

  for p in "${names[@]}"; do [ "${#p}" -gt "$name_w" ] && name_w="${#p}"; done
  for state in "${states[@]}"; do [ "${#state}" -gt "$state_w" ] && state_w="${#state}"; done

  local name_dashes state_dashes
  name_dashes="$(printf '─%.0s' $(seq 1 "$((name_w + 2))"))"
  state_dashes="$(printf '─%.0s' $(seq 1 "$((state_w + 2))"))"
  top="┌${name_dashes}┬${state_dashes}┐"
  sep="├${name_dashes}┼${state_dashes}┤"
  bot="└${name_dashes}┴${state_dashes}┘"

  printf '%s\n' "$top"
  for i in "${!names[@]}"; do
    printf '│ %-*s │ %-*s │\n' "$name_w" "${names[$i]}" "$state_w" "${states[$i]}"
    [ "$i" -lt "$((${#names[@]} - 1))" ] && printf '%s\n' "$sep"
  done
  printf '%s\n' "$bot"
}

# One-line confirmation — used by the toggle actions instead of the full table.
print_one() {
  printf '%s: %s\n' "$1" "$2"
}

command -v jq >/dev/null 2>&1 || { echo "statusline-toggle: jq is required" >&2; exit 1; }

ensure_config

cmd="${1:-}"

case "$cmd" in
  status)
    print_status
    ;;
  -h|--help|help)
    usage
    ;;
  all)
    action="${2:-}"
    case "$action" in
      on)  val=true ;;
      off) val=false ;;
      *) echo "statusline-toggle: 'all' needs on|off" >&2; usage; exit 1 ;;
    esac
    for p in "${PARTS[@]}"; do set_part "$p" "$val"; print_one "$p" "$action"; done
    ;;
  model|cost|rate)
    action="${2:-}"
    case "$action" in
      on)  set_part "$cmd" true ;;
      off) set_part "$cmd" false ;;
      toggle)
        if [ "$(get_part "$cmd")" = "false" ]; then set_part "$cmd" true; action=on; else set_part "$cmd" false; action=off; fi
        ;;
      *) echo "statusline-toggle: '$cmd' needs on|off|toggle" >&2; usage; exit 1 ;;
    esac
    print_one "$cmd" "$action"
    ;;
  emoji)
    action="${2:-toggle}"
    case "$action" in
      on)  set_part emoji true ;;
      off) set_part emoji false ;;
      toggle)
        if [ "$(get_emoji)" = "false" ]; then set_part emoji true; action=on; else set_part emoji false; action=off; fi
        ;;
      *) echo "statusline-toggle: 'emoji' needs on|off|toggle" >&2; usage; exit 1 ;;
    esac
    print_one emoji "$action"
    ;;
  reset-all-time)
    if [ "${2:-}" != "--yes" ]; then
      echo "statusline-toggle: 'reset-all-time' resets your all-time cost to 0 and cannot be undone." >&2
      echo "(today / week / month are kept.) Re-run to confirm:" >&2
      echo "  statusline-toggle.sh reset-all-time --yes" >&2
      exit 1
    fi
    command -v ccusage >/dev/null 2>&1 || { echo "reset-all-time: ccusage is required for this operation" >&2; exit 1; }
    if [ ! -f "$REFRESH" ]; then
      echo "statusline-toggle: refresher not found at $REFRESH" >&2
      exit 1
    fi
    echo "resetting all-time cost (recomputing from ccusage, ~10s)…"
    # timeout is GNU coreutils and absent on macOS; fall back to running
    # without a timeout there.
    if command -v timeout >/dev/null 2>&1; then
      reset_cmd=(timeout 90 bash "$REFRESH" --reset-all-time)
    else
      reset_cmd=(bash "$REFRESH" --reset-all-time)
    fi
    if ! "${reset_cmd[@]}"; then
      echo "statusline-toggle: reset failed or timed out" >&2
      exit 1
    fi
    echo "done — all-time cost is now 0; today / week / month are unchanged."
    ;;
  "")
    usage
    exit 1
    ;;
  *)
    echo "statusline-toggle: unknown part '$cmd' (expected model|cost|rate|all|emoji|status|reset-all-time)" >&2
    usage
    exit 1
    ;;
esac
