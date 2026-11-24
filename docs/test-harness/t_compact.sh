#!/usr/bin/env bash
# The auto-compact window on the context segment: which limit wins (the
# CLAUDE_CODE_AUTO_COMPACT_WINDOW env var, then the user, project and local
# settings scopes), which value forms count, and the recomputed total,
# percent and bar. With no explicit window the row must stay byte for byte
# what it was.
REPO="$1"; export HOME="$2"
BIN="$HOME/.claude/nutshell/bin"; PROJ="$HOME/proj"
mkdir -p "$BIN" "$HOME/.claude/nutshell/state" "$HOME/.claude/nutshell/locks" "$PROJ/.claude"
for f in nutshell-lib.sh statusline.sh; do cp "$REPO/skills/nutshell-setup/scripts/$f" "$BIN/$f"; done
cfg() {
  printf '{"model":true,"cost":false,"session":false,"workspace":false,"emoji":false,"mode":"%s","disabled":false}\n' \
    "$1" > "$HOME/.claude/nutshell/config.json"
}
cfg detail
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

# scopes <user> <project> <local>: settings.json bodies, "" for no file.
scopes() {
  rm -f "$HOME/.claude/settings.json" "$PROJ/.claude/settings.json" "$PROJ/.claude/settings.local.json"
  [ -n "$1" ] && printf '%s\n' "$1" > "$HOME/.claude/settings.json"
  [ -n "$2" ] && printf '%s\n' "$2" > "$PROJ/.claude/settings.json"
  [ -n "$3" ] && printf '%s\n' "$3" > "$PROJ/.claude/settings.local.json"
  return 0
}
per() { printf '{"modelSettings":{"%s":{"autoCompactWindow":%s}}}' "$1" "$2"; }
# pay <model id> <total_input_tokens>, on a 1M window at 25% used.
pay() {
  printf '{"session_id":"s1","model":{"id":"%s","display_name":"Opus 5.5"},"workspace":{"current_dir":"%s","project_dir":"%s"},"context_window":{"total_input_tokens":%s,"context_window_size":1000000,"used_percentage":25}}' \
    "$1" "$PROJ" "$PROJ" "$2"
}
run() { printf '%s' "$1" | bash "$BIN/statusline.sh" 2>&1 | head -1 | sed 's/\x1b\[[0-9;]*m//g'; }
ctx() { run "$1" | sed -n 's/.*context: //p'; }
P=$(pay 'claude-opus-5-5[1m]' 250000)
FULL='250.0k/1.0m tokens [███░░░░░░░] 25% used'
SIXH='250.0k/600.0k tokens [████░░░░░░] 42% used'

scopes "" "" ""
eq "no setting leaves the payload window"       "$(ctx "$P")" "$FULL"
scopes "$(per claude-opus-5-5 600000)" "" ""
eq "a per-model window replaces the total"      "$(ctx "$P")" "$SIXH"
scopes "$(per claude-opus-5-5 '"auto"')" "" ""
eq "auto is no explicit window"                 "$(ctx "$P")" "$FULL"
scopes "$(per claude-opus-5-5 99999)" "" ""
eq "a window below 100000 is ignored"           "$(ctx "$P")" "$FULL"
scopes "$(per claude-opus-5-5 '"600k"')" "" ""
eq "a shorthand string in settings is ignored"  "$(ctx "$P")" "$FULL"
scopes "$(per claude-sonnet-5 600000)" "" ""
eq "another model's window does not apply"      "$(ctx "$P")" "$FULL"
scopes "$(per claude-opus-5-5 2000000)" "" ""
eq "the window is capped at the model window"   "$(ctx "$P")" "$FULL"
scopes "$(per claude-opus-5-5 600000)" "" ""
eq "a dated model id matches"   "$(ctx "$(pay claude-opus-5-5-20261001 250000)")" "$SIXH"
eq "a Bedrock model id matches" "$(ctx "$(pay 'us.anthropic.claude-opus-5-5-v1:0' 250000)")" "$SIXH"
eq "used past the window caps at 100%" "$(ctx "$(pay claude-opus-5-5 700000)")" \
  '700.0k/600.0k tokens [██████████] 100% used'
