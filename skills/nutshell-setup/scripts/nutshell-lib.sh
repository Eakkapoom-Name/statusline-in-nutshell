#!/usr/bin/env bash
# nutshell-lib.sh: shared definitions for every nutshell script.
#
# Sourced, never executed. It defines the paths this plugin owns, the one
# copy of the settings.json registration, and the handful of helpers the
# scripts share (atomic writes, config and settings reads, the pre-0.3.1
# migration). It has no side effects beyond definitions and prints nothing:
# statusline.sh sources it once a second, and the hooks source it under
# `exec 2>/dev/null`.
#
# Portability is binding here as in every script: stock bash 3.2 (macOS),
# BSD userland, no GNU coreutils assumed. No namerefs, no associative
# arrays, and `flock`, `timeout`, `date -d` and `stat -c` are guarded or
# paired with their BSD form wherever they appear.

# Locale pin. `date +%p` is empty where the locale defines no am/pm strings,
# and a comma-decimal locale makes bash's printf '%.2f' reject the
# dot-decimal numbers jq hands us. C is defined everywhere and formats both
# the way these scripts assume.
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Paths. Everything this plugin owns lives under ~/.claude/nutshell/ (since
# 0.3.1). Only settings.json and .credentials.json are read from ~/.claude
# itself, and both belong to Claude Code, not to us.
# ---------------------------------------------------------------------------
NUT_CLAUDE_DIR="$HOME/.claude"
NUT_DIR="$NUT_CLAUDE_DIR/nutshell"
NUT_BIN_DIR="$NUT_DIR/bin"
NUT_STATE_DIR="$NUT_DIR/state"
NUT_LOCK_DIR="$NUT_DIR/locks"
NUT_CONFIG="$NUT_DIR/config.json"

NUT_COST_CACHE="$NUT_STATE_DIR/cost_cache.json"
NUT_COST_LEDGER="$NUT_STATE_DIR/cost_ledger.json"
NUT_COST_BASELINE="$NUT_STATE_DIR/cost_baseline.json"
NUT_RATE_CACHE="$NUT_STATE_DIR/rate_cache.json"
NUT_AUTH_CACHE="$NUT_STATE_DIR/auth_cache.json"
# Extra per-source ledgers written by other tools: ${NUT_EXTRA_LEDGER_PREFIX}<source>.json
NUT_EXTRA_LEDGER_PREFIX="$NUT_STATE_DIR/ledger_"

NUT_SYNC_LOCK="$NUT_LOCK_DIR/sync.lock"
NUT_COST_LOCK="$NUT_LOCK_DIR/cost_cache.lock"
NUT_AUTH_LOCK="$NUT_LOCK_DIR/auth_cache.lock"

NUT_SETTINGS="$NUT_CLAUDE_DIR/settings.json"
NUT_CREDENTIALS="$NUT_CLAUDE_DIR/.credentials.json"

# The scripts installed into bin/, in install order. This library goes
# first so no script ever lands before the file it sources.
NUT_INSTALLED_FILES="nutshell-lib.sh statusline.sh statusline-toggle.sh cost_cache_refresh.sh auth_cache_refresh.sh"

# The settings.json registration. This is the only copy: sync.sh, the setup
# skill (which runs sync.sh) and statusline-toggle.sh all register from it,
# so they can never disagree and rewrite each other at every session start.
#
# refreshInterval is required, not cosmetic. Claude Code re-runs the command
# on a few events (session start, a new assistant message, /compact, a
# permission-mode change) and otherwise not at all, so every segment read
# from disk rather than from the stdin payload (advisor, cost, rate cache)
# would sit stale while the session idles. A 1s timer re-runs it on a clock.
NUT_STATUSLINE_VALUE='{"type":"command","command":"bash ~/.claude/nutshell/bin/statusline.sh","refreshInterval":1}'

# ---------------------------------------------------------------------------
# The pre-0.3.1 layout, when all of this sat loose in ~/.claude. Needed by
# the migration below and by `uninstall --purge`, which sweeps an install
# that was never migrated.
# ---------------------------------------------------------------------------
NUT_OLD_CONFIG="$NUT_CLAUDE_DIR/statusline.config.json"
# State files: the new name is the old one without its leading dot.
NUT_OLD_STATE_FILES=".cost_cache.json .cost_ledger.json .cost_baseline.json .rate_cache.json .auth_cache.json"
NUT_OLD_LOCK_FILES=".cost_cache.lock .auth_cache.json.lock .statusline-sync.lock"
NUT_OLD_SCRIPTS="statusline.sh statusline-toggle.sh cost_cache_refresh.sh"
# Backups written by versions before 0.3.1, which is when this plugin
# stopped writing any. settings.json.bak may be a user's only copy of their
# pre-install settings, so only an explicit --purge ever removes these.
NUT_OLD_BAK_FILES="statusline.sh.bak statusline-toggle.sh.bak cost_cache_refresh.sh.bak settings.json.bak"
# Extra ledgers: ${NUT_OLD_EXTRA_LEDGER_PREFIX}<source>.json
NUT_OLD_EXTRA_LEDGER_PREFIX="$NUT_CLAUDE_DIR/.cost_ledger_"

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

# Create state/ and locks/ rather than trusting the sync hook to have done
# it. A missing locks/ is not cosmetic: `exec 9>"$lock"` on a path whose
# directory does not exist fails, and a failed redirection on `exec`
# terminates the shell, so a whole refresh would die before writing
# anything. Guarded by a test so the common case forks no mkdir: this runs
# on every render of statusline.sh.
nut_ensure_dirs() {
  [ -d "$NUT_STATE_DIR" ] && [ -d "$NUT_LOCK_DIR" ] \
    || mkdir -p "$NUT_STATE_DIR" "$NUT_LOCK_DIR" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

# Modification time of a file as unix seconds, GNU (-c) or BSD (-f) stat.
# Prints nothing when the file is absent or neither flavour is understood,
# which reads as "no signal" wherever it is used, never as "changed".
nut_mtime() {
  [ -e "$1" ] || return 1
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Write $1 (text, no trailing newline added) to file $2 atomically: a
# same-directory mktemp, then a rename. Same directory, not the default
# /tmp, so the mv is a same-filesystem rename a concurrent reader cannot
# catch half-written; a unique temp name, not a fixed "$target.tmp", so two
# writers running at once (stock macOS has no flock) cannot truncate each
# other's file. Returns 1 with the temp file removed on any failure.
nut_write_atomic() {
  local content="$1" target="$2" tmp
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
  if printf '%s' "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$target" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# nut_write_atomic, but only when $1 is a non-empty JSON object. Protects a
# ledger or cache from being truncated, or replaced with garbage, when an
# upstream jq step silently produced empty or malformed output. On failure
# the existing file is left untouched.
nut_write_json_object() {
  local content="$1" target="$2" tmp
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
  printf '%s' "$content" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ] && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$target" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
}

# Rewrite JSON file $1 in place through jq: the remaining arguments are
# passed to jq as-is (options, then the filter), the file is appended.
# Atomic like nut_write_atomic. Returns 1 with nothing changed on failure.
nut_jq_edit() {
  local target="$1" tmp
  shift
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
  if jq "$@" "$target" > "$tmp" 2>/dev/null && mv "$tmp" "$target" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Start a background job that outlives this script and is never awaited.
nut_spawn() {
  ( nohup "$@" >/dev/null 2>&1 & disown ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# config.json (written only by statusline-toggle.sh)
# ---------------------------------------------------------------------------

# Raw text of a top-level config key: "true", "false", "null" for a missing
# key, nothing at all for a missing or unreadable file. Callers decide the
# default, and they differ on purpose: the show/hide parts fail open (only
# "false" hides), emoji fails closed (only "true" enables), disabled fails
# open (only "true" disables).
nut_config_raw() {
  jq -r ".$1" "$NUT_CONFIG" 2>/dev/null
}

# True when the user handed the status line row back to Claude Code with
# `statusline-toggle.sh off` (the nutshell-inactive skill).
nut_config_is_disabled() {
  [ "$(nut_config_raw disabled)" = "true" ]
}

# ---------------------------------------------------------------------------
# settings.json (Claude Code's file; only the statusLine key is ours)
# ---------------------------------------------------------------------------

# The command currently registered, or nothing.
nut_registered_command() {
  jq -r '.statusLine.command // empty' "$NUT_SETTINGS" 2>/dev/null
}

# The registered statusLine value as compact JSON, or nothing.
nut_registered_value() {
  jq -c '.statusLine // empty' "$NUT_SETTINGS" 2>/dev/null
}

# True when settings.json's statusLine is absent, or is one we installed.
# Anyone can register a status line (Claude Code's own /statusline writes
# one from your shell PS1), and someone else's registration must never be
# deleted or overwritten. Ours is recognised by the command pointing at our
# script, at the current path or at the pre-0.3.1 one: an old install has
# to be recognised as ours, or `on`, `off`, `uninstall` and the sync hook
# would all refuse to touch it.
nut_statusline_is_ours() {
  local cmd
  [ -f "$NUT_SETTINGS" ] || return 0
  cmd=$(nut_registered_command)
  case "$cmd" in
    ''|*'/.claude/nutshell/bin/statusline.sh'*|*'/.claude/statusline.sh'*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when settings.json exists and is a JSON object. Anything else
# (missing, corrupt, valid JSON that is not an object such as `[1,2]`)
# must be left exactly as the user left it: every edit below would fail on
# it anyway, and rewriting it would destroy settings this plugin does not
# own and never backs up.
nut_settings_is_object() {
  jq -e 'type == "object"' "$NUT_SETTINGS" >/dev/null 2>&1
}

# Add our statusLine key to settings.json, creating the file when absent.
# Returns 0 when written, 1 when the file exists but is not a JSON object
# (left untouched), 2 when the write itself failed.
nut_settings_register() {
  [ -f "$NUT_SETTINGS" ] || printf '{}\n' > "$NUT_SETTINGS" 2>/dev/null
  nut_settings_is_object || return 1
  nut_jq_edit "$NUT_SETTINGS" --argjson v "$NUT_STATUSLINE_VALUE" '.statusLine = $v' || return 2
}

# Remove the statusLine key. Same return codes; a missing file is 0, there
# is nothing to remove. Removing the key is what makes Claude Code show its
# own footer again: it suppresses its built-in keyboard hints only while a
# custom status line is configured, so hiding every part is not the same
# thing (that leaves the key set and the row simply empty).
nut_settings_unregister() {
  [ -f "$NUT_SETTINGS" ] || return 0
  nut_settings_is_object || return 1
  nut_jq_edit "$NUT_SETTINGS" 'del(.statusLine)' || return 2
}

# ---------------------------------------------------------------------------
# Migration from the pre-0.3.1 layout
# ---------------------------------------------------------------------------

# Move $1 to $2 when $1 exists and $2 does not. Move, never copy: two files
# claiming to be the same ledger is worse than one in the wrong place. The
# destination check is what lets a half-migrated install finish cleanly and
# an already-migrated one stay untouched.
nut_migrate_one() {
  [ -e "$1" ] || return 0
  [ -e "$2" ] && return 0
  mv "$1" "$2" 2>/dev/null
}

# Move the config, the state files and the extra ledgers from ~/.claude
# into ~/.claude/nutshell/, and delete the old locks (they hold nothing).
# The old scripts are NOT touched here: the installer deletes them only
# once every new script is in place, since until then they are the working
# install. Callers hold the sync lock so two sessions starting together
# cannot both migrate.
nut_migrate_legacy_layout() {
  local f old
  nut_migrate_one "$NUT_OLD_CONFIG" "$NUT_CONFIG"
  for f in $NUT_OLD_STATE_FILES; do
    nut_migrate_one "$NUT_CLAUDE_DIR/$f" "$NUT_STATE_DIR/${f#.}"
  done
  # The source names are not ours to know, hence a glob. The tool writing
  # one has to be repointed at the new path by its owner; this rescues the
  # history, it cannot redirect a third-party writer.
  for old in "$NUT_OLD_EXTRA_LEDGER_PREFIX"*.json; do
    [ -f "$old" ] || continue
    nut_migrate_one "$old" "$NUT_EXTRA_LEDGER_PREFIX${old#"$NUT_OLD_EXTRA_LEDGER_PREFIX"}"
  done
  for f in $NUT_OLD_LOCK_FILES; do
    rm -f "$NUT_CLAUDE_DIR/$f" 2>/dev/null
  done
}
