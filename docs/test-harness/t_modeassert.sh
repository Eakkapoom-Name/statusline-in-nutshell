#!/usr/bin/env bash
# Assertions for the simple/detail layout. Display dumps live in t_mode.sh.
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; ST="$HOME/.claude/nutshell/state"
mkdir -p "$BIN" "$ST" "$HOME/.claude/nutshell/locks"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh; do cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"; done
printf '{"advisorModel":"opus"}\n' > "$HOME/.claude/settings.json"
now=$(date +%s); five=$((now+17760)); week=$((now+349200))
printf '{"updated_at":%s,"today_cost":12.34,"weekly_cost":56.78,"monthly_cost":123.45,"all_time_cost":2930.12}\n' "$now" > "$ST/cost_cache.json"
printf '{"sessions":{"s1":{"subscription_type":"max","updated_at":%s,"sig":1}}}\n' "$now" > "$ST/auth_cache.json"
printf '{"five_hour":{"used_percentage":42,"resets_at":%s},"seven_day":{"used_percentage":67,"resets_at":%s},"seen":{"plan":"max","windows":["five_hour","seven_day"]},"sessions":{"s1":{"sig":1,"at":%s}},"measured_at":%s}\n' "$five" "$week" "$now" "$now" > "$ST/rate_cache.json"
D="$HOME/work/statusline-in-nutshell"; mkdir -p "$D/.git" "$D/skills/deep"; printf 'ref: refs/heads/main\n' > "$D/.git/HEAD"
P='{"session_id":"s1","model":{"display_name":"Opus 5"},"effort":{"level":"high"},"context_window":{"used_percentage":37,"total_input_tokens":51800,"context_window_size":200000},"workspace":{"current_dir":"'"$D"'","repo":{"owner":"Eakkapoom-Name","name":"statusline-in-nutshell"}},"cost":{"total_cost_usd":3.4567},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":'"$five"'},"seven_day":{"used_percentage":67,"resets_at":'"$week"'}}}'
cfg() { printf '{"model":true,"cost":%s,"session":%s,"workspace":%s,"emoji":%s,"mode":"%s","disabled":false}\n' "$1" "$2" "$3" "$4" "$5" > "$HOME/.claude/nutshell/config.json"; }
run() { printf '%s' "${1:-$P}" | bash "$BIN/statusline.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
T() { bash "$BIN/statusline-toggle.sh" "$@" 2>&1; }
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

cfg true true true false simple
eq "simple emits exactly one line" "$(run | wc -l)" "1"
eq "simple, words, exact string" "$(run)" "Opus 5 (high) | adv Opus 5 | ctx 51.8k/200.0k | 3.46\$ | 5h 42% (4h56m) | 7d 67% (4d1h) | statusline-in-nutshell@main"
cfg true true true true simple
eq "simple, emoji, exact string" "$(run)" "💡 Opus 5 (high) | 🎓 Opus 5 | ⏳ 51.8k/200.0k | 🪙 3.46\$ | 🕐 42% (4h56m) | 🔄 67% (4d1h) | 📂 statusline-in-nutshell 🌿 main"
cfg true true true false detail
eq "detail still emits four lines" "$(run | wc -l)" "4"

cfg true true true false simple
sub=$(printf '%s' "$P" | sed "s#\"current_dir\":\"$D\"#\"current_dir\":\"$D/skills/deep\"#")
case "$(run "$sub")" in *"statusline-in-nutshell/skills/deep@main") ok "subdirectory shows repo plus relative path" ;; *) bad "subdir" "$(run "$sub")" ;; esac
out=$(printf '%s' "$P" | sed "s#\"current_dir\":\"$D\"#\"current_dir\":\"$HOME/elsewhere\"#" | bash "$BIN/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g')
case "$out" in *"~/elsewhere") ok "outside a repo shows the abbreviated path" ;; *) bad "outside repo" "$out" ;; esac

printf '{"sessions":{"s1":{"subscription_type":null,"updated_at":%s,"sig":1}}}\n' "$now" > "$ST/auth_cache.json"
nopay=$(printf '%s' "$P" | sed 's/,"rate_limits":{.*}}$/}/')
case "$(run "$nopay")" in *"5h "*|*"7d "*) bad "metered" "rate windows rendered" ;; *) ok "metered session drops both windows" ;; esac
printf '{"sessions":{"s1":{"subscription_type":"max","updated_at":%s,"sig":1}}}\n' "$now" > "$ST/auth_cache.json"

cfg false true true false simple
case "$(run)" in *'3.46$'*) bad "cost off" "cost still shown" ;; *) ok "cost off drops the cost" ;; esac
cfg true false true false simple
case "$(run)" in *"5h "*) bad "session off" "window still shown" ;; *) ok "session off drops both windows" ;; esac
cfg true true false false simple
case "$(run)" in *"nutshell@main"*) bad "workspace off" "location still shown" ;; *) ok "workspace off drops the location" ;; esac
cfg false false false false simple
eq "everything off still renders one line" "$(run | wc -l)" "1"

cfg true true true false simple
printf '{"model":true,"cost":true,"session":true,"workspace":true,"emoji":false,"mode":"sideways","disabled":false}\n' > "$HOME/.claude/nutshell/config.json"
eq "a bad mode value renders detail" "$(run | wc -l)" "4"
printf '{"model":true,"cost":true,"session":true,"workspace":true,"emoji":false,"disabled":false}\n' > "$HOME/.claude/nutshell/config.json"
eq "a missing mode key renders detail" "$(run | wc -l)" "4"

