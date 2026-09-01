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
#   statusline-toggle.sh <part> <on|off|toggle>   # part = model | cost | rate | workspace
#   statusline-toggle.sh all <on|off>
#   statusline-toggle.sh emoji [on|off|toggle]    # no arg = toggle
#   statusline-toggle.sh status
#
# Changes take effect within ~1s (statusline refreshInterval), no restart needed.

set -euo pipefail

CONFIG="$HOME/.claude/statusline.config.json"
REFRESH="$HOME/.claude/cost_cache_refresh.sh"
PARTS=(model cost rate workspace)
SETTINGS_FILE="$HOME/.claude/settings.json"
# Must stay byte-identical in meaning to hooks/sync.sh's WANT and to
# SKILL.md step 0. Three copies exist because the plugin path, the npx
# path, and this script can each be the one that registers the status
# line; if they disagree they rewrite each other on every session start.
STATUSLINE_VALUE='{"type":"command","command":"bash ~/.claude/statusline.sh","refreshInterval":1}'


usage() {
  cat <<'EOF'
Usage:
  statusline-toggle.sh <part> <on|off|toggle>   # part = model | cost | rate | workspace
  statusline-toggle.sh all <on|off>
  statusline-toggle.sh off                      # hand the row back to Claude Code's own footer
  statusline-toggle.sh on [--force]             # take it back, with your saved part settings
  statusline-toggle.sh emoji [on|off|toggle]    # no arg = toggle; default off
  statusline-toggle.sh status
  statusline-toggle.sh reset-all-time --yes     # reset all-time cost to 0 (keeps today/week/month)
  statusline-toggle.sh uninstall --yes [--purge] # remove registration + installed scripts

Parts:
  model  model name / advisor / context bar               (line 1)
  cost   session / today / week / month / all-time spend   (line 2)
  rate   usage rate: current session + current week limits (line 3)
  workspace current directory / repo / git branch          (line 4)
  emoji  replace text labels with icons across all shown parts (default off)

on / off vs show / hide:
  `off` removes the statusLine registration from settings.json, so Claude
  Code shows its own footer again. `all off` keeps the registration and
  prints a blank row instead. Use `off` to get the default back.
EOF
}

# True when the user has handed the status line row back to Claude Code.
# Absent or unreadable means not disabled, so nothing changes for configs
# written before this existed.
is_disabled() {
  [ "$(jq -r '.disabled' "$CONFIG" 2>/dev/null)" = "true" ]
}

# True when settings.json's statusLine is absent, or is one we installed.
# Anyone can register a status line, and a user may well have a different
# one (Claude Code's own /statusline writes one from your shell PS1). We
# must not delete or overwrite someone else's registration, so both `off`
# and `on` check ownership first and the SessionStart hook does the same.
# Ownership is decided by the command string pointing at our script.
statusline_is_ours() {
  local cmd
  [ -f "$SETTINGS_FILE" ] || return 0
  cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null)
  [ -z "$cmd" ] && return 0
  case "$cmd" in
    *'/.claude/statusline.sh'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The command currently registered, for messages.
current_statusline_command() {
  jq -r '.statusLine.command // "(none)"' "$SETTINGS_FILE" 2>/dev/null
}

# Add or remove settings.json's statusLine key. Removing it is what makes
# Claude Code fall back to its own footer: it suppresses the built-in
# keyboard hints only while a custom status line is configured, so hiding
# every part is not the same thing (that leaves the key set and prints a
# blank row). settings.json is backed up first, and the rewrite is a
# same-directory mktemp + mv so a reader never catches a half-written file.
set_statusline_key() {
  local mode="$1" tmp filter
  [ -f "$SETTINGS_FILE" ] || { [ "$mode" = "off" ] && return 0; printf '{}\n' > "$SETTINGS_FILE"; }
  jq -e 'type == "object"' "$SETTINGS_FILE" >/dev/null 2>&1 || {
    echo "statusline-toggle: $SETTINGS_FILE is not valid JSON, leaving it alone" >&2
    return 1
  }
  cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak" 2>/dev/null
  tmp="$(mktemp "${SETTINGS_FILE}.XXXXXX")" || return 1
  if [ "$mode" = "off" ]; then
    filter='del(.statusLine)'
    jq "$filter" "$SETTINGS_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$SETTINGS_FILE" || { rm -f "$tmp"; return 1; }
  else
    jq --argjson v "$STATUSLINE_VALUE" '.statusLine = $v' "$SETTINGS_FILE" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$SETTINGS_FILE" || { rm -f "$tmp"; return 1; }
  fi
}

