#!/usr/bin/env bash
# nutshell-install-deps.sh: close the gaps nutshell-doctor.sh reports, on
# whatever OS this is.
#
# The doctor decides WHAT is missing and WHICH command closes it. This
# script decides only whether that command can be run here, what version it
# would land, and then runs it. Every remedy string stays in the doctor, so
# there is exactly one place where a package name or a channel is written
# down.
#
# Usage:
#   nutshell-install-deps.sh --plan [--porcelain]
#   nutshell-install-deps.sh --apply <dep>... [--dry-run]
#   nutshell-install-deps.sh --apply all   [--dry-run]
#
# --plan resolves a channel and a candidate version per missing dependency
# and prints them WITHOUT touching the machine. That split is the point:
# the setup skill shows the plan to the user, asks once, and only then
# calls --apply with the names the user agreed to. Nothing here installs
# anything the caller did not name.
#
# Two dependencies are never installed by this script, on any OS:
#
#   claude   is Claude Code itself. If it is missing from PATH the binary
#            reading this is still running, so there is nothing to install,
#            only a PATH to fix.
#   bash     the plugin targets stock bash 3.2 precisely so macOS needs no
#            newer one, and a machine with no bash at all cannot run this.
#
# Homebrew is never installed either. Where the doctor's fix column says to
# install it first, that is reported and left to the user: it is a far
# larger change to their machine than any package here.
#
# sudo: a fix that starts with sudo is run only when sudo needs no
# password (`sudo -n true` succeeds). A tool call has no terminal, so a
# password prompt would block until something kills it, and a background
# prompt nobody can answer is worse than a printed command. The command is
# reported instead, for the user to run themselves.
#
# Exit status: 0 when every named dependency ended up satisfied, 1 when one
# of them did not. 2 for a usage error or a doctor that will not run.

LC_ALL=C
export LC_ALL

case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
. "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null
DOCTOR="$NUT_LIB_DIR/nutshell-doctor.sh"

# nut_timeout comes from the library. Its absence is not fatal here (the
# doctor survives a missing library too), it only means a hung installer
# hangs for as long as the caller allows rather than for INSTALL_TIMEOUT.
have_timeout_fn=0
type nut_timeout >/dev/null 2>&1 && have_timeout_fn=1
INSTALL_TIMEOUT=900
PROBE_TIMEOUT=25

tab=$'\t'
us=$'\x1f'

mode=""
porcelain=0
dry_run=0
wanted=""
for arg in "$@"; do
  case "$arg" in
    --plan)      mode="plan" ;;
    --apply)     mode="apply" ;;
    --porcelain) porcelain=1 ;;
    --dry-run)   dry_run=1 ;;
    -h|--help)   awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)          printf 'nutshell-install-deps: unknown option: %s\n' "$arg" >&2; exit 2 ;;
    *)           wanted="$wanted $arg" ;;
  esac
done
wanted="${wanted# }"

[ -n "$mode" ] || { printf 'nutshell-install-deps: --plan or --apply is required\n' >&2; exit 2; }
[ "$mode" = "apply" ] && [ -z "$wanted" ] && {
  printf 'nutshell-install-deps: --apply needs a dependency name, or "all"\n' >&2; exit 2; }
