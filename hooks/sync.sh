#!/usr/bin/env bash
# Silent install/sync of statusline scripts into ~/.claude/.
# Never touches user data: statusline.config.json, .cost_cache.json,
# .cost_ledger.json, .rate_cache.json.
# Always exits 0 so a sync problem can never block a session.

# Silent means silent: nothing on stderr either. Without this, a trailing
# `2>/dev/null` on a failing redirection (e.g. `exec 9>"$LOCK"`) doesn't help,
# since the redirection itself opens and fails before the trailing
# `2>/dev/null` applies to it.
exec 2>/dev/null

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$ROOT/skills/nutshell/scripts"
DEST="$HOME/.claude"

[ -d "$SRC" ] || exit 0
mkdir -p "$DEST" 2>/dev/null

# Non-blocking lock: two SessionStart hooks can start at once (multiple
# panes/sessions). Without this, interleaved runs could clobber a .bak
# that holds a user's only copy of a local edit. If another instance
# already holds the lock, it is doing the same work, so just exit.
if command -v flock >/dev/null 2>&1; then
  LOCK="$DEST/.statusline-sync.lock"
  exec 9>"$LOCK" 2>/dev/null || exit 0
  flock -n 9 || exit 0
fi

for f in statusline.sh statusline-toggle.sh cost_cache_refresh.sh; do
  [ -f "$SRC/$f" ] || continue
  if [ ! -f "$DEST/$f" ] || ! diff -q "$SRC/$f" "$DEST/$f" >/dev/null 2>&1; then
    [ -f "$DEST/$f" ] && cp "$DEST/$f" "$DEST/$f.bak" 2>/dev/null
    # Copy to a same-directory staging name, chmod it, then rename into place.
    # A running session renders roughly once a second, so a direct cp onto
    # $DEST/$f could be read mid-write; the final rename is atomic instead.
    cp "$SRC/$f" "$DEST/$f.new" 2>/dev/null \
      && chmod +x "$DEST/$f.new" 2>/dev/null \
      && mv "$DEST/$f.new" "$DEST/$f" 2>/dev/null \
      || rm -f "$DEST/$f.new" 2>/dev/null
  fi
done

# Register the statusLine command (silent; backup first). Requires jq.
# refreshInterval is required, not cosmetic: Claude Code only re-runs the
# statusLine command on session start, a new assistant message, /compact,
# a permission-mode change, or a vim-mode toggle. Switching the advisor
# model is NOT a trigger, and neither is the cost cache going stale, so
# every segment we read from disk rather than from the stdin payload
# (advisor, cost, rate) would show a stale value indefinitely while the
# session sits idle. A 1s timer re-runs the command on a clock instead.
#
# Unless the user turned the status line off with `statusline-toggle.sh off`,
# which records "disabled": true in statusline.config.json and deletes the
# key. Without this check the hook would re-register on the next session
# start and the opt-out would last exactly one session. An absent or
# unreadable config reads as not disabled, so the default is unchanged.
if command -v jq >/dev/null 2>&1 \
   && [ "$(jq -r '.disabled' "$DEST/statusline.config.json" 2>/dev/null)" != "true" ]; then
  SETTINGS="$DEST/settings.json"
  WANT='{"type":"command","command":"bash ~/.claude/statusline.sh","refreshInterval":1}'
  backed_up=0
  if [ -f "$SETTINGS" ]; then
    if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
      # Invalid JSON, or valid JSON that isn't an object (e.g. `[1,2]`, which
      # would make every later `.statusLine = $v` fail forever): back up the
      # original bytes BEFORE blanking the file, so the backup constraint
      # (backup must capture pre-run bytes) holds even for a corrupt or
      # non-object settings.json. The mismatch branch below must not
      # overwrite this backup with the '{}' placeholder, so it is skipped
      # this run via backed_up.
      cp "$SETTINGS" "$SETTINGS.bak" 2>/dev/null
      backed_up=1
      echo '{}' > "$SETTINGS" 2>/dev/null
    fi
  else
    # No settings.json existed, so there is nothing of the user's to back
    # up: skip the later backup cp instead of backing up our own '{}'
    # placeholder, which would leave a confusing stray .bak on a pristine
    # machine.
    echo '{}' > "$SETTINGS" 2>/dev/null
    backed_up=1
  fi
  cur=$(jq -c '.statusLine // empty' "$SETTINGS" 2>/dev/null)
  want=$(printf '%s' "$WANT" | jq -c .)
  # Never take over a status line someone else registered. Claude Code's own
  # /statusline writes one (e.g. generated from your shell PS1), and without
  # this check the hook would silently replace it on every session start.
  # An absent key is free to claim; ours is recognised by the command
  # pointing at the script we install.
  cur_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
  foreign=0
  case "$cur_cmd" in
    ''|*'/.claude/statusline.sh'*) ;;
    *) foreign=1 ;;
  esac
  if [ "$foreign" -eq 0 ] && [ "$cur" != "$want" ]; then
    [ "$backed_up" -eq 1 ] || cp "$SETTINGS" "$SETTINGS.bak" 2>/dev/null
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
