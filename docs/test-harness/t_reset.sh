#!/usr/bin/env bash
# `statusline-toggle.sh reset`: the parts, emoji, mode and color go back to
# exactly what a fresh install writes, while the active/inactive state,
# settings.json, the caches and any cost history stay as they were.
REPO="$1"; ROOT="$2"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

fresh() { export HOME="$ROOT/$1"; mkdir -p "$HOME/.claude"; C="$HOME/.claude"; BIN="$C/nutshell/bin"; CFG="$C/nutshell/config.json"; ST="$C/nutshell/state"; }
sync_() { CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/sync.sh" >/dev/null 2>&1; }
toggle() { bash "$BIN/statusline-toggle.sh" "$@"; }
look() { jq -cS '{model,session,cost,workspace,emoji,mode,color}' "$CFG" 2>/dev/null; }
sums() { (cd "$C" && find . -type f ! -path ./nutshell/config.json | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
customize() {
  toggle session off >/dev/null; toggle cost on >/dev/null; toggle workspace off >/dev/null
  toggle emoji on >/dev/null; toggle mode detail >/dev/null; toggle color blue >/dev/null
}

# The reference: what a fresh install's first toggle command writes.
fresh reference; printf '{}\n' > "$C/settings.json"; sync_
toggle status >/dev/null
DEFAULT=$(look)
[ -n "$DEFAULT" ] && ok "a fresh install has a config to compare against" || bad "reference" "no config"

# Active, customized, with caches and cost history on disk.
fresh active; printf '{"model":"opus"}\n' > "$C/settings.json"; sync_
customize
[ "$(look)" != "$DEFAULT" ] && ok "the customized look differs from the default" || bad "active" "customize did nothing"
printf '{"five_hour":{"used_percentage":42}}\n' > "$ST/shared_rate_limit_cache.json"
printf '{"windows_at":7}\n' > "$ST/account_usage_cache.json"
printf '{"loggedIn":true}\n' > "$ST/auth_cache.json"
printf '{"2026-09-10":1.0}\n' > "$ST/cost_ledger.json"
printf '{"2026-09-10":2.0}\n' > "$ST/ledger_openrouter.json"
before=$(sums)
out=$(toggle reset 2>&1); rc=$?
eq "reset exits 0" "$rc" 0
eq "reset restores the fresh-install look" "$(look)" "$DEFAULT"
eq "reset keeps the statusline active" "$(jq -r .disabled "$CFG")" false
eq "reset leaves settings.json, caches and cost history alone" "$(sums)" "$before"
case "$out" in "reset: default look restored ("*) ok "reset reports the restored look" ;; *) bad "active" "output: $out" ;; esac
first=$(cat "$CFG")
out2=$(toggle reset 2>&1)
eq "a second reset changes nothing" "$(cat "$CFG")" "$first"
eq "a second reset says the same" "$out2" "$out"

# Inactive: the look comes back, the row stays handed back to Claude Code.
fresh inactive; printf '{}\n' > "$C/settings.json"; sync_
customize
toggle off >/dev/null
before=$(sums)
out=$(toggle reset 2>&1); rc=$?
eq "reset while inactive exits 0" "$rc" 0
eq "reset while inactive restores the look" "$(look)" "$DEFAULT"
eq "reset keeps an inactive statusline inactive" "$(jq -r .disabled "$CFG")" true
eq "reset while inactive registers nothing" "$(jq -r '.statusLine // "none"' "$C/settings.json")" none
eq "reset while inactive touches no other file" "$(sums)" "$before"
printf '%s' "$out" | grep -q 'still inactive' && ok "reset says the statusline is still inactive" \
  || bad "inactive" "output: $out"

# An upgraded config (no mode key reads as detail) still lands on the default.
fresh upgraded; printf '{}\n' > "$C/settings.json"; sync_
mkdir -p "$C/nutshell"; printf '{"model":true,"cost":true,"session":true,"emoji":true,"extra":"kept"}\n' > "$CFG"
toggle reset >/dev/null 2>&1
eq "reset brings an upgraded config to the default look" "$(look)" "$DEFAULT"
eq "reset keeps keys it does not own" "$(jq -r .extra "$CFG")" kept

# Arguments are refused.
rc=0; toggle reset now >/dev/null 2>&1 || rc=$?
eq "reset with an argument exits 1" "$rc" 1

printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
