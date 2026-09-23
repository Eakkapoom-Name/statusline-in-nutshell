#!/usr/bin/env bash
# Integration: real scripts, fake HOME, stub claude.
REPO="$1"; export HOME="$2"; LABEL="$3"
SRC="$REPO/skills/nutshell-setup/scripts"
BIN="$HOME/.claude/nutshell/bin"; ST="$HOME/.claude/nutshell/state"; LK="$HOME/.claude/nutshell/locks"
mkdir -p "$BIN" "$ST" "$LK" "$HOME/stub"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh auth_cache_refresh.sh; do
  cp "$SRC/$f" "$BIN/$f"; chmod +x "$BIN/$f"
done
printf '{}\n' > "$HOME/.claude/settings.json"
printf '{"disabled":false,"cost":true,"session":true,"workspace":true,"emoji":false,"model":true}\n' > "$HOME/.claude/nutshell/config.json"

# stubs
cat > "$HOME/stub/claude" <<'S'
#!/usr/bin/env bash
case "$1" in
  auth) printf '%s claude auth\n' "$(date +%s)" >> "$HOME/claude.log"
        [ -n "$NUT_HANG" ] && sleep 300
        printf '{"subscriptionType":"max"}\n' ;;
  *) printf 'claude 2.1.266\n' ;;
esac
S
chmod +x "$HOME/stub/claude"
export PATH="$HOME/stub:$PATH"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   [%s] %s\n' "$LABEL" "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL [%s] %s: %s\n' "$LABEL" "$1" "$2"; }

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

# G. statusline still renders
payload='{"session_id":"s1","model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$HOME"'"},"cost":{"total_cost_usd":0.5}}'
r=$(printf '%s' "$payload" | bash "$BIN/statusline.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
[ -n "$r" ] && ok "statusline renders ($(printf '%s' "$r" | wc -l) lines)" || bad "render" "empty output"

# G2. write temporaries: a killed writer's leftovers are swept by the next
# background refresh, a live writer's are not, and a write of its own
# leaves nothing behind. The stale stamps are set with touch rather than by
# waiting ten minutes; both flavours of date are tried, as everywhere else.
old=$(date -d '-20 minutes' +%Y%m%d%H%M 2>/dev/null || date -v-20M +%Y%m%d%H%M 2>/dev/null)
: > "$ST/shared_rate_limit_cache.json.424242"; : > "$ST/cost_cache.json.Ab3Xy9"; : > "$ST/shared_rate_limit_cache.json.now"
touch -t "$old" "$ST/shared_rate_limit_cache.json.424242" "$ST/cost_cache.json.Ab3Xy9" 2>/dev/null
printf '{"measured_at":1}\n' > "$ST/shared_rate_limit_cache.json"
# A refresher that cannot take its lock leaves before it sweeps anything.
rm -f "$LK/auth_cache.lock.held"
bash "$BIN/auth_cache_refresh.sh" sweep-1 >/dev/null 2>&1
[ ! -e "$ST/shared_rate_limit_cache.json.424242" ] && [ ! -e "$ST/cost_cache.json.Ab3Xy9" ] \
  && ok "the refresher swept both stale write temporaries" \
  || bad "temp sweep" "left: $(ls "$ST" | grep -c 'json\.')"
[ -e "$ST/shared_rate_limit_cache.json.now" ] && ok "a temporary younger than the gate is left alone" \
  || bad "temp sweep" "removed a live writer's file"
[ -f "$ST/shared_rate_limit_cache.json" ] && ok "the sweep never touches the caches themselves" \
  || bad "temp sweep" "shared_rate_limit_cache.json is gone"
rm -f "$ST/shared_rate_limit_cache.json.now"
( . "$BIN/nutshell-lib.sh"; nut_write_atomic '{"a":1}' "$ST/sweeptest.json" )
n=$(ls "$ST" | grep -c 'sweeptest\.json\.' || true)
[ "$n" = "0" ] && [ -f "$ST/sweeptest.json" ] && ok "an atomic write leaves no temporary behind" \
  || bad "atomic write" "$n leftovers"
# And it is still private to the user. The mktemp this write used to draw
# from created at 0600 and the rename carried that to the target; the umask
# in nutshell-lib.sh is what keeps that true now that the temp file is a
# plain redirection. Skipped where the filesystem does not honour a umask
# at all, which is every MSYS path on Windows: it reports 0644 for
# everything and the real permissions are ACLs.
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
( umask 077; : > "$ST/.modeprobe" )
if [ "$(mode_of "$ST/.modeprobe")" = "600" ]; then
  m=$(mode_of "$ST/sweeptest.json")
  [ "$m" = "600" ] && ok "an atomic write leaves the target 0600" || bad "write mode" "got $m"
else
  ok "file modes are not enforced here, nothing to assert about 0600"
fi
rm -f "$ST/.modeprobe" "$ST/sweeptest.json"

# H. uninstall --purge leaves no locks directory
bash "$BIN/statusline-toggle.sh" uninstall --yes --purge >/dev/null 2>&1
[ ! -d "$LK" ] && ok "purge removed locks/" || bad "purge" "locks/ remains: $(ls -a "$LK" 2>/dev/null | tr '\n' ' ')"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
