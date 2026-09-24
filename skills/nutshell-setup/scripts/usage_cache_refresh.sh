#!/usr/bin/env bash
# usage_cache_refresh.sh: background probe of the account usage endpoint,
# feeding ~/.claude/nutshell/state/usage_cache.json.
#
# Usage: usage_cache_refresh.sh <claude_code_version>
#
# The stdin payload Claude Code hands the statusline carries exactly two
# rate-limit windows, five_hour and seven_day. Per-MODEL weekly windows (the
# "Current week (Fable)" row the built-in /usage dialog shows) exist only in
# the account's own usage endpoint, which is what /usage itself calls:
#
#   GET https://api.anthropic.com/api/oauth/usage
#
# Its limits[] array carries one entry per window; a per-model one has
# kind == "weekly_scoped" and scope.model.display_name (e.g. "Fable"),
# with percent and an ISO 8601 resets_at.
#
# The same array also carries the ACCOUNT-level windows the stdin payload
# has, kind == "session" (the five-hour one) and kind == "weekly_all". Those
# are cached too, and they are the only session-independent reading of them
# that exists: Claude Code refreshes the payload's rate_limits solely from
# that session's own API responses, so every window in an idle tab is frozen,
# in the shared rate cache as much as in the payload. This is what lets the
# rate row correct itself while nobody is typing. The top-level five_hour and
# seven_day objects of the same response say the same thing with a
# `utilization` float; limits[] is read instead so all three windows come out
# of one pass, and those two are the fallback if a kind is ever renamed.
# `is_active` is NOT consulted: the weekly window reports false while it sits
# at 0%, which is still a real reading.
#
# This is the ONLY outbound network call anything in this plugin makes, and
# the endpoint is undocumented and versioned with the Claude Code binary, so
# every failure here is silent and leaves the previous cache untouched: no
# curl, no credentials file, no token in it, a timeout, a non-200, an
# {"error": ...} body, or output that does not parse. A metered session never
# gets here at all, statusline.sh does not spawn it.
#
# The bearer token is read from Claude Code's own ~/.claude/.credentials.json
# and reaches curl through a 0600 config file (-K) that is deleted straight
# after the call, never through argv, which `ps` shows to every local user.
# It is never logged and never echoed. A macOS install that
# keeps its credentials in the Keychain has no such file, so this exits
# without probing and the row simply never appears.
#
# Cache shape:
#   {"updated_at": <epoch>, "windows_at": <epoch>,
#    "models":  {"<display_name>": {percent, resets_at}},
#    "windows": {"five_hour": {used_percentage, resets_at}, "seven_day": {...}},
#    "windows_absent": ["seven_day"]}
# where every resets_at is a unix epoch, converted here so the render path
# never has to parse a timestamp. `windows` uses the payload's own
# used_percentage key so statusline.sh can feed it through the same helpers
# as a payload window. `windows_absent` lists the account windows the
# response positively reported as not existing (see the jq below); it is the
# only way statusline.sh can learn that a window went away (issue #3).
#
# The two stamps are not interchangeable. `updated_at` is the 300s throttle
# and moves on EVERY attempt, successful or not, so an endpoint that is down
# is not called once a second. `windows_at` moves only when a response
# actually parsed, and is what statusline.sh weighs against the shared rate
# cache: a failed probe must never let last hour's windows outrank a reading
# some other session published a minute ago.

case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
. "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null || exit 0

cc_version="${1:-}"
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
[ -f "$NUT_CREDENTIALS" ] || exit 0
nut_ensure_dirs

# Non-blocking, like the auth probe: a second session skips this round
# rather than queueing behind it.
nut_lock_acquire "$NUT_USAGE_LOCK" "$NUT_LOCK_STALE_USAGE" || exit 0

token=$(jq -r '.claudeAiOauth.accessToken // empty' "$NUT_CREDENTIALS" 2>/dev/null)
[ -n "$token" ] || exit 0

now=$(date +%s)

# The three headers beside Authorization are what the CLI itself sends. They
# are not decoration: the same request without them comes back
# {"error": {"type": "rate_limit_error"}}, measured 2026-09-10.
#
# The version is the payload's own `version` field rather than a `claude
# --version` fork, so the User-Agent always matches the binary actually
# running. An empty one still identifies the client as the CLI.
ua="claude-cli/${cc_version:-0.0.0} (external, cli)"

