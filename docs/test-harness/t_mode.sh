#!/usr/bin/env bash
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; ST="$HOME/.claude/nutshell/state"
mkdir -p "$BIN" "$ST" "$HOME/.claude/nutshell/locks"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh; do cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"; done
printf '{"advisorModel":"opus"}\n' > "$HOME/.claude/settings.json"
now=$(date +%s)
printf '{"updated_at":%s,"today_cost":12.34,"weekly_cost":56.78,"monthly_cost":123.45,"all_time_cost":2930.12}\n' "$now" > "$ST/cost_cache.json"
printf '{"sessions":{"s1":{"subscription_type":"max","updated_at":%s,"sig":1}}}\n' "$now" > "$ST/auth_cache.json"
printf '{"five_hour":{"used_percentage":42,"resets_at":%s},"seven_day":{"used_percentage":67,"resets_at":%s},"seen":{"plan":"max","windows":["five_hour","seven_day"]},"sessions":{"s1":{"sig":1,"at":%s}},"measured_at":%s}\n' "$((now+17760))" "$((now+349200))" "$now" "$now" > "$ST/rate_cache.json"
mkdir -p "$HOME/work/statusline-in-nutshell/.git" "$HOME/work/statusline-in-nutshell/skills/deep" "$HOME/scratch/notes"
printf 'ref: refs/heads/main\n' > "$HOME/work/statusline-in-nutshell/.git/HEAD"
cfg() { printf '{"model":true,"cost":%s,"session":%s,"workspace":%s,"emoji":%s,"mode":"%s","disabled":false}\n' "$1" "$2" "$3" "$4" "$5" > "$HOME/.claude/nutshell/config.json"; }
pay() { # dir rate_json extra
  cat <<P
{"session_id":"s1","model":{"display_name":"$4"},$3"context_window":{"used_percentage":37,"total_input_tokens":$5,"context_window_size":$6},"workspace":{"current_dir":"$1","repo":{"owner":"Eakkapoom-Name","name":"statusline-in-nutshell"}},"cost":{"total_cost_usd":3.4567}$2}
P
}
RATE=',"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":'$((now+17760))'},"seven_day":{"used_percentage":67,"resets_at":'$((now+349200))'}}'
EFF='"effort":{"level":"high"},'
run() { printf '%s' "$1" | bash "$BIN/statusline.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
show() { printf '%-16s %3d  %s\n' "$1" "$(printf '%s' "$2" | python3 -c "import sys,unicodedata;s=sys.stdin.read().rstrip(chr(10));print(sum(2 if unicodedata.east_asian_width(c)=='W' else 1 for c in s))")" "$2"; }

D="$HOME/work/statusline-in-nutshell"
cfg true true true false simple
show "full"        "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
cfg true true true true simple
show "emoji"       "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
cfg true true true false simple
show "no effort"   "$(run "$(pay "$D" "$RATE" "" "Opus 5" 51800 200000)")"
printf '{}\n' > "$HOME/.claude/settings.json"
show "no advisor"  "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
printf '{"advisorModel":"opus"}\n' > "$HOME/.claude/settings.json"
show "fresh 1m ctx" "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 0 1000000)")"
show "metered"     "$(run "$(pay "$D" "" "$EFF" "Opus 5" 51800 200000)")"
show "subdir"      "$(run "$(pay "$D/skills/deep" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
show "outside git" "$(run "$(pay "$HOME/scratch/notes" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
cfg false true true false simple
show "cost off"    "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
cfg true false true false simple
show "session off" "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
cfg true true false false simple
show "workspace off" "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
cfg false false false false simple
show "all off"     "$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)")"
cfg true true true false simple
show "long name"   "$(run "$(pay "$D" "$RATE" '"effort":{"level":"medium"},' "Claude Sonnet 4.5" 187400 200000)")"
echo
echo "line count check (simple must always be exactly 1):"
cfg true true true false simple
for c in "$D" "$HOME/scratch/notes"; do n=$(run "$(pay "$c" "$RATE" "$EFF" "Opus 5" 51800 200000)" | wc -l); echo "  $c -> $n line(s)"; done
cfg true true true false detail
n=$(run "$(pay "$D" "$RATE" "$EFF" "Opus 5" 51800 200000)" | wc -l); echo "  detail -> $n lines"
