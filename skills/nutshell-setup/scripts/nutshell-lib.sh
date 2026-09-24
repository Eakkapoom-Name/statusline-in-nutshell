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
# Per-model weekly windows from the account usage endpoint. Written only by
# usage_cache_refresh.sh, the one job in this plugin that touches the network.
NUT_USAGE_CACHE="$NUT_STATE_DIR/usage_cache.json"
# Extra per-source ledgers written by other tools: ${NUT_EXTRA_LEDGER_PREFIX}<source>.json
NUT_EXTRA_LEDGER_PREFIX="$NUT_STATE_DIR/ledger_"

NUT_SYNC_LOCK="$NUT_LOCK_DIR/sync.lock"
NUT_COST_LOCK="$NUT_LOCK_DIR/cost_cache.lock"
NUT_AUTH_LOCK="$NUT_LOCK_DIR/auth_cache.lock"
NUT_USAGE_LOCK="$NUT_LOCK_DIR/usage_cache.lock"

NUT_SETTINGS="$NUT_CLAUDE_DIR/settings.json"
NUT_CREDENTIALS="$NUT_CLAUDE_DIR/.credentials.json"

# The scripts installed into bin/, in install order. This library goes
# first so no script ever lands before the file it sources.
NUT_INSTALLED_FILES="nutshell-lib.sh statusline.sh statusline-toggle.sh cost_cache_refresh.sh auth_cache_refresh.sh usage_cache_refresh.sh"

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
# upstream jq step silently produced empty or malformed output: rejected
# content leaves the existing file untouched and returns 0 (there was
# nothing to write). Only a failed mktemp or rename returns 1, which is
# what `reset-all-time` reads as "the reset did not land".
nut_write_json_object() {
  local content="$1" target="$2" tmp
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
  printf '%s' "$content" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ] && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$target" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# Rewrite JSON file $1 in place through jq: the remaining arguments are
# passed to jq as-is (options, then the filter), the file is appended.
# Atomic like nut_write_atomic. Returns 1 with nothing changed on failure.
# jq's own diagnostics are left on stderr; a caller that wants silence adds
# its own `2>/dev/null`.
nut_jq_edit() {
  local target="$1" tmp
  shift
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
  if jq "$@" "$target" > "$tmp" && mv "$tmp" "$target" 2>/dev/null; then
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
# Locks and timeouts
#
# flock is util-linux: absent on stock macOS, and not reliably present in
# the bash Git for Windows ships. timeout is GNU coreutils, absent on
# macOS for the same reason. Both used to be optional, with the scripts
# running unserialised and unbounded where they were missing. These two
# helpers remove that split so all three platforms behave alike.
#
# The lock is a file created with O_EXCL through bash's own noclobber
# redirection, which is atomic on ext4, btrfs, APFS, HFS+ and on NTFS
# through the Cygwin layer. It costs no fork, which matters because the
# refreshers are spawned from a render path that was cut from 67 forks to
# 11 for exactly this reason.
#
# Why not use flock where it exists and this only as the fallback: the two
# mechanisms do not exclude each other. Claude Code's spawned PATH is not
# always the terminal's (the same difference that hides a user-local
# ccusage from the refresher), so a background refresher could take the
# file lock while a terminal's reset-all-time took the kernel lock on the
# same path, and both would run. One mechanism everywhere is what makes
# the guarantee real.
#
# What is given up against flock: the kernel releases a flock when the
# holder dies, however it dies, and a file outlives its owner. The stale
# break below is the answer, and it is why every lock carries a maximum
# age. Two waiters can still both judge a lock dead and both take it; that
# window is small and its cost is the duplicated work the lock exists to
# avoid, never lost data, since every write in this plugin is a rename of
# a temp file and every merge is idempotent.
#
# The held file is "<lock>.held" rather than the lock path itself, because
# pre-0.3.4 installs left an empty sync.lock, cost_cache.lock and
# auth_cache.lock on disk as flock's fd targets. Reusing those paths would
# read every upgraded install as permanently locked until the stale break
# fired.
# ---------------------------------------------------------------------------

# Seconds after which a held lock is treated as abandoned. Per call site,
# because the jobs differ by two orders of magnitude: the sync hook and the
# auth probe are seconds, a full ccusage rescan is 5 to 14 and a
# reset-all-time is capped at 90.
NUT_LOCK_STALE_SYNC=60
NUT_LOCK_STALE_AUTH=60
NUT_LOCK_STALE_COST=120
# One HTTP call under an 8s curl limit inside a 15s nut_timeout, so a holder
# still on its feet after 60s is a dead one.
NUT_LOCK_STALE_USAGE=60

# Try to take lock $1, whose holder is stale after $2 seconds. Returns 0
# with the lock held and an EXIT trap set to release it, 1 when someone
# else holds it. Never blocks.
#
# noclobber is saved and restored around the attempt: leaving it on would
# break every later plain redirection in the caller, including the temp
# file writes in nut_write_atomic. The trap is built with the path already
# expanded, so it releases this lock and not whatever $1 holds later.
nut_lock_acquire() {
  local lock="$1.held" stale="${2:-$NUT_LOCK_STALE_COST}" had_noclobber=0 rc age now
  case "$-" in *C*) had_noclobber=1 ;; esac
  set -o noclobber
  { printf '%s\n' "$$" > "$lock"; } 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Held, or left behind by a process that died. Age decides which.
    now=$(date +%s 2>/dev/null) || now=""
    age=$(nut_mtime "$lock" 2>/dev/null) || age=""
    if [ -n "$now" ] && [ -n "$age" ] && [ "$((now - age))" -ge "$stale" ]; then
      rm -f "$lock" 2>/dev/null
      { printf '%s\n' "$$" > "$lock"; } 2>/dev/null
      rc=$?
    fi
  fi
  [ "$had_noclobber" -eq 1 ] || set +o noclobber
  [ "$rc" -eq 0 ] || return 1
  # EXIT releases on a normal end. The three signal traps release AND exit,
  # which the combined form "trap ... EXIT INT TERM HUP" does not do: a
  # handled signal there runs the handler and RESUMES the script. That is
  # not academic. nut_timeout signals the process group of a reset that ran
  # long, and a refresher that caught TERM, dropped its lock and carried on
  # would finish its pipeline on half-killed input, write nothing (the
  # content is rejected), exit 0, and let statusline-toggle.sh report
  # "done: all-time cost is now 0" for a reset that never happened.
  trap "rm -f '$lock' 2>/dev/null" EXIT
  trap "rm -f '$lock' 2>/dev/null; exit 143" TERM
  trap "rm -f '$lock' 2>/dev/null; exit 130" INT
  trap "rm -f '$lock' 2>/dev/null; exit 129" HUP
  return 0
}

