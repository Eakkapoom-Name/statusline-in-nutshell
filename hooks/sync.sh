#!/usr/bin/env bash
# Silent install/sync of statusline scripts into ~/.claude/nutshell/.
# Never touches user data: config.json and everything under state/.
# Always exits 0 so a sync problem can never block a session.

# Silent means silent: nothing on stderr either. Without this, a trailing
# `2>/dev/null` on a failing redirection (e.g. `exec 9>"$LOCK"`) doesn't help,
# since the redirection itself opens and fails before the trailing
# `2>/dev/null` applies to it.
exec 2>/dev/null

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$ROOT/skills/nutshell-setup/scripts"
# Everything this plugin owns lives under one directory as of 0.3.1. Before
# that the three scripts, the config, five state files and three locks all sat
# loose in ~/.claude, thirteen entries deep in a directory full of Claude
# Code's own files.
HOME_CLAUDE="$HOME/.claude"
DEST="$HOME_CLAUDE/nutshell"

[ -d "$SRC" ] || exit 0
mkdir -p "$DEST/bin" "$DEST/state" "$DEST/locks" 2>/dev/null

# Non-blocking lock: two SessionStart hooks can start at once (multiple
# panes/sessions). Without this, interleaved runs could race on the
# settings.json read-modify-write below and lose one of the writes. If
# another instance already holds the lock, it is doing the same work, so
# just exit.
if command -v flock >/dev/null 2>&1; then
  LOCK="$DEST/locks/sync.lock"
  exec 9>"$LOCK" 2>/dev/null || exit 0
  flock -n 9 || exit 0
fi