eq "a fresh session shows 0%" "$(ctx "$(pay claude-opus-5-5 0)")" \
  '0/600.0k tokens [░░░░░░░░░░] 0% used'
# jq splits "" into [], so an id-less payload once broke the whole row.
scopes '{"autoCompactWindow":400000}' "" ""
eq "a payload with no model id takes the default window" \
  "$(ctx "$(pay claude-opus-5-5 250000 | sed 's/"id":"claude-opus-5-5",//')")" \
  '250.0k/400.0k tokens [██████░░░░] 63% used'

# The scope fold, in the order Claude Code reads them.
scopes "$(per claude-opus-5-5 600000)" "$(per claude-opus-5-5 300000)" ""
eq "project beats user" "$(ctx "$P")" '250.0k/300.0k tokens [████████░░] 83% used'
scopes "$(per claude-opus-5-5 600000)" "$(per claude-opus-5-5 300000)" "$(per claude-opus-5-5 '"auto"')"
eq "a local auto beats a project window" "$(ctx "$P")" "$FULL"
scopes "$(per claude-opus-5-5 600000)" '{"autoCompactWindow":400000}' ""
eq "a top-level window drops per-model entries below it" "$(ctx "$P")" \
  '250.0k/400.0k tokens [██████░░░░] 63% used'
scopes "" '{"autoCompactWindow":400000}' "$(per 'claude-opus-5-5[1m]' 500000)"
eq "a per-model entry above beats a top-level default" "$(ctx "$P")" \
  '250.0k/500.0k tokens [█████░░░░░] 50% used'
scopes "" "" '{"modelSettings":{"claude-opus-5-5[1m]":{"autoCompactWindow":500000},"claude-opus-5-5":{"autoCompactWindow":700000}}}'
eq "within a scope the exact key wins" "$(ctx "$P")" \
  '250.0k/700.0k tokens [████░░░░░░] 36% used'

# The env var wins over every scope, and only when it parses.
scopes "$(per claude-opus-5-5 600000)" "" ""
eq "env beats settings" "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=300k ctx "$P")" \
  '250.0k/300.0k tokens [████████░░] 83% used'
eq "an unusable env falls through" "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=xyz ctx "$P")" "$SIXH"
scopes "" "" ""
for v in 600k 0.6M 6e5 600,000 600_000 ' 600000 '; do
  eq "env form [$v]" "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW="$v" ctx "$P")" "$SIXH"
done
# Below the 100000 minimum, Claude Code raises an env value to it but
# drops a settings value, so the two sources part ways here.
MIN='250.0k/100.0k tokens [██████████] 100% used'
eq "env 600 is tokens raised to the minimum, not 600k" "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=600 ctx "$P")" "$MIN"
eq "env 99999 is raised to the minimum" "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=99999 ctx "$P")" "$MIN"
eq "env 50k is raised to the minimum"   "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=50k ctx "$P")" "$MIN"
eq "env under 1 is unusable"            "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=0.5 ctx "$P")" "$FULL"
scopes '{"autoCompactWindow":99999}' "" ""
eq "a top-level window below 100000 is ignored" "$(ctx "$P")" "$FULL"
scopes '{"autoCompactWindow":400000}' "" "$(per claude-opus-5-5 99999)"
eq "a low per-model entry is skipped, not a mask" "$(ctx "$P")" \
  '250.0k/400.0k tokens [██████░░░░] 63% used'

# The simple layout shows the counts only.
cfg simple
scopes "$(per claude-opus-5-5 600000)" "" ""
eq "the simple row counts against the window" "$(run "$P" | sed -n 's/.*ctx: \([^ ]*\).*/\1/p')" '250.0k/600.0k'
cfg detail

printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
