#!/usr/bin/env bash
# A settings.json that is not a plain JSON object (comments, a trailing
# comma, a BOM, or valid JSON that is not an object) is never rewritten:
# sync, on, off, reset and uninstall each leave it byte for byte as it was,
# and every command but the silent sync hook says which file to fix. A
# missing settings.json is still created and registered. Every case runs in
# its own fake HOME under $2.
REPO="$1"; ROOT="$2"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

# fresh <name>: a new empty HOME with ~/.claude, exported.
fresh() { export HOME="$ROOT/$1"; mkdir -p "$HOME/.claude"; C="$HOME/.claude"; BIN="$C/nutshell/bin"; }
sync_() { CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/sync.sh"; }
toggle() { bash "$BIN/statusline-toggle.sh" "$@"; }
NEW='bash ~/.claude/nutshell/bin/statusline.sh'
REG="{\"statusLine\":{\"type\":\"command\",\"command\":\"$NEW\"}"
MARK='so nutshell left it alone'

# same <label>: settings.json still matches the copy taken before the run.
same() { cmp -s "$C/settings.json" "$HOME/orig" && ok "$1" || bad "$1" "settings.json changed: $(od -c "$C/settings.json" | head -3)"; }
# refused <label> <rc> <stderr file>: exit 1 and the refusal names the file.
refused() {
  eq "$1 exits 1" "$2" 1
  grep -qF "$C/settings.json" "$3" && grep -qF "$MARK" "$3" \
    && ok "$1 names settings.json and the refusal" || bad "$1" "stderr: $(cat "$3")"
}

# check <name> <content>: run every command against that settings.json.
check() {
  local name="$1" rc out
  fresh "$name"; printf '%s' "$2" > "$C/settings.json"; cp "$C/settings.json" "$HOME/orig"

  rc=0; out=$(sync_ 2>&1) || rc=$?
  eq "$name: sync exits 0" "$rc" 0
  eq "$name: sync is silent" "$out" ""
  same "$name: sync leaves settings.json byte for byte"
  [ -x "$BIN/statusline-toggle.sh" ] && ok "$name: sync still installs the scripts" \
    || bad "$name" "bin/ holds: $(ls "$BIN" 2>/dev/null | tr '\n' ' ')"

  rc=0; toggle on >/dev/null 2>"$HOME/err" || rc=$?
  refused "$name: on" "$rc" "$HOME/err"
  same "$name: on leaves settings.json byte for byte"
  eq "$name: on does not record the statusline as active" "$(jq -r '.disabled' "$C/nutshell/config.json" 2>/dev/null)" "false"

  rc=0; toggle on --force >/dev/null 2>"$HOME/err" || rc=$?
  refused "$name: on --force" "$rc" "$HOME/err"
  same "$name: on --force leaves settings.json byte for byte"

  rc=0; toggle off >/dev/null 2>"$HOME/err" || rc=$?
  refused "$name: off" "$rc" "$HOME/err"
  same "$name: off leaves settings.json byte for byte"
  eq "$name: off does not record the statusline as inactive" "$(jq -r '.disabled' "$C/nutshell/config.json" 2>/dev/null)" "false"

  rc=0; out=$(toggle reset 2>"$HOME/err") || rc=$?
  eq "$name: reset still restores the look" "$rc" 0
  case "$out" in reset:*) ok "$name: reset reports the restored look" ;; *) bad "$name" "reset stdout: $out" ;; esac
  grep -qF "$MARK" "$HOME/err" && ok "$name: reset reports the refusal" || bad "$name" "reset stderr: $(cat "$HOME/err")"
  same "$name: reset leaves settings.json byte for byte"

  rc=0; out=$(toggle uninstall --yes --purge 2>"$HOME/err") || rc=$?
  refused "$name: uninstall" "$rc" "$HOME/err"
  case "$out" in uninstalled:*) bad "$name" "uninstall claimed success: $out" ;; *) ok "$name: uninstall claims no success" ;; esac
  [ -x "$BIN/statusline.sh" ] && [ -x "$BIN/statusline-toggle.sh" ] && [ -f "$BIN/nutshell-lib.sh" ] \
    && [ -f "$C/nutshell/config.json" ] && ok "$name: uninstall deletes nothing" \
    || bad "$name" "files removed: $(ls -R "$C/nutshell" 2>/dev/null | tr '\n' ' ')"
  same "$name: uninstall leaves settings.json byte for byte"

  # A second session start, now that config.json exists, still writes nothing.
  sync_ >/dev/null 2>&1
  same "$name: a later sync leaves settings.json byte for byte"
}

check comments "$(printf '{\n  // my model\n  "model": "opus",\n  /* block */ "env": {"A": "1"}\n}\n')"
check trailing "$(printf '{\n  "model": "opus",\n  "env": {"A": "1"},\n}\n')"
check bom "$(printf '\357\273\277{"model": "opus"}\n')"
check array "$(printf '[1,2]\n')"
check string "$(printf '"x"\n')"
check null "$(printf 'null\n')"
# Registered first, then hand-edited with a comment: the registration inside
# a broken file is neither removed nor rewritten.
check registered "$(printf '%s,\n  // added later\n  "model": "opus"\n}\n' "$REG")"

# Every write to settings.json goes through these two, and neither rewrites
# a file that is not an object.
fresh lib; printf '[1,2]\n' > "$C/settings.json"; cp "$C/settings.json" "$HOME/orig"
rc=0; ( . "$REPO/skills/nutshell-setup/scripts/nutshell-lib.sh"; nut_settings_register ) || rc=$?
eq "nut_settings_register on a non-object returns 1" "$rc" 1
same "nut_settings_register leaves a non-object byte for byte"
rc=0; ( . "$REPO/skills/nutshell-setup/scripts/nutshell-lib.sh"; nut_settings_unregister ) || rc=$?
eq "nut_settings_unregister on a non-object returns 1" "$rc" 1
same "nut_settings_unregister leaves a non-object byte for byte"
grep -Eq 'nut_settings_recover|nut_json_sanitize' "$REPO/skills/nutshell-setup/scripts/nutshell-lib.sh" "$REPO/hooks/sync.sh" "$REPO/skills/nutshell-setup/scripts/statusline-toggle.sh" \
  && bad "repair code" "nut_settings_recover or nut_json_sanitize is still referenced" || ok "the settings repair is gone"

# A missing settings.json behaves as before: sync creates and registers it.
fresh missing; sync_ >/dev/null 2>&1
eq "a missing settings.json is created and registered" "$(jq -r '.statusLine.command // "none"' "$C/settings.json" 2>/dev/null)" "$NEW"
rm -f "$C/settings.json"
rc=0; toggle on >/dev/null 2>&1 || rc=$?
eq "on with settings.json gone exits 0" "$rc" 0
eq "on recreates a missing settings.json with the registration" "$(jq -r '.statusLine.command // "none"' "$C/settings.json" 2>/dev/null)" "$NEW"

printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