[ -f "$DOCTOR" ] || { printf 'nutshell-install-deps: cannot find %s\n' "$DOCTOR" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command string under a limit. eval, deliberately: the string is a
# remedy this repo wrote in nutshell-doctor.sh, never anything read from
# the network, a config file or an argument, and it carries flags that have
# to stay flags rather than becoming one quoted word.
run_cmd() {
  if [ "$have_timeout_fn" -eq 1 ]; then
    nut_timeout "$INSTALL_TIMEOUT" bash -c "$1"
  else
    bash -c "$1"
  fi
}
# The trailing `tr -d` is not decoration: winget, scoop and choco are native
# Windows executables and end every line with CRLF, so without it the version
# carries a carriage return into the tab-separated plan record and into what
# the user is shown. Same hazard as the CR strip statusline.sh does on a
# native Windows jq.
probe_cmd() {
  if [ "$have_timeout_fn" -eq 1 ]; then
    nut_timeout "$PROBE_TIMEOUT" bash -c "$1" 2>/dev/null
  else
    bash -c "$1" 2>/dev/null
  fi | tr -d '\r'
}

# ---------------------------------------------------------------------------
# reading the doctor
# ---------------------------------------------------------------------------

doctor_out=$(bash "$DOCTOR" --porcelain 2>/dev/null)
# Exit 1 only means a dependency is missing, which is the normal reason to
# be here. Empty output is the real failure.
[ -n "$doctor_out" ] || { printf 'nutshell-install-deps: %s produced no records\n' "$DOCTOR" >&2; exit 2; }

os_kind=$(printf '%s\n' "$doctor_out" | awk -F"$tab" '$1 == "os" { print $2; exit }')

# ---------------------------------------------------------------------------
# classifying a remedy
#
# The doctor writes two kinds of fix: a command that can be run, and a
# sentence for a human. They are told apart by the first word, against the
# list of managers this script knows how to drive, because a sentence never
# starts with one of those.
# ---------------------------------------------------------------------------

CHANNELS="brew apt-get dnf pacman zypper npm pnpm bun winget scoop choco"

# Sets CLS_ACTION, CLS_CHANNEL, CLS_CMD, CLS_REASON from a fix string.
classify() {
  local fix="$1" first rest
  CLS_ACTION="skip"; CLS_CHANNEL="-"; CLS_CMD="-"; CLS_REASON="-"

  # The trailing "# ..." note some remedies carry is for the reader, not
  # for the shell. Stripping it here keeps it out of the plan the user is
  # shown and out of the command that runs.
  fix="${fix%%#*}"
  # Trailing whitespace left by that cut.
  while :; do case "$fix" in *' '|*"$tab") fix="${fix%?}" ;; *) break ;; esac; done

  case "$fix" in
    -|"") CLS_REASON="no fix offered"; return ;;
  esac

  first="${fix%% *}"
  rest="$fix"
  if [ "$first" = "sudo" ]; then
    rest="${fix#sudo }"
    first="${rest%% *}"
  fi

  case " $CHANNELS " in
    *" $first "*) ;;
    *) CLS_REASON="$fix"; return ;;
  esac
  CLS_CHANNEL="$first"

  if [ "$fix" != "$rest" ] && [ "$(id -u 2>/dev/null)" = "0" ]; then
    # Already root, which is the normal state in a container image. Many of
    # those ship no sudo at all, so probing for one would report a password
    # prompt that can never happen and skip an install that would have
    # worked. The prefix is simply dropped.
    CLS_CMD="$rest"
  elif [ "$fix" != "$rest" ]; then
    # A sudo fix. -n on the probe AND on the command itself: the probe
    # answers whether a password is needed, the flag on the real command is
    # what guarantees it can never sit waiting for one if the cached
    # credential expires between the two.
    if sudo -n true >/dev/null 2>&1; then
      CLS_CMD="sudo -n $rest"
    else
      CLS_ACTION="skip"
      CLS_CMD="-"
      CLS_REASON="needs a sudo password, which a tool call cannot answer; run it yourself: $fix"
      return
    fi
  else
    CLS_CMD="$fix"
  fi

  have "$CLS_CHANNEL" || { CLS_ACTION="skip"; CLS_REASON="$CLS_CHANNEL is not installed"; CLS_CMD="-"; return; }
  CLS_ACTION="run"
}

# The package token of a command: the last argument that is not a flag.
# True for every remedy shape the doctor emits, including winget's, where
# the id sits after --id and every later token is a flag.
pkg_of() {
  local w out=""
  for w in $1; do
    case "$w" in -*) ;; *) out="$w" ;; esac
  done
  printf '%s' "${out%@*}"
}

