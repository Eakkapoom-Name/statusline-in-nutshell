#!/usr/bin/env bash
# Freshness of the two account rate windows: which of the three readings
# (this session's own payload, the shared rate cache, the usage endpoint
# cache) feeds the rate row, and what gets published back.
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; ST="$HOME/.claude/nutshell/state"
mkdir -p "$BIN" "$ST" "$HOME/.claude/nutshell/locks"
for f in nutshell-lib.sh statusline.sh; do cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"; done
printf '{}\n' > "$HOME/.claude/settings.json"
printf '{"model":true,"cost":false,"session":true,"workspace":false,"emoji":false,"mode":"detail","disabled":false}\n' \
  > "$HOME/.claude/nutshell/config.json"

now=$(date +%s); five=$((now+17760)); week=$((now+349200)); gone=$((now-60))
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

auth() { printf '{"sessions":{"s1":{"subscription_type":%s,"updated_at":%s}}}\n' "$1" "$now" > "$ST/auth_cache.json"; }
# rate <5h pct> <7d pct> <measured_at> <stored sig>
rate() {
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s},"measured_at":%s,"seen":{"plan":"max","windows":["five_hour","seven_day"]},"sessions":{"s1":{"sig":"%s","at":%s}}}\n' \
    "$1" "$five" "$2" "$week" "$3" "$4" "$((now-600))" > "$ST/shared_rate_limit_cache.json"
}
# usage <5h pct> <7d pct> <7d resets_at> <updated_at> <windows_at>
usage() {
  printf '{"updated_at":%s,"windows_at":%s,"models":{},"windows":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}\n' \
    "$4" "$5" "$1" "$five" "$2" "$3" > "$ST/account_usage_cache.json"
}
# pay <total_cost_usd> <5h pct> <7d pct>
pay() {
  printf '{"session_id":"s1","version":"2.1.0","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$HOME" "$1" "$2" "$five" "$3" "$week"
}
run() { printf '%s' "$1" | bash "$BIN/statusline.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
w7() { printf '%s' "$1" | sed -n 's/.*weekly session: \([0-9]*\)% used.*/\1/p' | head -1 | grep . || echo none; }
w5() { printf '%s' "$1" | sed -n 's/.*5 hours session: \([0-9]*\)% used.*/\1/p' | head -1 | grep . || echo none; }

auth '"max"'

# The reported bug: every tab idle, the cache frozen high, the endpoint low.
# Neither the payload nor the cache can correct itself here, so the endpoint
# has to, with no message sent in any session.
rate 2 41 $((now-600)) 5.0
usage 2 0 "$week" $((now-10)) $((now-10))
out=$(run "$(pay 5.0 0 0)")
eq "a fresher endpoint corrects a stale cache" "$(w7 "$out")" "0"
eq "the corrected reading is published"        "$(jq -r .seven_day.used_percentage "$ST/shared_rate_limit_cache.json")" "0"
eq "and is stamped with windows_at"            "$(jq -r .measured_at "$ST/shared_rate_limit_cache.json")" "$((now-10))"

# updated_at moves on a FAILED probe too, so weighing it instead of
# windows_at would let an endpoint that is down outrank a live publish.
rate 2 41 $((now-60)) 5.0
usage 2 0 "$week" $((now-5)) $((now-600))
out=$(run "$(pay 5.0 0 0)")
eq "a failed probe cannot outrank the cache" "$(w7 "$out")" "41"

# A session that just had a response holds the most current reading there is.
rate 2 41 $((now-600)) 5.0
usage 2 9 "$week" $((now-5)) $((now-5))
out=$(run "$(pay 9.0 3 7)")
eq "a fresh payload outranks both, weekly" "$(w7 "$out")" "7"
eq "a fresh payload outranks both, 5h"     "$(w5 "$out")" "3"

# An endpoint window whose reset has passed is dropped like any other.
rate 2 41 $((now-600)) 5.0
usage 2 0 "$gone" $((now-5)) $((now-5))
out=$(run "$(pay 5.0 0 0)")
eq "an expired endpoint window is ignored" "$(w7 "$out")" "41"

# Pre-0.3.6 cache, and no cache at all: today behaviour, the cache wins.
rate 2 41 $((now-600)) 5.0
printf '{"updated_at":%s,"models":{}}\n' "$((now-5))" > "$ST/account_usage_cache.json"
out=$(run "$(pay 5.0 0 0)")
eq "a usage cache with no windows key changes nothing" "$(w7 "$out")" "41"
rm -f "$ST/account_usage_cache.json"
rate 2 41 $((now-600)) 5.0
out=$(run "$(pay 5.0 0 0)")
eq "no usage cache at all changes nothing" "$(w7 "$out")" "41"

# A metered session reads neither shared source.
auth 'null'
rate 2 41 $((now-600)) 5.0
usage 2 0 "$week" "$now" "$now"
nopay='{"session_id":"s1","version":"2.1.0","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"'"$HOME"'"},"cost":{"total_cost_usd":5.0}}'
out=$(run "$nopay")
eq "a metered session shows no weekly window" "$(w7 "$out")" "none"
eq "a metered session shows no 5h window"     "$(w5 "$out")" "none"
eq "and publishes nothing"                    "$(jq -r .seven_day.used_percentage "$ST/shared_rate_limit_cache.json")" "41"
auth '"max"'

# Hiding the session part hides the endpoint windows with it.
printf '{"model":true,"cost":false,"session":false,"workspace":false,"emoji":false,"mode":"detail","disabled":false}\n' \
  > "$HOME/.claude/nutshell/config.json"
rate 2 41 $((now-600)) 5.0
usage 2 0 "$week" "$now" "$now"
out=$(run "$(pay 5.0 0 0)")
eq "session off drops the endpoint windows too" "$(w7 "$out")" "none"
printf '{"model":true,"cost":false,"session":true,"workspace":false,"emoji":false,"mode":"detail","disabled":false}\n' \
  > "$HOME/.claude/nutshell/config.json"

# Once the correction is published the readings agree, so the next render
# writes nothing: the row costs the same two processes it always did.
rate 2 41 $((now-600)) 5.0
usage 2 0 "$week" $((now-10)) $((now-10))
run "$(pay 5.0 0 0)" >/dev/null
before=$(jq -c . "$ST/shared_rate_limit_cache.json"); bm=$(stat -c %Y "$ST/shared_rate_limit_cache.json" 2>/dev/null || stat -f %m "$ST/shared_rate_limit_cache.json")
run "$(pay 5.0 0 0)" >/dev/null
am=$(stat -c %Y "$ST/shared_rate_limit_cache.json" 2>/dev/null || stat -f %m "$ST/shared_rate_limit_cache.json")
eq "the cache settles after one correction" "$(jq -c . "$ST/shared_rate_limit_cache.json")" "$before"
eq "and the settled render rewrites nothing" "$am" "$bm"

# The endpoint alone is enough: a session whose own payload carries no
# rate_limits yet still renders the account windows.
rm -f "$ST/shared_rate_limit_cache.json"
usage 2 0 "$week" "$now" "$now"
out=$(run '{"session_id":"s2","version":"2.1.0","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"'"$HOME"'"},"cost":{"total_cost_usd":0}}')
eq "the endpoint alone renders the weekly window" "$(w7 "$out")" "0"
eq "the endpoint alone renders the 5h window"     "$(w5 "$out")" "2"

printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
