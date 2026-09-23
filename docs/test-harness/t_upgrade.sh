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

bash "$BIN/statusline-toggle.sh" uninstall --yes --purge >/dev/null 2>&1
[ ! -d "$LK" ] && ok "uninstall removes both the old and the new lock names" || bad "upgrade" "locks/ left: $(ls -A "$LK" 2>/dev/null | tr '\n' ' ')"
[ ! -d "$ST" ] && ok "a purge still sweeps the retired cost files and ledgers" || bad "upgrade" "state/ left: $(ls -A "$ST" 2>/dev/null | tr '\n' ' ')"
printf '%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
