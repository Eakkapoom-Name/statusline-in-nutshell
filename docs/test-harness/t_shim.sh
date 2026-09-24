#!/usr/bin/env bash
# Shim unit tests. Run with PATH scrubbed of flock/timeout to exercise the
# fallback branches, and again with the real binaries present.
LIB="$1"
export HOME="$2"
mkdir -p "$HOME/.claude/nutshell/locks"
. "$LIB"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
L="$NUT_LOCK_DIR/t.lock"
rm -f "$L.held"

# 1 acquire succeeds, creates .held not the bare path
if nut_lock_acquire "$L" 60 && [ -f "$L.held" ] && [ ! -f "$L" ]; then ok "acquire creates <lock>.held"; else bad "acquire" "no held file"; fi

# 2 second acquire in a separate process fails
if bash -c '. "$1"; nut_lock_acquire "$2" 60' _ "$LIB" "$L"; then bad "reentry" "second acquire succeeded"; else ok "second holder is refused"; fi

# 3 noclobber restored after a refused attempt
bash -c '. "$1"; nut_lock_acquire "$2" 60 >/dev/null 2>&1; case "$-" in *C*) exit 1;; *) exit 0;; esac' _ "$LIB" "$L" \
  && ok "noclobber restored on the refused path" || bad "noclobber" "left enabled"

# 4 plain redirection still works after a refused attempt
bash -c '. "$1"; : > "$3"; nut_lock_acquire "$2" 60 >/dev/null 2>&1; echo x > "$3"' _ "$LIB" "$L" "$HOME/w.txt" 2>/dev/null \
  && [ -s "$HOME/w.txt" ] && ok "later > overwrite still works" || bad "overwrite" "redirection broken"

# 5 release frees it
nut_lock_release "$L"
[ ! -f "$L.held" ] && ok "release removes the held file" || bad "release" "held file remains"

# 6 EXIT trap releases when the holder exits without calling release
bash -c '. "$1"; nut_lock_acquire "$2" 60' _ "$LIB" "$L" >/dev/null 2>&1
[ ! -f "$L.held" ] && ok "EXIT trap releases on exit" || bad "trap" "held file leaked"

# 7 stale break: a lock older than its max age is taken over
printf '99999\n' > "$L.held"
touch -t 200001010000 "$L.held" 2>/dev/null || touch -d '-3000 seconds' "$L.held"
if nut_lock_acquire "$L" 60; then ok "stale lock is broken"; else bad "stale" "not broken"; fi
nut_lock_release "$L"

# 8 fresh lock is NOT broken
printf '99999\n' > "$L.held"
if nut_lock_acquire "$L" 60; then bad "fresh" "fresh lock was stolen"; else ok "fresh lock is not stolen"; fi
rm -f "$L.held"

# 9 mutual exclusion under 20 concurrent processes
LOG="$HOME/conc.log"; : > "$LOG"
i=0
while [ "$i" -lt 20 ]; do
  bash -c '. "$1"; nut_lock_acquire "$2" 60 || exit 0; printf "in\n" >> "$3"; sleep 1' _ "$LIB" "$L" "$LOG" &
  i=$((i+1))
done
wait
n=$(wc -l < "$LOG" | tr -d ' ')
[ "$n" = "1" ] && ok "20 concurrent starters, exactly 1 entered" || bad "concurrency" "$n entered, want 1"
rm -f "$L.held"

# 10 nut_lock_wait gets it once the holder goes away
( . "$LIB"; nut_lock_acquire "$L" 60; sleep 2 ) &
sleep 1
s=$(date +%s)
if nut_lock_wait "$L" 60 10; then e=$(date +%s); ok "lock_wait acquired after $((e-s))s"; nut_lock_release "$L"; else bad "lock_wait" "gave up"; fi
wait

# 11 lock_wait gives up at its cap
( . "$LIB"; nut_lock_acquire "$L" 600; sleep 4 ) &
sleep 1
if nut_lock_wait "$L" 600 2; then bad "lock_wait cap" "acquired when it should not"; else ok "lock_wait honours its cap"; fi
wait
rm -f "$L.held"

# 12 nut_timeout: fast command returns output and rc 0, and returns FAST
s=$(date +%s)
out=$(nut_timeout 15 bash -c 'printf "hello\n"; exit 0'); rc=$?
e=$(date +%s)
[ "$out" = "hello" ] && [ "$rc" -eq 0 ] && ok "timeout: output captured, rc 0" || bad "timeout out" "out=[$out] rc=$rc"
[ "$((e-s))" -lt 3 ] && ok "timeout: fast command returns in $((e-s))s, not at the limit" || bad "timeout blocking" "took $((e-s))s"

# 13 nut_timeout kills a slow command
s=$(date +%s)
out=$(nut_timeout 2 bash -c 'sleep 20; printf "late\n"'); rc=$?
e=$(date +%s)
[ "$rc" -ne 0 ] && [ -z "$out" ] && [ "$((e-s))" -lt 6 ] && ok "timeout: slow command killed at $((e-s))s, rc=$rc" || bad "timeout kill" "rc=$rc out=[$out] took $((e-s))s"

# 14 nut_timeout preserves a non-zero exit of its own
nut_timeout 15 bash -c 'exit 3'; rc=$?
[ "$rc" -eq 3 ] && ok "timeout: child exit status preserved" || bad "timeout rc" "got $rc want 3"

# 15 nut_timeout under set -e in the caller
bash -c 'set -e; . "$1"; nut_timeout 2 bash -c "sleep 9" || true; printf "survived\n"' _ "$LIB" | grep -q survived \
  && ok "set -e caller survives a timed-out child" || bad "set -e" "caller died"

# 16 a timeout that is on PATH but is not coreutils, which is what Git for
# Windows exposes as C:\Windows\System32\timeout.exe
mkdir -p "$HOME/badpath"
printf '#!/bin/sh\necho "ERROR: Invalid argument/option - %s" >&2\nexit 1\n' '$1' > "$HOME/badpath/timeout"
chmod +x "$HOME/badpath/timeout"
out=$(PATH="$HOME/badpath:$PATH" NUT_GNU_TIMEOUT= bash -c '. "$1"; nut_timeout 15 printf hello' _ "$LIB" 2>/dev/null); rc=$?
[ "$out" = "hello" ] && [ "$rc" -eq 0 ] && ok "non-coreutils timeout on PATH is bypassed" || bad "timeout gate" "out=[$out] rc=$rc"

# 17 the same impostor must not swallow the kill path either
s=$(date +%s)
out=$(PATH="$HOME/badpath:$PATH" NUT_GNU_TIMEOUT= bash -c '. "$1"; nut_timeout 2 sleep 20' _ "$LIB" 2>/dev/null); rc=$?
e=$(date +%s)
[ "$rc" -ne 0 ] && [ "$((e-s))" -lt 6 ] && ok "impostor timeout still gets the watcher kill at $((e-s))s" || bad "timeout gate kill" "rc=$rc took $((e-s))s"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