T status >/dev/null
eq "ensure_config writes the default" "$(jq -r .mode "$HOME/.claude/nutshell/config.json")" "detail"
printf '{"model":true,"cost":true,"session":true,"workspace":true,"emoji":false,"mode":"sideways","disabled":false}\n' > "$HOME/.claude/nutshell/config.json"
T status >/dev/null
eq "ensure_config repairs a bad value" "$(jq -r .mode "$HOME/.claude/nutshell/config.json")" "detail"
eq "mode simple writes it"  "$(T mode simple)" "mode: simple"
eq "bare mode toggles back" "$(T mode)" "mode: detail"
eq "bare mode toggles again" "$(T mode)" "mode: simple"
T mode sideways >/dev/null 2>&1; eq "a bad argument exits 1" "$?" "1"
eq "status row order" "$(T status | sed -n '4p;6p;8p' | tr -d '│' | tr -s ' ' | sed 's/^ //;s/ *$//' | tr '\n' ',')" "statusline active,mode simple,cost on,"
T off >/dev/null 2>&1
T mode detail >/dev/null 2>&1; eq "mode is refused while inactive" "$?" "1"
out=$(T mode detail 2>&1); case "$out" in *inactive*) ok "the refusal names the inactive statusline" ;; *) bad "inactive message" "$out" ;; esac
T on >/dev/null 2>&1

# first install vs upgrade: two different defaults
FRESH="$HOME/fresh"; mkdir -p "$FRESH/.claude/nutshell/bin" "$FRESH/.claude/nutshell/state" "$FRESH/.claude/nutshell/locks"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh; do cp "$BIN/$f" "$FRESH/.claude/nutshell/bin/$f"; done
printf '{}\n' > "$FRESH/.claude/settings.json"
FP='{"session_id":"s9","model":{"display_name":"Opus 5"},"context_window":{"used_percentage":1,"total_input_tokens":900,"context_window_size":200000},"workspace":{"current_dir":"'"$FRESH"'"},"cost":{"total_cost_usd":0.1}}'
n=$(printf '%s' "$FP" | HOME="$FRESH" bash "$FRESH/.claude/nutshell/bin/statusline.sh" | wc -l)
eq "first install renders one line before any config exists" "$n" "1"
HOME="$FRESH" bash "$FRESH/.claude/nutshell/bin/statusline-toggle.sh" status >/dev/null
eq "the config it then writes says simple" "$(jq -r .mode "$FRESH/.claude/nutshell/config.json")" "simple"
printf '{"model":true,"cost":true,"session":true,"workspace":true,"emoji":false,"disabled":false}\n' > "$FRESH/.claude/nutshell/config.json"
n=$(printf '%s' "$FP" | HOME="$FRESH" bash "$FRESH/.claude/nutshell/bin/statusline.sh" | wc -l)
eq "a pre-0.3.4 config still renders detail" "$n" "3"
HOME="$FRESH" bash "$FRESH/.claude/nutshell/bin/statusline-toggle.sh" status >/dev/null
eq "and ensure_config leaves that upgrade on detail" "$(jq -r .mode "$FRESH/.claude/nutshell/config.json")" "detail"

# cost is hidden on a first install, and only there. Its own HOME, because
# the assertions above have already written a config into $FRESH.
F2="$HOME/fresh2"; mkdir -p "$F2/.claude/nutshell/bin" "$F2/.claude/nutshell/state" "$F2/.claude/nutshell/locks"
for f in nutshell-lib.sh statusline.sh statusline-toggle.sh; do cp "$BIN/$f" "$F2/.claude/nutshell/bin/$f"; done
printf '{}\n' > "$F2/.claude/settings.json"
F2P='{"session_id":"s8","model":{"display_name":"Opus 5"},"context_window":{"used_percentage":1,"total_input_tokens":900,"context_window_size":200000},"workspace":{"current_dir":"'"$F2"'"},"cost":{"total_cost_usd":0.77}}'
f2run() { printf '%s' "$F2P" | HOME="$F2" bash "$F2/.claude/nutshell/bin/statusline.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
case "$(f2run)" in *'0.77$'*) bad "first install cost" "cost rendered" ;; *) ok "a first install hides the cost" ;; esac
HOME="$F2" bash "$F2/.claude/nutshell/bin/statusline-toggle.sh" status >/dev/null
eq "the config it writes says cost false" "$(jq -r .cost "$F2/.claude/nutshell/config.json")" "false"
HOME="$F2" bash "$F2/.claude/nutshell/bin/statusline-toggle.sh" cost on >/dev/null
case "$(f2run)" in *'0.77$'*) ok "showing it once brings the cost back" ;; *) bad "cost on" "still hidden" ;; esac
printf '{"model":true,"session":true,"workspace":true,"emoji":false,"disabled":false,"mode":"simple"}\n' > "$F2/.claude/nutshell/config.json"
case "$(f2run)" in *'0.77$'*) ok "an upgrade with no cost key still shows it" ;; *) bad "upgrade cost" "hidden on an upgrade" ;; esac

# parts stay usable in simple mode through the show/hide verbs
cfg true true true false simple
bash "$BIN/statusline-toggle.sh" cost off >/dev/null 2>&1
case "$(run)" in *'3.46$'*) bad "cost off via verb" "cost still shown" ;; *) ok "cost off through the toggle verb drops it in simple" ;; esac
bash "$BIN/statusline-toggle.sh" cost on >/dev/null 2>&1
case "$(run)" in *'3.46$'*) ok "cost on through the toggle verb brings it back" ;; *) bad "cost on via verb" "still hidden" ;; esac
bash "$BIN/statusline-toggle.sh" all off >/dev/null 2>&1
eq "all off still renders one line in simple" "$(run | wc -l)" "1"
bash "$BIN/statusline-toggle.sh" all on >/dev/null 2>&1
printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
