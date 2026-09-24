#!/usr/bin/env bash
# Upgrade from a pre-0.4.0 install: the empty flock fd targets are on disk.
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; LK="$HOME/.claude/nutshell/locks"; ST="$HOME/.claude/nutshell/state"
mkdir -p "$BIN" "$LK" "$ST" "$HOME/stub"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh auth_cache_refresh.sh; do
  cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"; chmod +x "$BIN/$f"
done
printf '{}\n' > "$HOME/.claude/settings.json"
printf '{"disabled":false,"cost":true,"session":true,"workspace":true,"emoji":false,"model":true}\n' > "$HOME/.claude/nutshell/config.json"
# what flock left behind, ancient mtime and all
: > "$LK/sync.lock"; : > "$LK/cost_cache.lock"; : > "$LK/auth_cache.lock"
touch -t 202401010000 "$LK/sync.lock" "$LK/cost_cache.lock" "$LK/auth_cache.lock"
# The cost refresher an install before the ccusage windows were retired
# still has in bin/, with the state it wrote.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/cost_cache_refresh.sh"; chmod +x "$BIN/cost_cache_refresh.sh"
printf '{"updated_at":1,"today_cost":1.0}\n' > "$ST/cost_cache.json"
printf '{"2026-09-10":1.0}\n' > "$ST/cost_ledger.json"
printf '{"2026-09-10":1.0}\n' > "$ST/ledger_openrouter.json"
# The two caches under the names they had through 0.3.6, the refresher that
# wrote one of them, and its lock. The usage cache also exists under its new
# name already (a render in flight when the scripts were swapped): the new
# file must win and the old one go.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/usage_cache_refresh.sh"; chmod +x "$BIN/usage_cache_refresh.sh"
printf '{"measured_at":7,"five_hour":{"used_percentage":42,"resets_at":9}}\n' > "$ST/rate_cache.json"
printf '{"updated_at":1,"windows_at":1}\n' > "$ST/usage_cache.json"
printf '{"updated_at":2,"windows_at":2}\n' > "$ST/account_usage_cache.json"
: > "$LK/usage_cache.lock.held"
cat > "$HOME/stub/claude" <<'S'
#!/usr/bin/env bash
printf 'probe\n' >> "$HOME/claude.log"
printf '{"loggedIn":true,"subscriptionType":"max"}\n'
S
chmod +x "$HOME/stub/claude"; export PATH="$HOME/stub:$PATH"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

: > "$HOME/claude.log"
bash "$BIN/auth_cache_refresh.sh" s1 >/dev/null 2>&1
[ -s "$HOME/claude.log" ] && ok "old flock lock file does not block a refresh" || bad "upgrade" "refresh was skipped"

CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/sync.sh" >/dev/null 2>&1
jq -e '.statusLine.command | test("statusline.sh")' "$HOME/.claude/settings.json" >/dev/null 2>&1 \
  && ok "old sync.lock does not block registration" || bad "upgrade" "sync skipped"
[ ! -e "$BIN/cost_cache_refresh.sh" ] && ok "sync removes the retired cost refresher from bin/" \
  || bad "upgrade" "bin/cost_cache_refresh.sh survived the sync"
[ ! -e "$BIN/usage_cache_refresh.sh" ] && [ -x "$BIN/account_usage_cache_refresh.sh" ] \
  && ok "sync swaps usage_cache_refresh.sh for account_usage_cache_refresh.sh" \
  || bad "upgrade" "bin/ holds: $(ls "$BIN" | tr '\n' ' ')"
[ ! -e "$ST/rate_cache.json" ] && [ "$(jq -r .measured_at "$ST/shared_rate_limit_cache.json" 2>/dev/null)" = 7 ] \
  && ok "sync renames rate_cache.json to shared_rate_limit_cache.json, content kept" \
  || bad "upgrade" "shared rate limit cache not migrated"
[ ! -e "$ST/usage_cache.json" ] && [ "$(jq -r .windows_at "$ST/account_usage_cache.json" 2>/dev/null)" = 2 ] \
  && ok "an old usage_cache.json beside the new name is dropped, the new one kept" \
  || bad "upgrade" "account usage cache wrong after sync"
[ ! -e "$LK/usage_cache.lock.held" ] && ok "sync removes the old usage cache lock" \
  || bad "upgrade" "locks/usage_cache.lock.held survived the sync"

# An install that never re-synced still has the 0.3.6 names: purge must
# sweep those as well, or the rmdir of state/ and locks/ below fails.
printf '{}\n' > "$ST/rate_cache.json"; printf '{}\n' > "$ST/usage_cache.json"
: > "$LK/usage_cache.lock"; : > "$LK/usage_cache.lock.held"

bash "$BIN/statusline-toggle.sh" uninstall --yes --purge >/dev/null 2>&1
[ ! -d "$LK" ] && ok "uninstall removes both the old and the new lock names" || bad "upgrade" "locks/ left: $(ls -A "$LK" 2>/dev/null | tr '\n' ' ')"
[ ! -d "$ST" ] && ok "a purge sweeps the retired cost files, ledgers and 0.3.6 cache names" || bad "upgrade" "state/ left: $(ls -A "$ST" 2>/dev/null | tr '\n' ' ')"
printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