# Migration from the pre-0.3.1 layout. Move, never copy: two files claiming to
# be the same ledger is worse than one in the wrong place. Each move happens
# only when the new path does not exist yet, so a partially migrated install
# finishes cleanly and an already-migrated one is untouched. Held under the
# same lock as everything else here, so two sessions starting together cannot
# both migrate.
migrate_one() {
  [ -e "$1" ] || return 0
  [ -e "$2" ] && return 0
  mv "$1" "$2" 2>/dev/null
}
migrate_one "$HOME_CLAUDE/statusline.config.json" "$DEST/config.json"
migrate_one "$HOME_CLAUDE/.cost_cache.json"       "$DEST/state/cost_cache.json"
migrate_one "$HOME_CLAUDE/.cost_ledger.json"      "$DEST/state/cost_ledger.json"
migrate_one "$HOME_CLAUDE/.cost_baseline.json"    "$DEST/state/cost_baseline.json"
migrate_one "$HOME_CLAUDE/.rate_cache.json"       "$DEST/state/rate_cache.json"
migrate_one "$HOME_CLAUDE/.auth_cache.json"       "$DEST/state/auth_cache.json"
# Extra per-source ledgers, .cost_ledger_<source>.json -> state/ledger_<source>.json.
# The source names are not ours to know, hence a glob. The tool that writes one
# has to be repointed at the new path by its owner; this only rescues the
# history, it cannot redirect a third-party writer.
for old_extra in "$HOME_CLAUDE/.cost_ledger_"*.json; do
  [ -f "$old_extra" ] || continue
  base=${old_extra##*/}                 # .cost_ledger_<source>.json
  source_name=${base#.cost_ledger_}     # <source>.json
  migrate_one "$old_extra" "$DEST/state/ledger_$source_name"
done
# Locks carry no data, so they are deleted outright rather than moved.
rm -f "$HOME_CLAUDE/.cost_cache.lock" \
      "$HOME_CLAUDE/.auth_cache.json.lock" \
      "$HOME_CLAUDE/.statusline-sync.lock" 2>/dev/null

for f in statusline.sh statusline-toggle.sh cost_cache_refresh.sh; do
  [ -f "$SRC/$f" ] || continue
  if [ ! -f "$DEST/bin/$f" ] || ! diff -q "$SRC/$f" "$DEST/bin/$f" >/dev/null 2>&1; then
    # Copy to a same-directory staging name, chmod it, then rename into place.
    # A running session renders roughly once a second, so a direct cp onto
    # $DEST/bin/$f could be read mid-write; the final rename is atomic instead.
    cp "$SRC/$f" "$DEST/bin/$f.new" 2>/dev/null \
      && chmod +x "$DEST/bin/$f.new" 2>/dev/null \
      && mv "$DEST/bin/$f.new" "$DEST/bin/$f" 2>/dev/null \
      || rm -f "$DEST/bin/$f.new" 2>/dev/null
  fi
done

# Only now drop the pre-0.3.1 copies, once bin/ actually holds all three. If a
# copy above failed (full disk, unreadable source) the old scripts are still
# the working install, and deleting them first would leave the user with
# neither. Deleted rather than moved: they are replaced from the bundle every
# sync anyway, and a local edit to one of them was already unrecoverable.
if [ -x "$DEST/bin/statusline.sh" ] \
   && [ -x "$DEST/bin/statusline-toggle.sh" ] \
   && [ -x "$DEST/bin/cost_cache_refresh.sh" ]; then
  rm -f "$HOME_CLAUDE/statusline.sh" \
        "$HOME_CLAUDE/statusline-toggle.sh" \
        "$HOME_CLAUDE/cost_cache_refresh.sh" 2>/dev/null
fi

# Register the statusLine command (silent). Requires jq.
# refreshInterval is required, not cosmetic: Claude Code only re-runs the
# statusLine command on session start, a new assistant message, /compact,
# a permission-mode change, or a vim-mode toggle. Switching the advisor
# model is NOT a trigger, and neither is the cost cache going stale, so
# every segment we read from disk rather than from the stdin payload
# (advisor, cost, rate) would show a stale value indefinitely while the
# session sits idle. A 1s timer re-runs the command on a clock instead.
#
# Unless the user turned the status line off with `statusline-toggle.sh off`,
# which records "disabled": true in config.json and deletes the key. Without
# this check the hook would re-register on the next session start and the
# opt-out would last exactly one session. An absent or unreadable config reads
# as not disabled, so the default is unchanged.
if command -v jq >/dev/null 2>&1 \
   && [ "$(jq -r '.disabled' "$DEST/config.json" 2>/dev/null)" != "true" ]; then
  SETTINGS="$HOME_CLAUDE/settings.json"
  WANT='{"type":"command","command":"bash ~/.claude/nutshell/bin/statusline.sh","refreshInterval":1}'
  # A settings.json that exists but is not a JSON object (corrupt, or valid
  # JSON that isn't an object, e.g. `[1,2]`) is left exactly as the user
  # left it. Every `.statusLine = $v` below would fail on it anyway, and
  # rewriting it would destroy settings this plugin does not own and never
  # backs up. Registration is skipped this run and retried at the next
  # session start, once the file is valid again.
  if [ -f "$SETTINGS" ]; then
    jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || exit 0
  else
    echo '{}' > "$SETTINGS" 2>/dev/null
  fi
  cur=$(jq -c '.statusLine // empty' "$SETTINGS" 2>/dev/null)
  want=$(printf '%s' "$WANT" | jq -c .)
  # Never take over a status line someone else registered. Claude Code's own
  # /statusline writes one (e.g. generated from your shell PS1), and without
  # this check the hook would silently replace it on every session start.
  # An absent key is free to claim; ours is recognised by the command
  # pointing at the script we install, at either the current path or the
  # pre-0.3.1 one, which is what lets an old install be re-registered at the
  # new location instead of being treated as a stranger's.
  cur_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
  foreign=0
  case "$cur_cmd" in
    ''|*'/.claude/nutshell/bin/statusline.sh'*|*'/.claude/statusline.sh'*) ;;
    *) foreign=1 ;;
  esac
  if [ "$foreign" -eq 0 ] && [ "$cur" != "$want" ]; then
    # Same-directory temp name (not the default /tmp) so the later mv is an
    # atomic same-filesystem rename instead of a cross-filesystem
    # truncate-and-rewrite that a concurrent reader could catch mid-write.
    tmp=$(mktemp "$SETTINGS.XXXXXX" 2>/dev/null)
    if [ -n "$tmp" ]; then
      jq --argjson v "$WANT" '.statusLine = $v' "$SETTINGS" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$SETTINGS" 2>/dev/null \
        || rm -f "$tmp" 2>/dev/null
    fi
  fi
fi
exit 0
