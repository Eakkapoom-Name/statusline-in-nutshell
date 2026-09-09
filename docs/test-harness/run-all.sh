#!/usr/bin/env bash
# Runs every suite twice where it matters: once with whatever flock and
# timeout this machine has, and once against a PATH that omits exactly those
# two binaries, which is the code path stock macOS and Git for Windows take.
#
#   bash docs/test-harness/run-all.sh [path-to-repo]
#
# Writes nothing outside its own temp directory and never touches the real
# ~/.claude: every suite runs against a fake HOME it creates itself.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO="${1:-$(cd "$HERE/../.." && pwd)}"
[ -f "$REPO/skills/nutshell-setup/scripts/nutshell-lib.sh" ] || {
  echo "not a statusline-in-nutshell checkout: $REPO" >&2; exit 2; }
LIB="$REPO/skills/nutshell-setup/scripts/nutshell-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nutshell-harness.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

# A mirror of PATH with flock and timeout left out. Symlinks rather than a
# shell function, since `command -v` finds a function and would defeat the
# whole point of the exercise.
MIRROR="$WORK/nopath"; mkdir -p "$MIRROR"
IFS=: read -r -a _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -x "$f" ] && [ ! -d "$f" ] || continue
    b=${f##*/}
    case "$b" in flock|timeout) continue ;; esac
    [ -e "$MIRROR/$b" ] || ln -s "$f" "$MIRROR/$b" 2>/dev/null
  done
done

fails=0
run() { # label suite [mirror]
  local label="$1" suite="$2" mirror="${3:-}" home="$WORK/h$RANDOM$RANDOM" out
  mkdir -p "$home"
  printf '### %s\n' "$label"
  if [ -n "$mirror" ]; then
    out=$(PATH="$MIRROR" bash "$HERE/$suite" "$REPO" "$home" 2>&1)
  else
    out=$(bash "$HERE/$suite" "$REPO" "$home" 2>&1)
  fi
  printf '%s\n' "$out" | grep -E '^(FAIL|[0-9]+ passed)' || printf '%s\n' "$out" | tail -3
  printf '%s' "$out" | grep -q ' 0 failed' || fails=$((fails + 1))
}

printf '### syntax\n'
for f in "$REPO"/hooks/*.sh "$REPO"/skills/nutshell-setup/scripts/*.sh; do
  bash -n "$f" || { echo "FAIL $f"; fails=$((fails + 1)); }
done
echo ok

# t_shim.sh takes the library path rather than the repo root.
for mode in real shim; do
  home="$WORK/shim$mode"; mkdir -p "$home"
  printf '### shim units, %s\n' "$mode"
  if [ "$mode" = shim ]; then out=$(PATH="$MIRROR" bash "$HERE/t_shim.sh" "$LIB" "$home" 2>&1)
  else out=$(bash "$HERE/t_shim.sh" "$LIB" "$home" 2>&1); fi
  printf '%s\n' "$out" | grep -E '^(FAIL|[0-9]+ passed)'
  printf '%s' "$out" | grep -q ' 0 failed' || fails=$((fails + 1))
done

run "integration, real"  t_integ.sh
run "integration, shim"  t_integ.sh mirror
run "upgrade"            t_upgrade.sh
run "kill paths, real"   t_kill.sh
run "kill paths, shim"   t_kill.sh mirror
run "mode"               t_modeassert.sh

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo "every suite passed" || echo "$fails suite(s) failed")"
[ "$fails" -eq 0 ]
