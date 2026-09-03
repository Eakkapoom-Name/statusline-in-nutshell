#!/usr/bin/env bash
# hooks/sync.sh: SessionStart hook. Installs or refreshes the scripts under
# ~/.claude/nutshell/bin/, migrates a pre-0.3.1 install, and registers the
# statusLine command in settings.json. The nutshell-setup skill runs this
# same script as the mid-session repair.
#
# Never touches user data: config.json and everything under state/. Always
# exits 0 so a sync problem can never block a session start. Silent means
# silent: nothing on stderr either. The `exec` below comes first because a
# trailing `2>/dev/null` on a failing redirection (such as `exec 9>"$LOCK"`)
# does not help, the redirection opens and fails before it applies.
exec 2>/dev/null

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$ROOT/skills/nutshell-setup/scripts"
[ -d "$SRC" ] || exit 0
. "$SRC/nutshell-lib.sh" || exit 0

mkdir -p "$NUT_BIN_DIR" "$NUT_STATE_DIR" "$NUT_LOCK_DIR" 2>/dev/null

# Non-blocking lock: two SessionStart hooks can start at once (several
# panes or sessions). Without it, interleaved runs could race on the
# settings.json read-modify-write and lose one of the writes. Another
# instance holding the lock is doing the same work, so just leave. Guarded
# behind `command -v` since stock macOS ships no flock.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$NUT_SYNC_LOCK" 2>/dev/null || exit 0
  flock -n 9 || exit 0
fi

nut_migrate_legacy_layout

# Copy each bundled script into bin/ when missing or different. Copy to a
# same-directory staging name, chmod it, then rename into place: a running
# session renders about once a second, so a direct cp onto the live file
# could be read mid-write, while the final rename is atomic. No .bak is
# written; the bundle is the source of truth for these files.
for f in $NUT_INSTALLED_FILES; do
  [ -f "$SRC/$f" ] || continue
  if [ ! -f "$NUT_BIN_DIR/$f" ] || ! diff -q "$SRC/$f" "$NUT_BIN_DIR/$f" >/dev/null 2>&1; then
    cp "$SRC/$f" "$NUT_BIN_DIR/$f.new" 2>/dev/null \
      && chmod +x "$NUT_BIN_DIR/$f.new" 2>/dev/null \
      && mv "$NUT_BIN_DIR/$f.new" "$NUT_BIN_DIR/$f" 2>/dev/null \
      || rm -f "$NUT_BIN_DIR/$f.new" 2>/dev/null
  fi
done

# Only now drop the pre-0.3.1 scripts, once bin/ holds every new one. If a
# copy above failed (full disk, unreadable source) the old scripts are still
# the working install, and deleting them first would leave the user with
# neither. Deleted rather than moved: a local edit to one of them was
# already unrecoverable, since every sync replaces them from the bundle.
all_installed=1
for f in $NUT_INSTALLED_FILES; do
  [ -x "$NUT_BIN_DIR/$f" ] || all_installed=0
done
if [ "$all_installed" -eq 1 ]; then
  for f in $NUT_OLD_SCRIPTS; do
    rm -f "$NUT_CLAUDE_DIR/$f" 2>/dev/null
  done
fi

# Register the statusLine command, unless the user turned the status line
# off with `statusline-toggle.sh off` (the nutshell-inactive skill), which
# records "disabled": true and deletes the key: without this check the hook
# would re-register at the next session start and the opt-out would last
# exactly one session. An absent or unreadable config reads as not disabled.
command -v jq >/dev/null 2>&1 || exit 0
nut_config_is_disabled && exit 0

# A settings.json that exists but is not a JSON object is left exactly as
# the user left it, and registration is retried at the next session start.
if [ -f "$NUT_SETTINGS" ]; then
  nut_settings_is_object || exit 0
else
  echo '{}' > "$NUT_SETTINGS" 2>/dev/null
fi
# Never take over a status line someone else registered (Claude Code's own
# /statusline writes one from your shell PS1). Ours, at either the current
# path or the pre-0.3.1 one, is re-registered whenever it differs from the
# wanted value, which is also what repoints an old install at the new path
# and what restores a deleted refreshInterval.
nut_statusline_is_ours || exit 0
want=$(printf '%s' "$NUT_STATUSLINE_VALUE" | jq -c .)
[ "$(nut_registered_value)" = "$want" ] || nut_settings_register
exit 0
