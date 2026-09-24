#!/usr/bin/env bash
# A rate window the account no longer has (issue #3). The usage endpoint is
# the only source that can say a window is gone: the probe records it in
# `windows_absent`, and the render drops that window from the row, from the
# shared cache and from `seen.windows`, unless a reading of it was measured
# after the probe did.
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; ST="$HOME/.claude/nutshell/state"
mkdir -p "$BIN" "$ST" "$HOME/.claude/nutshell/locks"
for f in nutshell-lib.sh statusline.sh usage_cache_refresh.sh; do
  cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"
done
printf '{}\n' > "$HOME/.claude/settings.json"
printf '{"model":true,"cost":false,"session":true,"workspace":false,"emoji":false,"mode":"detail","disabled":false}\n' \
  > "$HOME/.claude/nutshell/config.json"

now=$(date +%s); five=$((now+17760)); week=$((now+349200))
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

# ---------------------------------------------------------------------------
# The probe. curl is a stub that prints $STUB_BODY, so nothing reaches the
# network and the response shape is whatever the case needs.
STUB="$HOME/stub"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_BODY"
EOF
chmod +x "$STUB/curl"
printf '{"claudeAiOauth":{"accessToken":"test-token"}}\n' > "$HOME/.claude/.credentials.json"
export STUB_BODY="$HOME/body.json"
iso5=$(date -u -d "@$five" +%Y-%m-%dT%H:%M:%S.123456+00:00 2>/dev/null || date -u -r "$five" +%Y-%m-%dT%H:%M:%S.123456+00:00)
iso7=$(date -u -d "@$week" +%Y-%m-%dT%H:%M:%S.123456+00:00 2>/dev/null || date -u -r "$week" +%Y-%m-%dT%H:%M:%S.123456+00:00)
probe() { rm -f "$ST/usage_cache.json"; PATH="$STUB:$PATH" bash "$BIN/usage_cache_refresh.sh" 2.1.0; }
absent() { jq -c '.windows_absent' "$ST/usage_cache.json"; }

# Shape of a real response for an account with no weekly limit: the key is
# there and null, and limits[] has no weekly_all entry.
printf '{"five_hour":{"utilization":19},"seven_day":null,"limits":[{"kind":"session","percent":19,"resets_at":"%s"}]}' "$iso5" > "$STUB_BODY"
probe
eq "probe: a null key and no limits entry mark the window absent" "$(absent)" '["seven_day"]'
eq "probe: the window that is there is still read" "$(jq -r .windows.five_hour.used_percentage "$ST/usage_cache.json")" "19"

# Both windows present: nothing is absent.
printf '{"five_hour":{},"seven_day":{},"limits":[{"kind":"session","percent":19,"resets_at":"%s"},{"kind":"weekly_all","percent":89,"resets_at":"%s"}]}' "$iso5" "$iso7" > "$STUB_BODY"
probe
eq "probe: both windows present, nothing absent" "$(absent)" '[]'

# A weekly_all entry whose stamp does not parse is dropped from `windows`,
# but it proves the window exists, so it is not absent.
printf '{"five_hour":{},"seven_day":null,"limits":[{"kind":"session","percent":19,"resets_at":"%s"},{"kind":"weekly_all","percent":89,"resets_at":"garbage"}]}' "$iso5" > "$STUB_BODY"
probe
eq "probe: an unparseable entry is not absent" "$(absent)" '[]'

# A key that is missing, rather than null, says nothing: a renamed field
# must never wipe a window.
printf '{"five_hour":{},"limits":[{"kind":"session","percent":19,"resets_at":"%s"}]}' "$iso5" > "$STUB_BODY"
probe
eq "probe: a missing key is not absent" "$(absent)" '[]'

# No limits array at all: nothing to go on, nothing absent.
printf '{"five_hour":null,"seven_day":null}' > "$STUB_BODY"
probe
eq "probe: no limits array, nothing absent" "$(absent)" '[]'

# A failed call carries the last verdict forward with windows_at, so the
# absence stays dated to the probe that measured it.
printf '{"five_hour":{},"seven_day":null,"limits":[{"kind":"session","percent":19,"resets_at":"%s"}]}' "$iso5" > "$STUB_BODY"
probe
wat=$(jq -r .windows_at "$ST/usage_cache.json")
printf '{"error":{"type":"rate_limit_error"}}' > "$STUB_BODY"
PATH="$STUB:$PATH" bash "$BIN/usage_cache_refresh.sh" 2.1.0
eq "probe: a failed call keeps the absence" "$(absent)" '["seven_day"]'
eq "probe: and keeps its windows_at" "$(jq -r .windows_at "$ST/usage_cache.json")" "$wat"

