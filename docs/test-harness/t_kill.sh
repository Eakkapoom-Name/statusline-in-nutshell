#!/usr/bin/env bash
# A hung auth probe spawned through the real nut_spawn shape must be cut
# off by nut_timeout and release its lock. The reset-all-time kill cases
# that used to open this suite went with the ccusage cost windows, see
# archived/fragments/t_kill-reset-all-time.txt.
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; LK="$HOME/.claude/nutshell/locks"; ST="$HOME/.claude/nutshell/state"
mkdir -p "$BIN" "$LK" "$ST" "$HOME/stub"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh auth_cache_refresh.sh; do
  cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"; chmod +x "$BIN/$f"
done
printf '{}\n' > "$HOME/.claude/settings.json"
printf '{"disabled":false,"cost":true,"session":true,"workspace":true,"emoji":false,"model":true}\n' > "$HOME/.claude/nutshell/config.json"
cat > "$HOME/stub/claude" <<'S'
#!/usr/bin/env bash
[ "$1" = auth ] && { printf 'probe\n' >> "$HOME/claude.log"; sleep 300; }
S
chmod +x "$HOME/stub/claude"
export PATH="$HOME/stub:$PATH"
. "$BIN/nutshell-lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# hung auth probe through the real spawn shape (nohup, disown, no tty).
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
