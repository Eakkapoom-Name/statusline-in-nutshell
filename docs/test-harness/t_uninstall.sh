#!/usr/bin/env bash
# Install and uninstall around files and registrations nutshell does not own:
# a hand-written ~/.claude/statusline.sh (the pre-0.3.1 path), and a real
# pre-0.3.1 install that must still be migrated. Every case runs in its own
# fake HOME under $2.
REPO="$1"; ROOT="$2"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

# fresh <name>: a new empty HOME with ~/.claude, exported.
fresh() { export HOME="$ROOT/$1"; mkdir -p "$HOME/.claude"; C="$HOME/.claude"; BIN="$C/nutshell/bin"; }
sync_() { CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/sync.sh" >/dev/null 2>&1; }
toggle() { bash "$BIN/statusline-toggle.sh" "$@"; }
cmd() { jq -r '.statusLine.command // "none"' "$C/settings.json" 2>/dev/null; }
NEW='bash ~/.claude/nutshell/bin/statusline.sh'
MINE='bash ~/.claude/statusline.sh'
register_mine() { printf '{"model":"opus","statusLine":{"type":"command","command":"%s"}}\n' "$MINE" > "$C/settings.json"; }
user_script() { printf '#!/bin/sh\necho mine\n' > "$C/statusline.sh"; }
# The opening a pre-0.3.1 statusline.sh had in every released version.
legacy_script() {
  printf '#!/usr/bin/env bash\n# Claude Code statusLine script\n# Reads the statusLine JSON payload from stdin and prints a single summary line.\nCFG="$HOME/.claude/statusline.config.json"\n' > "$C/statusline.sh"
}

# --- bug 1: a user's own ~/.claude/statusline.sh ---------------------------

fresh b1-registered; user_script; register_mine
sync_
eq "sync leaves a user's statusline.sh registration alone" "$(cmd)" "$MINE"
eq "sync keeps a user's own statusline.sh" "$(cat "$C/statusline.sh" 2>/dev/null)" "$(printf '#!/bin/sh\necho mine')"
toggle uninstall --yes >/dev/null 2>&1
eq "uninstall keeps a user's own statusline.sh" "$(cat "$C/statusline.sh" 2>/dev/null)" "$(printf '#!/bin/sh\necho mine')"

fresh b1-unregistered; user_script; printf '{}\n' > "$C/settings.json"
sync_
eq "with no statusLine, sync registers nutshell" "$(cmd)" "$NEW"
[ -f "$C/statusline.sh" ] && ok "with no statusLine, sync still keeps the user's statusline.sh" \
  || bad "b1-unregistered" "statusline.sh deleted by sync"
toggle uninstall --yes --purge >/dev/null 2>&1
[ -f "$C/statusline.sh" ] && ok "uninstall --purge keeps the user's statusline.sh" \
  || bad "b1-unregistered" "statusline.sh deleted by purge"
toggle_off_rc=0
fresh b1-off; user_script; register_mine; sync_
toggle off >/dev/null 2>&1 || toggle_off_rc=$?
eq "off refuses a user's statusline.sh registration" "$toggle_off_rc" 1
eq "off leaves the user's registration in place" "$(cmd)" "$MINE"

# A real pre-0.3.1 install is still recognised, migrated and repointed.
fresh b1-legacy-config; legacy_script; register_mine
printf '{"cost":true,"session":true}\n' > "$C/statusline.config.json"
printf '#!/bin/sh\n' > "$C/statusline-toggle.sh"
sync_
eq "sync repoints a pre-0.3.1 install at the new path" "$(cmd)" "$NEW"
[ ! -e "$C/statusline.sh" ] && [ ! -e "$C/statusline-toggle.sh" ] \
  && ok "sync deletes the pre-0.3.1 scripts once the new ones are in" \
  || bad "b1-legacy-config" "left: $(ls -A "$C" | tr '\n' ' ')"
eq "sync migrates the pre-0.3.1 config" "$(jq -r .cost "$C/nutshell/config.json" 2>/dev/null)" true

# The script's own header is enough, with no other legacy file around.
fresh b1-legacy-header; legacy_script; register_mine
sync_
eq "a pre-0.3.1 header alone is recognised as ours" "$(cmd)" "$NEW"
[ ! -e "$C/statusline.sh" ] && ok "sync deletes a pre-0.3.1 script recognised by its header" \
  || bad "b1-legacy-header" "statusline.sh survived"

# Uninstall of an install that was never re-synced still sweeps the old script.
fresh b1-legacy-uninstall; register_mine; sync_
legacy_script
toggle uninstall --yes >/dev/null 2>&1
[ ! -e "$C/statusline.sh" ] && ok "uninstall deletes a pre-0.3.1 statusline.sh" \
  || bad "b1-legacy-uninstall" "statusline.sh survived"

# --- bug 2: uninstall leaves a foreign registration alone -------------------

FOREIGN='bash ~/.claude/my-own-line.sh'
fresh b2-foreign; printf '{}\n' > "$C/settings.json"; sync_
jq --arg c "$FOREIGN" '.statusLine={"type":"command","command":$c}' "$C/settings.json" > "$C/s" && mv "$C/s" "$C/settings.json"
out=$(toggle uninstall --yes 2>/dev/null); rc=$?
eq "uninstall keeps a foreign statusLine" "$(cmd)" "$FOREIGN"
eq "uninstall with a foreign statusLine still succeeds" "$rc" 0
case "$out" in
  "uninstalled: removed the scripts under ~/.claude/nutshell/bin/ and left settings.json's statusLine alone"*)
    ok "uninstall says it left the foreign statusLine alone" ;;
  *) bad "b2-foreign" "output: $out" ;;
esac
[ ! -e "$BIN/statusline.sh" ] && ok "uninstall with a foreign statusLine still removes the scripts" \
  || bad "b2-foreign" "bin/statusline.sh survived"

fresh b2-foreign-purge; printf '{}\n' > "$C/settings.json"; sync_
jq --arg c "$FOREIGN" '.statusLine={"type":"command","command":$c}' "$C/settings.json" > "$C/s" && mv "$C/s" "$C/settings.json"
toggle uninstall --yes --purge >/dev/null 2>&1
eq "uninstall --purge keeps a foreign statusLine" "$(cmd)" "$FOREIGN"
[ ! -d "$C/nutshell" ] && ok "uninstall --purge with a foreign statusLine removes nutshell/" \
  || bad "b2-foreign-purge" "left: $(find "$C/nutshell" | tr '\n' ' ')"

# A user's own ~/.claude/statusline.sh registration is foreign too.
fresh b2-mine; user_script; register_mine; sync_
toggle uninstall --yes >/dev/null 2>&1
eq "uninstall keeps a user's statusline.sh registration" "$(cmd)" "$MINE"

# Ours is still removed, and unrelated keys survive.
fresh b2-ours; printf '{"model":"opus","env":{"A":"1"}}\n' > "$C/settings.json"; sync_
out=$(toggle uninstall --yes 2>/dev/null)
eq "uninstall removes nutshell's own statusLine" "$(cmd)" none
eq "uninstall keeps unrelated settings" "$(jq -c '{model,env}' "$C/settings.json")" '{"model":"opus","env":{"A":"1"}}'
case "$out" in
  "uninstalled: removed the statusline registration and the scripts under ~/.claude/nutshell/bin/. "*)
    ok "uninstall of nutshell's own registration reports it removed" ;;
  *) bad "b2-ours" "output: $out" ;;
esac

printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
