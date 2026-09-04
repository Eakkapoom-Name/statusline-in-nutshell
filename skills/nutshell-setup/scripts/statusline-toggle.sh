#!/usr/bin/env bash
# statusline-toggle.sh: the only writer of config.json, and the command
# behind every nutshell skill. Shows and hides the status-line parts,
# switches emoji labels, hands the row back to Claude Code and takes it
# again, resets the all-time cost, and uninstalls.
#
# The status line (statusline.sh) has four parts:
#   model    : model name / advisor / context bar          (line 1)
#              ALWAYS ON. It cannot be hidden and `all` skips it, so line 1
#              always renders and the row never collapses to nothing.
#   cost     : current session / today / week / month / all-time (line 2)
#   session  : usage limits, current 5-hour window + current week (line 3)
#   workspace: current directory / repo / git branch          (line 4)
#
# Independently of those, "emoji" swaps text labels ("model:", "current
# session:", ...) for icons everywhere. Default OFF (fail-closed), unlike
# the parts, which fail open (missing key = shown): a missing or bad emoji
# key must not silently switch the status line to icons the user did not
# ask for.
#
# Changes take effect within ~1s (statusline refreshInterval), no restart.

set -euo pipefail

case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
if ! . "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null; then
  echo "statusline-toggle: $NUT_LIB_DIR/nutshell-lib.sh is missing; run the nutshell-setup skill to repair the install" >&2
  exit 1
fi

PARTS=(model cost session workspace)
# The parts `all` acts on, and the only ones that accept on/off/toggle.
# model is absent on purpose: pinning it on is what stops `all off` from
# leaving an empty row that shows neither our lines nor Claude Code's own
# footer hints (those stay suppressed while the statusLine key is set).
TOGGLEABLE_PARTS=(cost session workspace)
REFRESH="$NUT_BIN_DIR/cost_cache_refresh.sh"
DEFAULT_CONFIG='{
  "model": true,
  "cost": true,
  "session": true,
  "workspace": true,
  "emoji": false,
  "disabled": false
}'

usage() {
  cat <<'USAGE'
Usage:
  statusline-toggle.sh <part> <on|off|toggle>   # part = cost | session | workspace
  statusline-toggle.sh all <on|off>             # cost, session, workspace (not model)
  statusline-toggle.sh off                      # hand the row back to Claude Code's own footer
  statusline-toggle.sh on [--force]             # take it back, with your saved part settings
  statusline-toggle.sh emoji [on|off|toggle]    # no arg = toggle; default off
  statusline-toggle.sh status
  statusline-toggle.sh reset-all-time --yes     # reset all-time cost to 0 (keeps today/week/month)
  statusline-toggle.sh uninstall --yes [--purge] # remove registration + installed scripts

Parts:
  model  model name / advisor / context bar               (line 1)
         always on: it cannot be hidden and `all` skips it
  cost   current session / today / week / month / all-time spend (line 2)
  session  usage limits: current 5-hour window + current week (line 3)
  workspace current directory / repo / git branch          (line 4)
  emoji  replace text labels with icons across all shown parts (default off)

on / off vs show / hide:
  `off` removes the statusLine registration from settings.json, so Claude
  Code shows its own footer again. `all off` only hides cost, session and
  workspace; line 1 stays, and so does the registration, so that footer
  stays suppressed. Use `off` to get the default back.
USAGE
}

# ---------------------------------------------------------------------------
# config.json
# ---------------------------------------------------------------------------

# Make sure the config exists, is a JSON object, and carries every key the
# current version expects. Recreates it with defaults otherwise, and
# migrates in one pass:
#   - "rate" (the session part's name before v0.3.0) becomes "session",
#     keeping the saved value so a hidden line stays hidden. If both exist,
#     "session" wins and the stale "rate" is dropped.
#   - "model" is pinned to true. It is not toggleable, but a config written
#     before that rule (or hand-edited) can still carry false, which would
#     hide line 1 and let `all off` leave an empty row.
#   - "emoji", "workspace" and "disabled" are backfilled for configs written
#     before each existed, with the same defaults their readers assume.
ensure_config() {
  if ! jq -e 'type == "object"' "$NUT_CONFIG" >/dev/null 2>&1; then
    printf '%s\n' "$DEFAULT_CONFIG" > "$NUT_CONFIG"
    return 0
  fi
  if jq -e 'has("rate") or (.model | tostring) != "true" or (has("emoji") | not) or (has("workspace") | not) or (has("disabled") | not)' \
       "$NUT_CONFIG" >/dev/null 2>&1; then
    nut_jq_edit "$NUT_CONFIG" '
      (if has("rate") then (if has("session") then del(.rate) else .session = .rate | del(.rate) end) else . end)
      | .model = true
      | (if has("emoji") then . else .emoji = false end)
      | (if has("workspace") then . else .workspace = true end)
      | (if has("disabled") then . else .disabled = false end)'
  fi
}

