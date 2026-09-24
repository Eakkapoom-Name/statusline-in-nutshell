#!/usr/bin/env bash
# The regression the advisor found: a reset killed by nut_timeout must fail,
# not report success. Plus the nut_spawn shape for the auth probe.
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; LK="$HOME/.claude/nutshell/locks"; ST="$HOME/.claude/nutshell/state"
mkdir -p "$BIN" "$LK" "$ST" "$HOME/stub"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh cost_cache_refresh.sh auth_cache_refresh.sh; do
  cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"; chmod +x "$BIN/$f"
done
printf '{}\n' > "$HOME/.claude/settings.json"
printf '{"disabled":false,"cost":true,"session":true,"workspace":true,"emoji":false,"model":true}\n' > "$HOME/.claude/nutshell/config.json"
cat > "$HOME/stub/ccusage" <<'S'
#!/usr/bin/env bash
sleep 300
S
cat > "$HOME/stub/claude" <<'S'
#!/usr/bin/env bash
[ "$1" = auth ] && { printf 'probe\n' >> "$HOME/claude.log"; sleep 300; }
S
chmod +x "$HOME/stub/ccusage" "$HOME/stub/claude"
export PATH="$HOME/stub:$PATH"
. "$BIN/nutshell-lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# 1 a killed refresher reports failure, not success
s=$(date +%s)
nut_timeout 3 bash "$BIN/cost_cache_refresh.sh" --reset-all-time >/dev/null 2>&1; rc=$?
e=$(date +%s)
[ "$rc" -ne 0 ] && ok "killed reset returns non-zero (rc=$rc)" || bad "killed reset" "rc=0, would report done"
[ "$((e-s))" -lt 8 ] && ok "killed reset returned in $((e-s))s" || bad "killed reset" "took $((e-s))s"
[ ! -f "$LK/cost_cache.lock.held" ] && ok "lock released by the signal trap" || bad "killed reset" "lock leaked"

# 2 the same through the user-facing command
s=$(date +%s)
out=$(bash "$BIN/statusline-toggle.sh" reset-all-time --yes 2>&1); rc=$?
e=$(date +%s)
printf '%s' "$out" | grep -q "reset failed or timed out" && [ "$rc" -ne 0 ] \
  && ok "toggle reports 'reset failed or timed out' after $((e-s))s" \
  || bad "toggle reset" "rc=$rc out=[$(printf '%s' "$out" | tail -1)]"

# 3 hung auth probe through the real spawn shape (nohup, disown, no tty).
# The assertion is the spawned script's own exit time, recorded by a wrapper,
# which is a positive signal rather than the absence of a matching process.
: > "$HOME/claude.log"; rm -f "$LK/auth_cache.lock.held" "$HOME/exited.at"
s=$(date +%s)
nut_spawn bash -c 'bash "$1" spawned-1 >/dev/null 2>&1; date +%s > "$2"' _ "$BIN/auth_cache_refresh.sh" "$HOME/exited.at"
i=0; while [ "$i" -lt 40 ]; do [ -s "$HOME/exited.at" ] && break; sleep 1; i=$((i+1)); done
if [ -s "$HOME/exited.at" ]; then
  e=$(cat "$HOME/exited.at"); d=$((e-s))
  [ "$d" -lt 25 ] && ok "spawned hung probe exited after ${d}s, inside its 15s limit plus slack" \
    || bad "spawned probe" "took ${d}s"
else
  bad "spawned probe" "never exited within 40s"
fi
[ ! -f "$LK/auth_cache.lock.held" ] && ok "spawned probe released its lock" || bad "spawned probe" "lock leaked"
printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