# The version the channel would install. Best effort by design: every one
# of these asks a package index, several ask it over the network, and a
# channel that will not answer in PROBE_TIMEOUT is not a reason to refuse
# the install. An unknown version is reported as "?" rather than guessed.
version_of() { # channel pkg
  local ch="$1" pkg="$2" v=""
  case "$ch" in
    apt-get) v=$(probe_cmd "apt-cache policy '$pkg'" | awk '/Candidate:/ { print $2; exit }') ;;
    dnf)     v=$(probe_cmd "dnf --quiet info '$pkg'" | awk -F': *' '/^Version/ { print $2; exit }') ;;
    pacman)  v=$(probe_cmd "pacman -Si '$pkg'" | awk -F': *' '/^Version/ { print $2; exit }') ;;
    zypper)  v=$(probe_cmd "zypper --non-interactive info '$pkg'" | awk -F': *' '/^Version/ { print $2; exit }') ;;
    brew)    v=$(probe_cmd "brew info --quiet '$pkg'" | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1) ;;
    npm|pnpm|bun)
             # npm answers for all three: a bun or pnpm global install of a
             # published package resolves the same registry entry, and
             # neither has a query as terse as `npm view <pkg> version`.
             have npm && v=$(probe_cmd "npm view '$pkg' version" | tail -1) ;;
    winget)  v=$(probe_cmd "winget show --id '$pkg' -e" | awk -F': *' '/^Version/ { print $2; exit }') ;;
    scoop)   v=$(probe_cmd "scoop info '$pkg'" | awk -F': *' '/^Version/ { print $2; exit }') ;;
    choco)   v=$(probe_cmd "choco search '$pkg' --exact --limit-output" | head -1 | cut -d'|' -f2) ;;
  esac
  # Anything with a space in it is a sentence the tool printed instead of a
  # version (an error, a prompt, a "not found"), never a version.
  case "$v" in *' '*|'') v="" ;; esac
  printf '%s' "${v:-?}"
}

# ---------------------------------------------------------------------------
# the plan
#
# One line per dependency the doctor did not call ok, in the doctor's own
# order, which is jq, bash, ccusage, claude: the stop conditions first.
#
#   plan <dep> <run|skip> <channel> <version> <command or reason> <current verdict>
# ---------------------------------------------------------------------------

plan_lines=""
build_plan() {
  local n t v ver p r l skip_ver
  plan_lines=""
  # A here-string would be simpler and is bash 4 only. The pipe would put
  # the loop in a subshell, where plan_lines would not survive it.
  while IFS="$tab" read -r kind n t v ver p r l; do
    [ "$kind" = "dep" ] || continue
    [ "$v" = "ok" ] && continue
    case "$n" in
      claude|bash) plan_lines="$plan_lines$n${us}skip${us}-${us}-${us}${r}${us}$v
"; continue ;;
    esac
    classify "$r"
    if [ "$CLS_ACTION" = "run" ]; then
      plan_lines="$plan_lines$n${us}run${us}$CLS_CHANNEL${us}$(version_of "$CLS_CHANNEL" "$(pkg_of "$CLS_CMD")")${us}$CLS_CMD${us}$v
"
    else
      # A skipped dependency still gets its version resolved when the
      # channel is here and only the permission to use it is not, which is
      # every sudo case on a desktop Linux. The user is being handed a
      # command to run themselves, and the version is the part that tells
      # them what it will land.
      skip_ver="-"
      if [ "$CLS_CHANNEL" != "-" ] && have "$CLS_CHANNEL"; then
        skip_ver=$(version_of "$CLS_CHANNEL" "$(pkg_of "$r")")
      fi
      plan_lines="$plan_lines$n${us}skip${us}$CLS_CHANNEL${us}$skip_ver${us}${CLS_REASON}${us}$v
"
    fi
  done <<EOF
$doctor_out
EOF
}

build_plan