# A part's current value ("true"/"false"); a missing key defaults to true.
# Only a literal "false" counts as off (jq's // would turn false into the
# default). Mirrors statusline.sh's fail-open reading.
get_part() {
  [ "$(nut_config_raw "$1")" = "false" ] && echo false || echo true
}

# Emoji's current value; missing or bad defaults to false (fail-closed).
get_emoji() {
  [ "$(nut_config_raw emoji)" = "true" ] && echo true || echo false
}

# Set any top-level key to a JSON value, atomically, so statusline.sh never
# sees a half-written file.
set_key() {
  nut_jq_edit "$NUT_CONFIG" --argjson v "$2" ".${1} = \$v"
}

# Part, emoji and reset commands refuse while the status line is inactive
# (handed back to Claude Code with `off`), since nothing they change would
# be visible. `status`, `on`, `off` and `uninstall` still work.
require_active() {
  if nut_config_is_disabled; then
    echo "status line: inactive. Run 'statusline-toggle.sh on' (the nutshell-active skill) first." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# settings.json
# ---------------------------------------------------------------------------

# Add ("on") or remove ("off") the statusLine key. A settings.json that is
# not a JSON object is refused rather than rewritten, so there is no edit
# a backup would protect; nothing here writes a .bak.
set_statusline_key() {
  local rc=0
  if [ "$1" = off ]; then
    nut_settings_unregister || rc=$?
  else
    nut_settings_register || rc=$?
  fi
  [ "$rc" -eq 1 ] && echo "statusline-toggle: $NUT_SETTINGS is not valid JSON, leaving it alone" >&2
  return "$rc"
}

refuse_foreign_statusline() {  # verb-phrase
  echo "statusline-toggle: settings.json's statusLine points at a different" >&2
  echo "status line, not ours:" >&2
  echo "  $(jq -r '.statusLine.command // "(none)"' "$NUT_SETTINGS" 2>/dev/null)" >&2
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

# Full box-drawn table, only for the explicit "status" command.
print_status() {
  local p state names=(Part status-line model cost session workspace emoji) states=(Status) name_w=0 state_w=0
  local top sep bot i name_dashes state_dashes

  if nut_config_is_disabled; then states+=("off"); else states+=("on"); fi
  for p in "${PARTS[@]}"; do
    if [ "$p" = model ]; then states+=("on (always)")
    elif [ "$(get_part "$p")" = "false" ]; then states+=("off")
    else states+=("on"); fi
  done
  if [ "$(get_emoji)" = "true" ]; then states+=("on"); else states+=("off"); fi

  for p in "${names[@]}"; do [ "${#p}" -gt "$name_w" ] && name_w="${#p}"; done
  for state in "${states[@]}"; do [ "${#state}" -gt "$state_w" ] && state_w="${#state}"; done

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

# One-line confirmation, used by the toggle actions instead of the table.
print_one() {
  printf '%s: %s\n' "$1" "$2"
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_off() {
  if ! nut_statusline_is_ours; then
    refuse_foreign_statusline
    echo "Refusing to remove someone else's registration. Delete it yourself if" >&2
    echo "that is what you want." >&2
    exit 1
  fi
  # Both halves must already be off to pass, mirroring `on`. The flag alone
  # is not enough: a config that says disabled while settings.json still
  # registers our command is the one state that renders nothing AND keeps
  # Claude Code's footer hints suppressed (statusline.sh exits on the flag
  # while the key keeps the row reserved). Falling through deletes the
  # stray key instead of reporting a state we are not actually in.
  if nut_config_is_disabled && ! jq -e '.statusLine' "$NUT_SETTINGS" >/dev/null 2>&1; then
    echo "status line: already off (Claude Code's own footer is showing)"
    exit 0
  fi
  if set_statusline_key off; then
    set_key disabled true
    echo "status line: off. Claude Code's default footer is back. Your part"
    echo "settings are kept; run 'statusline-toggle.sh on' to restore this one."
  else
    echo "statusline-toggle: could not update settings.json, status line left on" >&2
    exit 1
  fi
}

cmd_on() {
  if ! nut_statusline_is_ours && [ "${1:-}" != "--force" ]; then
    echo "statusline-toggle: settings.json already registers a different status" >&2
    echo "line:" >&2
    echo "  $(jq -r '.statusLine.command // "(none)"' "$NUT_SETTINGS" 2>/dev/null)" >&2
    echo "Refusing to overwrite it. Re-run as 'on --force' to replace it with" >&2
    echo "this one." >&2
    exit 1
  fi
  if ! nut_config_is_disabled && jq -e '.statusLine' "$NUT_SETTINGS" >/dev/null 2>&1 && nut_statusline_is_ours; then
    echo "status line: already on"
    exit 0
  fi
  if set_statusline_key on; then
    set_key disabled false
    echo "status line: on, restored with your saved part settings."
  else
    echo "statusline-toggle: could not update settings.json, status line left off" >&2
    exit 1
  fi
}

cmd_all() {
  local action="${1:-}" val p
  require_active
  case "$action" in
    on)  val=true ;;
    off) val=false ;;
    *) echo "statusline-toggle: 'all' needs on|off" >&2; usage; exit 1 ;;
  esac
  for p in "${TOGGLEABLE_PARTS[@]}"; do set_key "$p" "$val"; print_one "$p" "$action"; done
  print_one model "on (always)"
}

cmd_model() {
  require_active
  case "${1:-}" in
    on)
      # Already the only possible state; report it rather than erroring.
      print_one model "on (always)"
      ;;
    off|toggle)
      echo "statusline-toggle: model cannot be hidden, it is always shown." >&2
      echo "Line 1 is what keeps the row from collapsing to nothing: the" >&2
      echo "statusLine key stays registered while parts are merely hidden," >&2
      echo "so Claude Code keeps its own footer hints suppressed and you" >&2
      echo "would be left with an empty row. To hand the whole row back to" >&2
      echo "Claude Code, run 'statusline-toggle.sh off' instead." >&2
      exit 1
      ;;
    *) echo "statusline-toggle: model only accepts on (it is always shown)" >&2; usage; exit 1 ;;
  esac
}