# Write any top-level boolean key in the config (same atomic pattern as set_part).
set_flag() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp "${CONFIG}.XXXXXX")" || return 1
  jq --argjson v "$val" ".${key} = \$v" "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# Ensure the config exists and is valid JSON; recreate with defaults otherwise.
ensure_config() {
  if [ ! -f "$CONFIG" ] || ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    printf '{\n  "model": true,\n  "cost": true,\n  "rate": true,\n  "workspace": true,\n  "emoji": false,\n  "disabled": false\n}\n' > "$CONFIG"
  fi
  # Backfill "emoji" for configs written before emoji mode existed.
  if ! jq -e 'has("emoji")' "$CONFIG" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp "${CONFIG}.XXXXXX")"
    jq '. + {emoji: false}' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
  # Same backfill for "workspace", added after the location row. Defaults to
  # true, matching statusline.sh's fail-open reading of a missing key.
  if ! jq -e 'has("workspace")' "$CONFIG" >/dev/null 2>&1; then
    local tmp2
    tmp2="$(mktemp "${CONFIG}.XXXXXX")"
    jq '. + {workspace: true}' "$CONFIG" > "$tmp2" && mv "$tmp2" "$CONFIG"
  fi
  # And for "disabled", which records that the user handed the status line
  # row back to Claude Code. Absent means not disabled, so an old config
  # keeps working exactly as before.
  if ! jq -e 'has("disabled")' "$CONFIG" >/dev/null 2>&1; then
    local tmp3
    tmp3="$(mktemp "${CONFIG}.XXXXXX")"
    jq '. + {disabled: false}' "$CONFIG" > "$tmp3" && mv "$tmp3" "$CONFIG"
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
  local p state names=(Part status-line model cost rate workspace emoji) states=(Status) name_w=0 state_w=0
  local top sep bot i

  if is_disabled; then states+=("off"); else states+=("on"); fi
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

cmd="${1:-}"

# Skip for uninstall: it must not recreate or rewrite the config it may be
# about to remove (and its warn path must leave every file untouched).
[ "$cmd" != "uninstall" ] && ensure_config

