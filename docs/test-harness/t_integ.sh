#!/usr/bin/env bash
# Integration: real scripts, fake HOME, stub ccusage/claude.
REPO="$1"; export HOME="$2"; LABEL="$3"
SRC="$REPO/skills/nutshell-setup/scripts"
BIN="$HOME/.claude/nutshell/bin"; ST="$HOME/.claude/nutshell/state"; LK="$HOME/.claude/nutshell/locks"
mkdir -p "$BIN" "$ST" "$LK" "$HOME/stub"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh cost_cache_refresh.sh auth_cache_refresh.sh; do
  cp "$SRC/$f" "$BIN/$f"; chmod +x "$BIN/$f"
done
printf '{}\n' > "$HOME/.claude/settings.json"
printf '{"disabled":false,"cost":true,"session":true,"workspace":true,"emoji":false,"model":true}\n' > "$HOME/.claude/nutshell/config.json"

# stubs
cat > "$HOME/stub/ccusage" <<'S'
#!/usr/bin/env bash
printf '%s ccusage %s\n' "$(date +%s)" "$*" >> "$HOME/ccusage.log"
sleep 2
printf '{"daily":[{"date":"2026-09-10","totalCost":1.23}]}\n'
S
cat > "$HOME/stub/claude" <<'S'
#!/usr/bin/env bash
case "$1" in
  auth) printf '%s claude auth\n' "$(date +%s)" >> "$HOME/claude.log"
        [ -n "$NUT_HANG" ] && sleep 300
        printf '{"subscriptionType":"max"}\n' ;;
  *) printf 'claude 2.1.266\n' ;;
esac
S
chmod +x "$HOME/stub/ccusage" "$HOME/stub/claude"
export PATH="$HOME/stub:$PATH"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   [%s] %s\n' "$LABEL" "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL [%s] %s: %s\n' "$LABEL" "$1" "$2"; }

# A. cost refresher: 10 concurrent background runs, exactly one scan
: > "$HOME/ccusage.log"
i=0; while [ "$i" -lt 10 ]; do bash "$BIN/cost_cache_refresh.sh" >/dev/null 2>&1 & i=$((i+1)); done
wait
n=$(grep -c ccusage "$HOME/ccusage.log" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "10 concurrent cost refreshes, 1 ccusage scan" || bad "cost lock" "$n scans, want 1"
[ ! -f "$LK/cost_cache.lock.held" ] && ok "cost lock released after the run" || bad "cost lock" "held file leaked"

# B. auth refresher: 10 concurrent, exactly one probe
: > "$HOME/claude.log"
i=0; while [ "$i" -lt 10 ]; do bash "$BIN/auth_cache_refresh.sh" "sess-$i" >/dev/null 2>&1 & i=$((i+1)); done
wait
n=$(grep -c claude "$HOME/claude.log" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "10 concurrent auth probes, 1 ran" || bad "auth lock" "$n probes, want 1"
[ ! -f "$LK/auth_cache.lock.held" ] && ok "auth lock released" || bad "auth lock" "held file leaked"
jq -e '.sessions | length >= 1' "$ST/auth_cache.json" >/dev/null 2>&1 && ok "auth cache written" || bad "auth cache" "not written"

# C. auth refresher with a hung claude: cut short, not left running
: > "$HOME/claude.log"; rm -f "$LK/auth_cache.lock.held"
s=$(date +%s)
NUT_HANG=1 bash "$BIN/auth_cache_refresh.sh" "hang-1" >/dev/null 2>&1
e=$(date +%s)
[ "$((e-s))" -lt 25 ] && ok "hung probe cut short after $((e-s))s" || bad "auth timeout" "took $((e-s))s"

# D. sync hook: 10 concurrent, registration still correct
rm -f "$HOME/.claude/settings.json"; printf '{}\n' > "$HOME/.claude/settings.json"
i=0; while [ "$i" -lt 10 ]; do CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/sync.sh" >/dev/null 2>&1 & i=$((i+1)); done
wait
jq -e '.statusLine.command | test("statusline.sh")' "$HOME/.claude/settings.json" >/dev/null 2>&1 \
  && ok "sync registered statusLine under contention" || bad "sync" "registration missing"
jq -e 'type == "object"' "$HOME/.claude/settings.json" >/dev/null 2>&1 && ok "settings.json still valid JSON" || bad "sync" "settings corrupted"
[ ! -f "$LK/sync.lock.held" ] && ok "sync lock released" || bad "sync lock" "held file leaked"

# E. reset-all-time completes and reports done
out=$(bash "$BIN/statusline-toggle.sh" reset-all-time --yes 2>&1); rc=$?
printf '%s' "$out" | grep -q "done: all-time cost is now 0" && [ "$rc" -eq 0 ] \
  && ok "reset-all-time reports done, rc 0" || bad "reset" "rc=$rc out=[$out]"

# F. reset-all-time waits for a live holder instead of skipping
printf '%s\n' 999999 > "$LK/cost_cache.lock.held"
( sleep 3; rm -f "$LK/cost_cache.lock.held" ) &
s=$(date +%s); out=$(bash "$BIN/statusline-toggle.sh" reset-all-time --yes 2>&1); rc=$?; e=$(date +%s)
wait
[ "$rc" -eq 0 ] && [ "$((e-s))" -ge 2 ] && ok "reset waited $((e-s))s for the holder, then ran" || bad "reset wait" "rc=$rc took $((e-s))s"

# G. statusline still renders
payload='{"session_id":"s1","model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$HOME"'"},"cost":{"total_cost_usd":0.5}}'
r=$(printf '%s' "$payload" | bash "$BIN/statusline.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
[ -n "$r" ] && ok "statusline renders ($(printf '%s' "$r" | wc -l) lines)" || bad "render" "empty output"

# H. uninstall --purge leaves no locks directory
bash "$BIN/statusline-toggle.sh" uninstall --yes --purge >/dev/null 2>&1
[ ! -d "$LK" ] && ok "purge removed locks/" || bad "purge" "locks/ remains: $(ls -a "$LK" 2>/dev/null | tr '\n' ' ')"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