cmd_part() {  # part action
  local part="$1" action="${2:-}"
  require_active
  case "$action" in
    on)  set_key "$part" true ;;
    off) set_key "$part" false ;;
    toggle)
      if [ "$(get_part "$part")" = "false" ]; then set_key "$part" true; action=on; else set_key "$part" false; action=off; fi
      ;;
    *) echo "statusline-toggle: '$part' needs on|off|toggle" >&2; usage; exit 1 ;;
  esac
  print_one "$part" "$action"
}

cmd_emoji() {
  local action="${1:-toggle}"
  require_active
  case "$action" in
    on)  set_key emoji true ;;
    off) set_key emoji false ;;
    toggle)
      if [ "$(get_emoji)" = "false" ]; then set_key emoji true; action=on; else set_key emoji false; action=off; fi
      ;;
    *) echo "statusline-toggle: 'emoji' needs on|off|toggle" >&2; usage; exit 1 ;;
  esac
  print_one emoji "$action"
}

cmd_reset_all_time() {
  local reset_cmd
  require_active
  if [ "${1:-}" != "--yes" ]; then
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
  # timeout is GNU coreutils and absent on macOS; run without one there.
  if command -v timeout >/dev/null 2>&1; then
    reset_cmd=(timeout 90 bash "$REFRESH" --reset-all-time)
  else
    reset_cmd=(bash "$REFRESH" --reset-all-time)
  fi
  if ! "${reset_cmd[@]}"; then
    echo "statusline-toggle: reset failed or timed out" >&2
    exit 1
  fi
  echo "done: all-time cost is now 0; today / week / month are unchanged."
}