# The Authorization header goes in a curl config file (-K), never in argv:
# an argument is world-readable through `ps` for as long as the call runs,
# and this is a live account token. mktemp creates the file 0600 and the
# chmod is belt and braces for a platform whose mktemp does not. Any
# straggler from a run killed mid-flight is swept first; the lock is already
# held here, so no live file can be caught by that.
rm -f "$NUT_STATE_DIR"/usage_hdr.* 2>/dev/null
hdr=$(mktemp "$NUT_STATE_DIR/usage_hdr.XXXXXX" 2>/dev/null) || exit 0
chmod 600 "$hdr" 2>/dev/null
printf 'header = "Authorization: Bearer %s"\n' "$token" > "$hdr" 2>/dev/null || {
  rm -f "$hdr" 2>/dev/null; exit 0; }
token=""

body=$(nut_timeout 15 curl -s -m 8 -K "$hdr" \
  -H "Content-Type: application/json" \
  -H "x-app: cli" \
  -H "User-Agent: $ua" \
  -H "anthropic-beta: oauth-2025-04-20" \
  https://api.anthropic.com/api/oauth/usage 2>/dev/null) || body=""
rm -f "$hdr" 2>/dev/null

# Keep only the per-model weekly windows, and only those whose reset stamp
# converts cleanly. jq's fromdateiso8601 takes "...Z" and nothing else, so
# the fractional seconds are dropped and a "+00:00" offset is rewritten;
# anything carrying a different offset is skipped rather than guessed at.
new=""
[ -n "$body" ] && new=$(printf '%s' "$body" | jq -c --argjson now "$now" '
  def epoch: (strings // "")
             | sub("\\.[0-9]+"; "")
             | sub("\\+00:00$"; "Z")
             | (try fromdateiso8601 catch null);
  select(type == "object") | select(has("error") | not)
  | ((.limits? | arrays) // []) as $lim
  | [ $lim[]
      | select(.kind? == "weekly_scoped")
      | { name:    (.scope?.model?.display_name? | strings),
          percent: ((.percent | numbers) // 0),
          resets_at: (.resets_at | epoch) }
      | select(.name != null and .resets_at != null) ] as $scoped
  | [ $lim[]
      | select(.kind? == "session" or .kind? == "weekly_all")
      | { name: (if .kind == "session" then "five_hour" else "seven_day" end),
          used_percentage: ((.percent | numbers) // 0),
          resets_at: (.resets_at | epoch) }
      | select(.resets_at != null) ] as $acct
  # A window the account no longer has (issue #3). Only a response that
  # says so twice counts: the top-level key is present and null, which is
  # how the endpoint reports every window an account lacks, AND limits[]
  # holds no entry of that kind, parseable or not. A missing key, a missing
  # limits array or an entry whose stamp did not convert all say nothing,
  # so a renamed field or a parse failure can never wipe a live window.
  | . as $r
  | [ ["five_hour", "session"], ["seven_day", "weekly_all"]
      | .[0] as $w | .[1] as $k
      | select(($lim | length) > 0)
      | select(($r | has($w)) and $r[$w] == null)
      | select([$lim[] | select(.kind? == $k)] | length == 0)
      | $w ] as $absent
  | { updated_at: $now,
      windows_at: $now,
      models: ($scoped
               | map({ (.name): {percent: .percent, resets_at: .resets_at} })
               | add // {}),
      windows: ($acct
                | map({ (.name): {used_percentage: .used_percentage,
                                  resets_at: .resets_at} })
                | add // {}),
      windows_absent: $absent }' 2>/dev/null)

# A failed call moves updated_at and nothing else, carrying both `models` and
# `windows` forward untouched and leaving `windows_at` where it was. Without
# the updated_at move the 300s gate would fire on the very next render and an
# endpoint that is down would be called once a second forever; without the
# windows_at freeze statusline.sh would read those carried-forward windows as
# newly measured and let them outrank the shared rate cache. Both maps are
# kept rather than cleared because a transient failure says nothing about
# them, and an expired window is dropped at render time anyway.
#
# An empty `models` or `windows` map from a SUCCESSFUL call is written as-is:
# that is a real answer (this account has no per-model window, or the
# endpoint stopped reporting one of these kinds), not a failure.
if [ -z "$new" ]; then
  new=$(jq -c --argjson now "$now" \
    '{updated_at: $now,
      windows_at: ((.windows_at | numbers) // 0),
      models:  ((.models? | objects) // {}),
      windows: ((.windows? | objects) // {}),
      windows_absent: ((.windows_absent? | arrays) // [])}' \
    "$NUT_USAGE_CACHE" 2>/dev/null) \
    || new=""
  [ -n "$new" ] || new="{\"updated_at\":$now,\"windows_at\":0,\"models\":{},\"windows\":{},\"windows_absent\":[]}"
fi

nut_write_json_object "$new" "$NUT_USAGE_CACHE"
exit 0