if [ "$mode" = "plan" ]; then
  if [ -z "$plan_lines" ]; then
    [ "$porcelain" -eq 1 ] || printf 'Every dependency is already satisfied.\n'
    exit 0
  fi
  printf '%s' "$plan_lines" | while IFS="$us" read -r n act ch ver cmd verdict; do
    [ -n "$n" ] || continue
    if [ "$porcelain" -eq 1 ]; then
      printf 'plan\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$act" "$ch" "$ver" "$cmd" "$verdict"
    elif [ "$act" = "run" ]; then
      printf '%s %s (%s, currently %s): %s\n' "$n" "$ver" "$ch" "$verdict" "$cmd"
    elif [ "$ver" != "-" ] && [ "$ver" != "?" ]; then
      printf '%s %s (%s, currently %s): NOT installed, %s\n' "$n" "$ver" "$ch" "$verdict" "$cmd"
    else
      printf '%s (currently %s): NOT installed, %s\n' "$n" "$verdict" "$cmd"
    fi
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

failed=0
ran=0
results=""

wants() { # name
  case " $wanted " in
    *" all "*) return 0 ;;
    *" $1 "*)  return 0 ;;
    *)         return 1 ;;
  esac
}

# The loop reads the plan through a here-document for the same reason
# build_plan does: a pipe would hide every count it keeps.
while IFS="$us" read -r n act ch ver cmd verdict; do
  [ -n "$n" ] || continue
  wants "$n" || continue
  if [ "$act" != "run" ]; then
    results="$results$n${us}skipped${us}${cmd}
"
    failed=1
    continue
  fi
  if [ "$dry_run" -eq 1 ]; then
    results="$results$n${us}dry-run${us}${cmd}
"
    continue
  fi
  printf '%s\n' "+ $cmd" >&2
  if run_cmd "$cmd" >&2; then
    results="$results$n${us}installed${us}${cmd}
"
    ran=1
  else
    rc=$?
    # A Debian family install fails on a machine whose package index has
    # never been fetched, or is old enough that the version it names is
    # gone from the mirror. That is one apt-get update away and is by far
    # the most common failure here, so it is retried once rather than
    # reported. Anything else is reported as it happened.
    if [ "$ch" = "apt-get" ] && sudo -n true >/dev/null 2>&1; then
      printf '%s\n' "+ sudo -n apt-get update" >&2
      run_cmd "sudo -n apt-get update" >&2
      if run_cmd "$cmd" >&2; then
        results="$results$n${us}installed${us}${cmd}
"
        ran=1
        continue
      fi
    fi
    hint=$(printf '%s\n' "$doctor_out" | awk -F"$tab" -v d="$n" '$1 == "dep" && $2 == d { print $7; exit }')
    case "$hint" in *'#'*) printf '%s\n' "  the doctor's note on this fix: ${hint#*#}" >&2 ;; esac
    results="$results$n${us}failed (exit $rc)${us}${cmd}
"
    failed=1
  fi
done <<EOF
$plan_lines
EOF

# The verdict comes from the doctor again, never from the exit status of
# the install: a package manager that reports success while leaving the
# binary somewhere this shell cannot see it (a fresh scoop shim, a user
# npm prefix) is exactly the case worth catching, and only a second look
# catches it.
if [ "$ran" -eq 1 ]; then
  doctor_out=$(bash "$DOCTOR" --porcelain 2>/dev/null)
fi

if [ -z "$results" ]; then
  [ "$porcelain" -eq 1 ] || printf 'Nothing to install: every dependency named is already satisfied.\n'
  exit 0
fi

printf '%s' "$results" | while IFS="$us" read -r n state cmd; do
  [ -n "$n" ] || continue
  final=$(printf '%s\n' "$doctor_out" | awk -F"$tab" -v d="$n" '$1 == "dep" && $2 == d { print $4; exit }')
  if [ "$porcelain" -eq 1 ]; then
    printf 'result\t%s\t%s\t%s\t%s\n' "$n" "$state" "${final:--}" "$cmd"
  else
    printf '%s: %s, now %s\n' "$n" "$state" "${final:-unknown}"
  fi
done

# One more read of the doctor's own verdicts, so a dependency that was
# installed but landed off PATH fails the run rather than passing it.
for d in $wanted; do
  [ "$d" = "all" ] && continue
  v=$(printf '%s\n' "$doctor_out" | awk -F"$tab" -v n="$d" '$1 == "dep" && $2 == n { print $4; exit }')
  [ -z "$v" ] || [ "$v" = "ok" ] || failed=1
done

exit "$failed"
