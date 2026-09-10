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
# Cache shape: {"updated_at": <epoch>, "models": {"<display_name>": {percent, resets_at}}}
# where resets_at is a unix epoch, converted here so the render path never
# has to parse a timestamp.

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
  select(type == "object") | select(has("error") | not)
  | [ ((.limits? | arrays) // [])[]
      | select(.kind? == "weekly_scoped")
      | { name:    (.scope?.model?.display_name? | strings),
          percent: ((.percent | numbers) // 0),
          resets_at: ((.resets_at | strings // "")
                      | sub("\\.[0-9]+"; "")
                      | sub("\\+00:00$"; "Z")
                      | (try fromdateiso8601 catch null)) }
      | select(.name != null and .resets_at != null) ]
  | { updated_at: $now,
      models: (map({ (.name): {percent: .percent, resets_at: .resets_at} })
               | add // {}) }' 2>/dev/null)

# A failed call still stamps the cache, keeping whatever windows were last
# seen. Without that the timestamp would stay old, statusline.sh's 300s gate
# would fire on the very next render, and an endpoint that is down would be
# called once a second forever. The old windows are kept rather than cleared
# because a transient failure says nothing about them, and an expired one is
# dropped at render time anyway.
#
# An empty models map from a SUCCESSFUL call is written as-is: that is a real
# answer (this account has no per-model window), not a failure.
if [ -z "$new" ]; then
  new=$(jq -c --argjson now "$now" \
    '{updated_at: $now, models: ((.models? | objects) // {})}' \
    "$NUT_USAGE_CACHE" 2>/dev/null) \
    || new=""
  [ -n "$new" ] || new="{\"updated_at\":$now,\"models\":{}}"
fi

nut_write_json_object "$new" "$NUT_USAGE_CACHE"
exit 0