case "$cmd" in
  status)
    print_status
    ;;
  -h|--help|help)
    usage
    ;;
  off)
    if ! statusline_is_ours; then
      echo "statusline-toggle: settings.json's statusLine points at a different" >&2
      echo "status line, not ours:" >&2
      echo "  $(current_statusline_command)" >&2
      echo "Refusing to remove someone else's registration. Delete it yourself if" >&2
      echo "that is what you want." >&2
      exit 1
    fi
    if is_disabled; then
      echo "status line: already off (Claude Code's own footer is showing)"
      exit 0
    fi
    if set_statusline_key off; then
      set_flag disabled true
      echo "status line: off — Claude Code's default footer is back. Your part"
      echo "settings are kept; run 'statusline-toggle.sh on' to restore this one."
      echo "settings.json backed up to settings.json.bak."
    else
      echo "statusline-toggle: could not update settings.json, status line left on" >&2
      exit 1
    fi
    ;;
  on)
    if ! statusline_is_ours && [ "${2:-}" != "--force" ]; then
      echo "statusline-toggle: settings.json already registers a different status" >&2
      echo "line:" >&2
      echo "  $(current_statusline_command)" >&2
      echo "Refusing to overwrite it. Re-run as 'on --force' to replace it with" >&2
      echo "this one." >&2
      exit 1
    fi
    if ! is_disabled && jq -e '.statusLine' "$SETTINGS_FILE" >/dev/null 2>&1 && statusline_is_ours; then
      echo "status line: already on"
      exit 0
    fi
    if set_statusline_key on; then
      set_flag disabled false
      echo "status line: on — restored with your saved part settings."
      echo "settings.json backed up to settings.json.bak."
    else
      echo "statusline-toggle: could not update settings.json, status line left off" >&2
      exit 1
    fi
    ;;
  all)
    action="${2:-}"
    case "$action" in
      on)  val=true ;;
      off) val=false ;;
      *) echo "statusline-toggle: 'all' needs on|off" >&2; usage; exit 1 ;;
    esac
    for p in "${PARTS[@]}"; do set_part "$p" "$val"; print_one "$p" "$action"; done
    # `if`, not `is_disabled && echo`: the && form is the last command in this
    # branch, so on the normal path (not disabled) it makes a fully successful
    # run exit 1. SKILL.md shells out to this script, so a non-zero status
    # reads as a failed toggle.
    if is_disabled; then
      echo "note: the status line is off, so this takes effect after 'statusline-toggle.sh on'."
    fi
    ;;
  model|cost|rate|workspace)
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
    # See the `all` branch: the && form would make a successful toggle exit 1.
    if is_disabled; then
      echo "note: the status line is off, so this takes effect after 'statusline-toggle.sh on'."
    fi
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
  uninstall)
    yes=false
    purge=false
    for a in "$@"; do
      case "$a" in
        --yes) yes=true ;;
        --purge) purge=true ;;
      esac
    done
    if [ "$yes" != true ]; then
      echo "statusline-toggle: 'uninstall' removes the status line registration from settings.json" >&2
      echo "and deletes the installed scripts (statusline.sh, statusline-toggle.sh," >&2
      echo "cost_cache_refresh.sh) from ~/.claude/. Your toggle config, cost history and rate" >&2
      echo "cache are kept" >&2
      echo "unless --purge is also given. Re-run to confirm:" >&2
      echo "  statusline-toggle.sh uninstall --yes [--purge]" >&2
      exit 1
    fi
    SETTINGS="$HOME/.claude/settings.json"
    backed_up=false
    if [ -f "$SETTINGS" ]; then
      cp "$SETTINGS" "${SETTINGS}.bak"
      backed_up=true
      if jq -e . "$SETTINGS" >/dev/null 2>&1; then
        tmp="$(mktemp "${SETTINGS}.XXXXXX")"
        if jq 'del(.statusLine)' "$SETTINGS" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$SETTINGS"
        else
          rm -f "$tmp"
        fi
      fi
    fi
    # Clear "disabled" before leaving. A non-purge uninstall keeps the
    # config, and a config that still says disabled would make a later
    # reinstall skip registration entirely: the plugin would look installed
    # and do nothing, with nothing on screen to explain why.
    if [ "$purge" != true ] && [ -f "$CONFIG" ] && jq -e . "$CONFIG" >/dev/null 2>&1; then
      tmp="$(mktemp "${CONFIG}.XXXXXX")" \
        && jq '.disabled = false' "$CONFIG" > "$tmp" \
        && mv "$tmp" "$CONFIG" || rm -f "$tmp"
    fi
    # The sync lock holds no user data, so it goes in both paths. Leaving it
    # behind on a non-purge uninstall left a file the "kept files" message
    # never mentioned.
    rm -f "$HOME/.claude/.statusline-sync.lock"
    rm -f "$HOME/.claude/statusline.sh" "$REFRESH"
    if [ "$purge" = true ]; then
      rm -f "$CONFIG" \
            "$HOME/.claude/.cost_cache.json" \
            "$HOME/.claude/.cost_ledger.json" \
            "$HOME/.claude/.cost_baseline.json" \
            "$HOME/.claude/.cost_cache.lock" \
            "$HOME/.claude/.rate_cache.json"
    fi
    settings_note=""
    [ "$backed_up" = true ] && settings_note=" settings.json backed up to settings.json.bak."
    if [ "$purge" = true ]; then
      echo "uninstalled: removed status line registration, statusline.sh, statusline-toggle.sh, and cost_cache_refresh.sh, and purged config/cost/lock files.${settings_note}"
    else
      echo "uninstalled: removed status line registration, statusline.sh, statusline-toggle.sh, and cost_cache_refresh.sh.${settings_note} Config, cost history and rate cache were kept."
    fi
    rm -f "$HOME/.claude/statusline-toggle.sh"
    exit 0
    ;;
  "")
    usage
    exit 1
    ;;
  *)
    echo "statusline-toggle: unknown part '$cmd' (expected model|cost|rate|workspace|all|on|off|emoji|status|reset-all-time|uninstall)" >&2
    usage
    exit 1
    ;;
esac