# Wait for lock $1 (stale after $2 seconds) for at most $3 seconds, then
# give up and return 1. Used by reset-all-time, which must not be silently
# skipped the way a background refresh is. The retry interval is a whole
# second: POSIX sleep promises no fractions and bash 3.2 is the floor.
nut_lock_wait() {
  local lock="$1" stale="${2:-$NUT_LOCK_STALE_COST}" max="${3:-120}" waited=0
  while ! nut_lock_acquire "$lock" "$stale"; do
    [ "$waited" -lt "$max" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

# Release lock $1 and clear the trap nut_lock_acquire set.
nut_lock_release() {
  rm -f "$1.held" 2>/dev/null
  trap - EXIT INT TERM HUP
  return 0
}

# Run "$@" with a limit of $1 seconds. Uses GNU timeout when it is there,
# since it needs no extra processes; falls back to a watcher subshell.
#
# The watcher's own output is sent to /dev/null, and that redirection is
# load bearing rather than tidy: this function is called inside $(...),
# and a command substitution returns only once every writer to the capture
# pipe has closed it. A watcher that inherited the pipe would hold it for
# the whole limit, so a 170ms auth probe under a 15s limit would take 15s.
#
# rc is collected with `|| rc=$?` because statusline-toggle.sh runs under
# `set -e`, where a bare `wait` on a non-zero child exits the script before
# the next line runs. A command killed by the watcher returns 143 rather
# than GNU timeout's 124; both callers test zero against non-zero only, so
# the distinction is not worth a marker file to recover.
# True only for GNU coreutils timeout. The name alone is not enough: the
# bash Git for Windows ships has C:\Windows\System32\timeout.exe on its
# PATH, which is cmd's "wait N seconds and swallow a keypress" and rejects
# a command argument outright. Probed once per shell and remembered, so the
# check costs one fork per script rather than one per call.
nut_have_gnu_timeout() {
  if [ -z "${NUT_GNU_TIMEOUT:-}" ]; then
    if timeout --version 2>/dev/null | head -1 | grep -qi coreutils; then
      NUT_GNU_TIMEOUT=yes
    else
      NUT_GNU_TIMEOUT=no
    fi
  fi
  [ "$NUT_GNU_TIMEOUT" = yes ]
}

nut_timeout() {
  local secs="$1" pid watcher rc=0 had_monitor=0
  shift
  if nut_have_gnu_timeout; then
    timeout "$secs" "$@"
    return $?
  fi
  # Job control is switched on just long enough to start the child, which
  # is what puts it in a process group of its own with the pgid equal to
  # its pid. Signalling the group rather than the one process is what GNU
  # timeout does, and it is not optional here: `claude auth status` and
  # `bash refresher --reset-all-time` both fork children of their own, and
  # a grandchild that survives keeps the capture pipe of a surrounding
  # $(...) open, so the substitution would block for the full run of the
  # command the limit was supposed to cut short. Monitor mode is restored
  # immediately, so the reaping below prints no job-control notices.
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  pid=$!
  [ "$had_monitor" -eq 1 ] || set +m
  # The group form is tried first and the single process is the fallback,
  # for the case where the platform gave the child no group of its own.
  ( sleep "$secs"
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" || rc=$?
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
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

# True when the user handed the statusline row back to Claude Code with
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
# Anyone can register a statusline (Claude Code's own /statusline writes
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
# Strip the three things that make a hand-edited settings.json unparseable
# without changing any value: a UTF-8 BOM, // and /* */ comments, and a
# comma before a closing } or ]. Quote-aware, so a "https://..." value or a
# comma inside a string survives; awk rather than sed because that state has
# to be tracked character by character, and awk is POSIX everywhere this
# runs. Prints the cleaned text on stdout and nothing on stderr.
nut_json_sanitize() {
  awk 'BEGIN { RS = "\001"; }
    {
      s = $0
      sub(/^\357\273\277/, "", s)          # UTF-8 BOM
      out = ""; n = length(s)
      in_str = 0; esc = 0; line_c = 0; block_c = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); d = (i < n) ? substr(s, i + 1, 1) : ""
        if (line_c)  { if (c == "\n") { line_c = 0; out = out c } ; continue }
        if (block_c) { if (c == "*" && d == "/") { block_c = 0; i++ } ; continue }
        if (in_str) {
          out = out c
          if (esc)            { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { in_str = 0 }
          continue
        }
        if (c == "\"") { in_str = 1; out = out c; continue }
        if (c == "/" && d == "/") { line_c = 1; i++; continue }
        if (c == "/" && d == "*") { block_c = 1; i++; continue }
        out = out c
      }
      # Second pass, same quote tracking: drop a comma whose next
      # non-whitespace character closes an object or an array.
      res = ""; n = length(out); in_str = 0; esc = 0
      for (i = 1; i <= n; i++) {
        c = substr(out, i, 1)
        if (in_str) {
          res = res c
          if (esc)            { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { in_str = 0 }
          continue
        }
        if (c == "\"") { in_str = 1; res = res c; continue }
        if (c == ",") {
          j = i + 1
          while (j <= n && substr(out, j, 1) ~ /[ \t\r\n]/) j++
          k = substr(out, j, 1)
          if (k == "}" || k == "]") continue
        }
        res = res c
      }
      printf "%s", res
    }' "$1" 2>/dev/null
}

# Silent repair of a settings.json this plugin cannot edit. Two cases:
# valid JSON that is not an object (`[1,2]`, `"x"`, `null`) holds no
# settings to keep, so it becomes `{}`; unparseable text is run through
# nut_json_sanitize and written back ONLY when the result parses as an
# object, so a file whose damage is anything but a BOM, a comment or a
# trailing comma is left exactly as the user left it. No backup is written
# by design: the repair either preserves every key or does not happen.
# Returns 0 when the file is usable afterwards, 1 when it is not.
nut_settings_recover() {
  local cleaned
  [ -f "$NUT_SETTINGS" ] || return 1
  nut_settings_is_object && return 0
  if jq -e . "$NUT_SETTINGS" >/dev/null 2>&1; then
    nut_write_atomic '{}
' "$NUT_SETTINGS" || return 1
    return 0
  fi
  cleaned=$(nut_json_sanitize "$NUT_SETTINGS")
  [ -n "$cleaned" ] || return 1
  printf '%s' "$cleaned" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  nut_write_atomic "$cleaned" "$NUT_SETTINGS" || return 1
  return 0
}

# A write that failed on permissions, where the file is ours to fix. Adds
# the owner write bit and nothing else: never chown, never touch a file
# owned by someone else, never widen group or other. Returns 0 when it
# changed something worth retrying.
nut_settings_make_writable() {
  [ -f "$NUT_SETTINGS" ] || return 1
  [ -w "$NUT_SETTINGS" ] && return 1
  [ -O "$NUT_SETTINGS" ] || return 1
  chmod u+w "$NUT_SETTINGS" 2>/dev/null || return 1
  [ -w "$NUT_SETTINGS" ]
}

nut_settings_register() {
  [ -f "$NUT_SETTINGS" ] || printf '{}\n' > "$NUT_SETTINGS" 2>/dev/null
  nut_settings_is_object || nut_settings_recover || return 1
  nut_jq_edit "$NUT_SETTINGS" --argjson v "$NUT_STATUSLINE_VALUE" '.statusLine = $v' 2>/dev/null && return 0
  nut_settings_make_writable || return 2
  nut_jq_edit "$NUT_SETTINGS" --argjson v "$NUT_STATUSLINE_VALUE" '.statusLine = $v' 2>/dev/null || return 2
}

# Remove the statusLine key. Same return codes; a missing file is 0, there
# is nothing to remove. Removing the key is what makes Claude Code show its
# own footer again: it suppresses its built-in keyboard hints only while a
# custom statusline is configured, so hiding every part is not the same
# thing (that leaves the key set and the row simply empty).
nut_settings_unregister() {
  [ -f "$NUT_SETTINGS" ] || return 0
  nut_settings_is_object || nut_settings_recover || return 1
  nut_jq_edit "$NUT_SETTINGS" 'del(.statusLine)' 2>/dev/null && return 0
  nut_settings_make_writable || return 2
  nut_jq_edit "$NUT_SETTINGS" 'del(.statusLine)' 2>/dev/null || return 2
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
