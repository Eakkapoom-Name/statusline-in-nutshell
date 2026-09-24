#!/usr/bin/env bash
# auth_cache_refresh.sh: background probe of `claude auth status`, feeding
# ~/.claude/nutshell/state/auth_cache.json.
#
# Usage: auth_cache_refresh.sh <session_id>
#
# statusline.sh needs to know whether a session is on a Claude.ai
# subscription (Pro, Max, Team, Enterprise) or on metered billing (API key,
# Bedrock, Vertex, a gateway), because that decides whether a rate-limit
# window is shown at all: metered billing never gets the rate_limits object,
# and a 0% row there is a lie. `claude auth status` reports subscriptionType
# as a string on a subscription and null (or no key at all) on metered
# billing. The probe costs about 170ms, far too slow for a 1s render, so it
# runs here in the background, like cost_cache_refresh.sh, and statusline.sh
# only ever reads the cache.
#
# The verdict is PER SESSION, not per machine, so the cache is a `sessions`
# map keyed by session_id. Auth is whatever the session was launched with:
# a Max tab and an ANTHROPIC_AUTH_TOKEN tab side by side get different
# answers, because this probe inherits the env of the session that spawned
# it. A single shared verdict let whichever tab wrote last decide what BOTH
# rendered. Entries older than a week are dropped on write.
#
# Cache shape: {"sessions": {"<session_id>": {subscription_type, updated_at, sig}}}
# where sig is .credentials.json's mtime at probe time. Every /login, logout
# and account switch rewrites that file, so statusline.sh re-probes as soon
# as the mtime moves instead of waiting out the cache age.

case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
. "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null || exit 0

session_id="${1:-}"
[ -n "$session_id" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0
nut_ensure_dirs

# One lock for the whole job, so the read-modify-write of the sessions map
# does not lose another session's entry. Non-blocking: a second session
# skips this round rather than queueing, its next render is a second later
# and the probe takes about 200ms, so it simply gets the lock then. This is
# the library's lock rather than flock, so the interleaving that used to
# lose an entry on stock macOS cannot happen there any more.
nut_lock_acquire "$NUT_AUTH_LOCK" "$NUT_LOCK_STALE_AUTH" || exit 0

now=$(date +%s)

# A hung probe is cut short at 15s on every platform: nut_timeout uses GNU
# timeout where it exists and its own watcher where it does not.
out=$(nut_timeout 15 claude auth status 2>/dev/null) || out=""

# The credentials mtime is read here, after the probe, so the stored
# signature always matches the state the verdict was taken from.
sig=$(nut_mtime "$NUT_CREDENTIALS") || sig=""

# The new entry, or nothing when the probe failed (non-zero exit, timeout,
# non-JSON output, an older Claude Code with no `auth status` at all).
entry=""
[ -n "$out" ] && entry=$(printf '%s' "$out" | jq -c --argjson now "$now" --arg sig "$sig" \
  'select(type == "object") | {subscription_type: (.subscriptionType // null), updated_at: $now, sig: $sig}' 2>/dev/null)

cur=$(jq -c 'select(type == "object")' "$NUT_AUTH_CACHE" 2>/dev/null)
[ -n "$cur" ] || cur='{}'

# Merge: drop entries older than a week (or stamped in the future), then
# write this session's entry. A failed probe keeps this session's previous
# verdict and only bumps the stamp, so a transient error never turns a known
# plan into an unknown one, and a persistently failing probe still cannot
# make statusline.sh fork `claude` on every 1s render.
new=$(printf '%s' "$cur" | jq -c --arg s "$session_id" --argjson now "$now" --arg sig "$sig" \
  --argjson e "${entry:-null}" '
  ((.sessions? | objects) // {}) as $all
  | ($all | with_entries(select((.value.updated_at? | numbers) != null
       and .value.updated_at > ($now - 604800) and .value.updated_at <= $now))) as $keep
  | (if $e != null then $e
     else (($all[$s]? | objects) // {}) + {updated_at: $now, sig: $sig} end) as $mine
  | {sessions: ($keep + {($s): $mine})}' 2>/dev/null)
[ -n "$new" ] || exit 0

nut_write_atomic "$new" "$NUT_AUTH_CACHE"
exit 0