# ---------------------------------------------------------------------------
# The render.
printf '{"sessions":{"s1":{"subscription_type":"team","updated_at":%s}}}\n' "$now" > "$ST/auth_cache.json"
# The reporter's cache: an old weekly reading, listed as seen, stamped by a
# fresh render AFTER the probe, and with no per-window stamp (pre-0.3.7).
oldrate() {
  printf '{"five_hour":{"used_percentage":19,"resets_at":%s},"seven_day":{"used_percentage":89,"resets_at":%s},"measured_at":%s,"seen":{"plan":"team","windows":["five_hour","seven_day"]},"sessions":{"s1":{"sig":"%s","at":%s}}}\n' \
    "$five" "$week" "$1" "$2" "$((now-600))" > "$ST/rate_cache.json"
}
# usage <windows_at> <windows_absent json>
usage() {
  printf '{"updated_at":%s,"windows_at":%s,"models":{},"windows":{"five_hour":{"used_percentage":19,"resets_at":%s}},"windows_absent":%s}\n' \
    "$1" "$1" "$five" "$2" > "$ST/usage_cache.json"
}
pay5() {
  printf '{"session_id":"s1","version":"2.1.0","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":%s},"rate_limits":{"five_hour":{"used_percentage":19,"resets_at":%s}}}' \
    "$HOME" "$1" "$five"
}
pay57() {
  printf '{"session_id":"s1","version":"2.1.0","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":%s},"rate_limits":{"five_hour":{"used_percentage":19,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$HOME" "$1" "$five" "$2" "$week"
}
run() { printf '%s' "$1" | bash "$BIN/statusline.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
w7() { printf '%s' "$1" | sed -n 's/.*weekly session: \([0-9]*\)% used.*/\1/p' | head -1 | grep . || echo none; }
w5() { printf '%s' "$1" | sed -n 's/.*5 hours session: \([0-9]*\)% used.*/\1/p' | head -1 | grep . || echo none; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# The reported bug, fresh session: its payload has no weekly window, the
# cache still does, and the cache was stamped after the probe.
oldrate $((now-10)) 5.0
usage $((now-30)) '["seven_day"]'
out=$(run "$(pay5 6.0)")
eq "fresh: an absent window is not rendered"       "$(w7 "$out")" "none"
eq "fresh: the 5h window still is"                 "$(w5 "$out")" "19"
eq "fresh: the absent window leaves the cache"     "$(jq -r 'has("seven_day")' "$ST/rate_cache.json")" "false"
eq "fresh: and leaves seen.windows"                "$(jq -c .seen.windows "$ST/rate_cache.json")" '["five_hour"]'

# Idle tab: a frozen payload still carrying the old weekly reading.
oldrate $((now-10)) 5.0
usage $((now-30)) '["seven_day"]'
out=$(run "$(pay57 5.0 89)")
eq "idle: a frozen payload cannot bring it back" "$(w7 "$out")" "none"

# Once dropped, the next render writes nothing.
run "$(pay5 5.0)" >/dev/null
before=$(jq -c . "$ST/rate_cache.json"); bm=$(mtime "$ST/rate_cache.json")
run "$(pay5 5.0)" >/dev/null
eq "the dropped cache settles"        "$(jq -c . "$ST/rate_cache.json")" "$before"
eq "and the next render writes nothing" "$(mtime "$ST/rate_cache.json")" "$bm"

# A usage cache written before 0.3.7 has no windows_absent: nothing changes.
oldrate $((now-10)) 5.0
printf '{"updated_at":%s,"windows_at":%s,"models":{},"windows":{"five_hour":{"used_percentage":19,"resets_at":%s}}}\n' \
  "$((now-30))" "$((now-30))" "$five" > "$ST/usage_cache.json"
out=$(run "$(pay5 5.0)")
eq "no windows_absent key keeps the cached window" "$(w7 "$out")" "89"

# A reading measured after the probe outranks the absence.
printf '{"five_hour":{"used_percentage":19,"resets_at":%s,"at":%s},"seven_day":{"used_percentage":89,"resets_at":%s,"at":%s},"measured_at":%s,"seen":{"plan":"team","windows":["five_hour","seven_day"]},"sessions":{"s1":{"sig":"5.0","at":%s}}}\n' \
  "$five" "$((now-5))" "$week" "$((now-5))" "$((now-5))" "$((now-600))" > "$ST/rate_cache.json"
usage $((now-30)) '["seven_day"]'
out=$(run "$(pay5 5.0)")
eq "a window measured after the probe is kept" "$(w7 "$out")" "89"

# The limit comes back: a fresh payload carrying it wins over the absence,
# and the window returns to the cache and to seen.windows.
oldrate $((now-10)) 5.0
usage $((now-30)) '["seven_day"]'
run "$(pay5 6.0)" >/dev/null
out=$(run "$(pay57 7.0 3)")
eq "a fresh payload brings the window back"      "$(w7 "$out")" "3"
eq "it is published again"                       "$(jq -r .seven_day.used_percentage "$ST/rate_cache.json")" "3"
eq "stamped with this render"                    "$(jq -r '.seven_day.at > '"$((now-30))" "$ST/rate_cache.json")" "true"
eq "and seen.windows lists it again"             "$(jq -c .seen.windows "$ST/rate_cache.json")" '["five_hour","seven_day"]'
# And an idle tab then reads it from the cache, the absence being older.
out=$(run "$(pay5 7.0)")
eq "an idle tab reads the returned window" "$(w7 "$out")" "3"

# A metered session reads no absence either (it reads no shared source).
printf '{"sessions":{"s1":{"subscription_type":null,"updated_at":%s}}}\n' "$now" > "$ST/auth_cache.json"
oldrate $((now-10)) 5.0
usage $((now-30)) '["seven_day"]'
run "$(pay57 5.0 40)" >/dev/null
eq "a metered session leaves the shared cache alone" "$(jq -r .seven_day.used_percentage "$ST/rate_cache.json")" "89"

printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