# Remove the registration and the installed scripts. Config, cost history
# and caches are kept unless --purge is given. ensure_config is skipped for
# this command: it must not recreate or rewrite the config it may be about
# to remove, and the warn path must leave every file untouched.
cmd_uninstall() {
  local yes=false purge=false a f
  for a in "$@"; do
    case "$a" in
      --yes) yes=true ;;
      --purge) purge=true ;;
    esac
  done
  if [ "$yes" != true ]; then
    echo "statusline-toggle: 'uninstall' removes the status line registration from settings.json" >&2
    echo "and deletes the installed scripts from ~/.claude/nutshell/bin/. Your toggle" >&2
    echo "config, cost history and rate cache are kept unless --purge is also given." >&2
    echo "Re-run to confirm:" >&2
    echo "  statusline-toggle.sh uninstall --yes [--purge]" >&2
    exit 1
  fi
  nut_settings_unregister || true
  # Clear "disabled" before leaving. A non-purge uninstall keeps the config,
  # and a config that still says disabled would make a later reinstall skip
  # registration entirely: the plugin would look installed and do nothing,
  # with nothing on screen to explain why.
  if [ "$purge" != true ] && [ -f "$NUT_CONFIG" ] && jq -e . "$NUT_CONFIG" >/dev/null 2>&1; then
    nut_jq_edit "$NUT_CONFIG" '.disabled = false' || true
  fi
  # Locks hold no user data, so they go in both paths. Leaving one behind
  # on a non-purge uninstall leaves a file the "kept files" message never
  # mentions.
  rm -f "$NUT_SYNC_LOCK" "$NUT_COST_LOCK" "$NUT_AUTH_LOCK"
  # Every installed script but this one, which goes last so the message
  # below always gets printed.
  for f in $NUT_INSTALLED_FILES; do
    [ "$f" = statusline-toggle.sh ] || rm -f "$NUT_BIN_DIR/$f"
  done
  # Files a pre-0.3.1 install left directly in ~/.claude. Exact names only,
  # never a glob, and only the ones this plugin is known to have written.
  rm -f "$NUT_CLAUDE_DIR/statusline.sh" \
        "$NUT_CLAUDE_DIR/cost_cache_refresh.sh" \
        "$NUT_CLAUDE_DIR/.statusline-sync.lock"
  if [ "$purge" = true ]; then
    rm -f "$NUT_CONFIG" \
          "$NUT_COST_CACHE" "$NUT_COST_LEDGER" "$NUT_COST_BASELINE" \
          "$NUT_RATE_CACHE" "$NUT_AUTH_CACHE"
    # Extra per-source ledgers, written by other tools and folded into the
    # cost windows by the refresher. A glob, since the source names are not
    # ours to know; with no match the literal pattern reaches rm -f, which
    # ignores a path that does not exist.
    rm -f "$NUT_EXTRA_LEDGER_PREFIX"*.json
    # And the pre-0.3.1 equivalents of all of the above, for an install that
    # was never migrated (or that kept writing to the old paths), plus the
    # .bak files those versions wrote. settings.json.bak in particular may
    # hold a user's only copy of their pre-install settings, so only an
    # explicit --purge takes it.
    rm -f "$NUT_OLD_CONFIG"
    for f in $NUT_OLD_STATE_FILES $NUT_OLD_LOCK_FILES $NUT_OLD_BAK_FILES; do
      rm -f "$NUT_CLAUDE_DIR/$f"
    done
    rm -f "$NUT_OLD_EXTRA_LEDGER_PREFIX"*.json
  fi
  if [ "$purge" = true ]; then
    echo "uninstalled: removed the status line registration and the scripts under ~/.claude/nutshell/bin/, and purged config/cost/lock files plus any .bak files left by versions before 0.3.1."
  else
    echo "uninstalled: removed the status line registration and the scripts under ~/.claude/nutshell/bin/. Config, cost history, rate cache, auth cache and any .bak files from versions before 0.3.1 were kept."
  fi
  rm -f "$NUT_BIN_DIR/statusline-toggle.sh" "$NUT_CLAUDE_DIR/statusline-toggle.sh"
  # Drop the directories once their contents are gone. rmdir, never `rm -r`:
  # it removes bin/, state/, locks/ and nutshell/ only while they are empty,
  # so anything unexpected in there (a file a future version writes,
  # something the user put there) survives instead of being deleted by a
  # recursive sweep this script cannot audit.
  #
  # `|| true` because a non-empty directory is the NORMAL outcome here: a
  # non-purge uninstall keeps config.json and everything under state/, so
  # this rmdir always fails, and under `set -e` that failure exited the
  # script with status 1 right after printing the success message. The
  # nutshell-uninstall skill shells out to this script, so a successful
  # uninstall read as a failed one.
  rmdir "$NUT_BIN_DIR" "$NUT_STATE_DIR" "$NUT_LOCK_DIR" "$NUT_DIR" 2>/dev/null || true
  exit 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local cmd="${1:-}"
  command -v jq >/dev/null 2>&1 || { echo "statusline-toggle: jq is required" >&2; exit 1; }
  [ -d "$NUT_DIR" ] || mkdir -p "$NUT_DIR" 2>/dev/null
  [ "$cmd" != "uninstall" ] && ensure_config
  case "$cmd" in
    status)                 print_status ;;
    -h|--help|help)         usage ;;
    off)                    cmd_off ;;
    on)                     cmd_on "${2:-}" ;;
    all)                    cmd_all "${2:-}" ;;
    model)                  cmd_model "${2:-}" ;;
    cost|session|workspace) cmd_part "$cmd" "${2:-}" ;;
    emoji)                  cmd_emoji "${2:-}" ;;
    reset-all-time)         cmd_reset_all_time "${2:-}" ;;
    uninstall)              shift; cmd_uninstall "$@" ;;
    "")                     usage; exit 1 ;;
    *)
      echo "statusline-toggle: unknown part '$cmd' (expected model|cost|session|workspace|all|on|off|emoji|status|reset-all-time|uninstall)" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
