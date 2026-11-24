#!/usr/bin/env bash
# Install, off and uninstall around files and registrations nutshell does
# not own: a hand-written ~/.claude/statusline.sh, someone else's statusLine,
# anything else directly in ~/.claude. Outside ~/.claude/nutshell/ the only
# thing nutshell may write is its own statusLine key. Every case runs in its
# own fake HOME under $2.
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
MINE_BODY=$(printf '#!/bin/sh\necho mine')
# Everything directly in ~/.claude but settings.json, with content hashes.
outside() { (cd "$C" && find . -path ./nutshell -prune -o -type f ! -name settings.json -print | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

# --- nothing outside ~/.claude/nutshell/ is touched -------------------------

# A user's own statusline.sh, registered, through install, off and uninstall.
fresh own-registered; user_script; register_mine
sync_
eq "sync leaves a user's statusline.sh registration alone" "$(cmd)" "$MINE"
eq "sync keeps a user's own statusline.sh" "$(cat "$C/statusline.sh" 2>/dev/null)" "$MINE_BODY"
rc=0; toggle off >/dev/null 2>&1 || rc=$?
eq "off refuses a user's statusline.sh registration" "$rc" 1
eq "off leaves the user's registration in place" "$(cmd)" "$MINE"
toggle uninstall --yes >/dev/null 2>&1
eq "uninstall keeps a user's own statusline.sh" "$(cat "$C/statusline.sh" 2>/dev/null)" "$MINE_BODY"
eq "uninstall keeps a user's statusline.sh registration" "$(cmd)" "$MINE"

# The same file, not registered: nutshell registers itself, the file stays.
fresh own-unregistered; user_script; printf '{}\n' > "$C/settings.json"
sync_
eq "with no statusLine, sync registers nutshell" "$(cmd)" "$NEW"
eq "with no statusLine, sync keeps the user's statusline.sh" "$(cat "$C/statusline.sh" 2>/dev/null)" "$MINE_BODY"
toggle uninstall --yes --purge >/dev/null 2>&1
eq "uninstall --purge keeps the user's statusline.sh" "$(cat "$C/statusline.sh" 2>/dev/null)" "$MINE_BODY"

# Files with the names a pre-0.3.1 install used, which are no longer
# nutshell's business: never migrated, never deleted, never claimed.
fresh outside-names; register_mine
printf '#!/usr/bin/env bash\n# Claude Code statusLine script\nCFG="$HOME/.claude/statusline.config.json"\n' > "$C/statusline.sh"
for f in statusline-toggle.sh cost_cache_refresh.sh statusline.config.json .cost_cache.json \
         .cost_ledger.json .auth_cache.json .cost_cache.lock .statusline-sync.lock \
         .auth_cache.json.lock .cost_ledger_openrouter.json statusline.sh.bak settings.json.bak; do
  printf 'x %s\n' "$f" > "$C/$f"
done
before=$(outside)
sync_
eq "sync leaves every file outside nutshell/ alone" "$(outside)" "$before"
eq "sync does not claim a registration of ~/.claude/statusline.sh" "$(cmd)" "$MINE"
toggle uninstall --yes >/dev/null 2>&1
eq "uninstall leaves every file outside nutshell/ alone" "$(outside)" "$before"
sync_; toggle uninstall --yes --purge >/dev/null 2>&1
eq "uninstall --purge leaves every file outside nutshell/ alone" "$(outside)" "$before"
eq "uninstall --purge keeps that registration" "$(cmd)" "$MINE"

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
