#!/usr/bin/env bash
# nutshell-doctor.sh: read-only report of what this plugin needs, what the
# machine has, and the exact command that closes each gap.
#
# It reports. It never installs, never writes, never touches the network.
# Installation is the setup skill's job, behind a question the user answers,
# because installing packages is a change to their machine and a
# `SessionStart` hook is the wrong place to make one. sync.sh therefore does
# not call this script at all.
#
# Written to survive the very thing it diagnoses: it must run and produce a
# useful report on a machine with no jq, so nothing outside --probe parses
# JSON, and the only tools used are the ones every POSIX system already
# has (--probe needs both ccusage and jq, and says so when either is
# absent rather than failing). Stock
# bash 3.2 (macOS), BSD userland, no GNU coreutils assumed, same rules as
# the rest of the plugin.
#
# Usage:
#   nutshell-doctor.sh              human-readable table
#   nutshell-doctor.sh --porcelain  tab-separated records, for the skill
#   nutshell-doctor.sh --probe      also run the ccusage schema probe (slow)
#
# Exit status: 0 when every REQUIRED dependency is satisfied, 1 when one is
# missing or too old. Optional gaps never fail the run, because the status
# line works without them; they only cost the features named in the report.

# Locale pin, for the same reason nutshell-lib.sh pins it: a comma-decimal
# locale changes how numbers print and compare.
LC_ALL=C
export LC_ALL

# nutshell-lib.sh is sourced when it is next to us (it only defines paths
# and helpers, and needs no jq to source) so the report can name the real
# install directory. Its absence is not fatal: a doctor that cannot run
# because the thing it diagnoses is broken is no doctor at all.
case "${BASH_SOURCE[0]}" in */*) NUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;; *) NUT_LIB_DIR=. ;; esac
. "$NUT_LIB_DIR/nutshell-lib.sh" 2>/dev/null
: "${NUT_BIN_DIR:=$HOME/.claude/nutshell/bin}"

porcelain=0
probe=0
for arg in "$@"; do
  case "$arg" in
    --porcelain) porcelain=1 ;;
    --probe)     probe=1 ;;
    # Print the header comment, from the line after the shebang up to the
    # first line that is not a comment. A fixed line range drifts silently
    # the moment the header is edited, which is how --help ends up printing
    # a stray sentence from whatever follows it.
    -h|--help)   awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           printf 'nutshell-doctor: unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# First dotted number in a --version line. Every tool this plugin touches
# prints its version differently ("jq-1.8.2", "ccusage 20.0.20",
# "2.1.224 (Claude Code)", "timeout (GNU coreutils) 9.11", "GNU bash,
# version 3.2.57(1)-release"), and in all of them the first dotted number is
# the version. Cheaper and steadier than a pattern per tool.
ver_of() {
  command -v "$1" >/dev/null 2>&1 || return 1
  "$1" --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1
}

# `$1 >= $2`, comparing dot-separated numbers field by field. Not `sort -V`:
# that is a GNU extension, and while macOS 26 happens to have it, older
# macOS does not, which is exactly the platform this script exists to
# report on. Missing fields count as 0, so "1.7" >= "1.7.0" holds. 10# is
# not decoration: a field like "08" is an invalid octal literal to bash and
# would abort the comparison.
ver_ge() {
  local a="$1" b="$2" i=1 fa fb
  while [ "$i" -le 4 ]; do
    fa=$(printf '%s' "$a" | cut -d. -f"$i"); [ -n "$fa" ] || fa=0
    fb=$(printf '%s' "$b" | cut -d. -f"$i"); [ -n "$fb" ] || fb=0
    if [ "$((10#$fa))" -gt "$((10#$fb))" ]; then return 0; fi
    if [ "$((10#$fa))" -lt "$((10#$fb))" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# The record separator, named rather than typed. A literal tab in the source
# is invisible, and an editor set to expand tabs turns it into spaces and
# breaks every reader of these records with no error anywhere.
tab=$'\t'

# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------

os_kind="unknown"; os_name="unknown"; os_version=""; os_arch=$(uname -m 2>/dev/null)
case "$(uname -s 2>/dev/null)" in
  Darwin)
    os_kind="macos"; os_name="macOS"
    os_version=$(sw_vers -productVersion 2>/dev/null)
    ;;
  Linux)
    os_kind="linux"; os_name="Linux"
    # /etc/os-release is the only cross-distro answer; ID_LIKE is what makes
    # a derivative (Mint, Pop!_OS, Zorin) resolve to its apt/dnf parent
    # instead of falling through to "unknown".
    if [ -r /etc/os-release ]; then
      # One subshell for all three values: sourcing it once per variable
      # read the same file three times to answer three questions.
      IFS="$tab" read -r os_name os_version os_like <<EOF
$(. /etc/os-release 2>/dev/null; printf '%s\t%s\t%s' "${ID:-Linux}" "${VERSION_ID:-}" "${ID_LIKE:-}")
EOF
      case " $os_name $os_like " in
        *" debian "*|*" ubuntu "*) os_family="debian" ;;
        *" fedora "*|*" rhel "*)   os_family="fedora" ;;
        *" arch "*)                os_family="arch" ;;
        *" suse "*)                os_family="suse" ;;
      esac
    fi
    # WSL runs Ubuntu's userland on a Microsoft kernel: apt is right, but
    # the report should say so, because it changes nothing here and
    # everything about where the user looks when something else breaks.
    case "$(uname -r 2>/dev/null)" in *[Mm]icrosoft*) os_name="$os_name (WSL)" ;; esac
    ;;
esac
: "${os_family:=$os_kind}"

# Package managers present, in the order this script would reach for them.
pkgmgrs=""
for m in brew apt-get dnf pacman zypper npm bun nix; do
  have "$m" && pkgmgrs="$pkgmgrs $m"
done
pkgmgrs="${pkgmgrs# }"
[ -n "$pkgmgrs" ] || pkgmgrs="none"

# ---------------------------------------------------------------------------
# remedies
#
# One function per dependency rather than a table, because the answer
# genuinely differs by OS and by what is already installed: ccusage has no
# distro package anywhere, so on Linux it walks a chain of channels and the
# right one depends on which package manager exists.
# ---------------------------------------------------------------------------

remedy_jq() {
  case "$os_kind" in
    macos)  have brew && { echo "brew install jq"; return; }
            echo "install Homebrew (https://brew.sh), then: brew install jq" ;;
    linux)  case "$os_family" in
              debian) echo "sudo apt-get install -y jq" ;;
              fedora) echo "sudo dnf install -y jq" ;;
              arch)   echo "sudo pacman -S --noconfirm jq" ;;
              suse)   echo "sudo zypper install -y jq" ;;
              *)      have brew && echo "brew install jq" || echo "install jq with your package manager" ;;
            esac ;;
    *)      echo "install jq with your package manager" ;;
  esac
}

# ccusage ships no distro package on any platform. Homebrew is first
# wherever it exists because its bottle is a self-contained native binary
# (no Node runtime) and it is bottled for Linux as well as macOS; the
# JavaScript channels come next only because they need a runtime the user
# may not want. `nix run` is last: it works, but it is not an install.
remedy_ccusage() {
  if have brew; then echo "brew install ccusage"; return; fi
  if [ "$os_kind" = "macos" ]; then
    echo "install Homebrew (https://brew.sh), then: brew install ccusage"; return
  fi
  if have npm; then echo "npm install -g ccusage   # may need sudo with a system node"; return; fi
  if have bun; then echo "bun add -g ccusage"; return; fi
  if have nix; then echo "nix run github:ccusage/ccusage   # runs it, does not install it"; return; fi
  echo "no channel found: install Homebrew, Node (npm) or Bun first"
}

# The channel a present ccusage came through, guessed from where its binary
# sits, because upgrading it through a different one leaves two copies and
# the wrong one first on PATH. Only reached when ccusage is already
# installed, so the guess always has a path to work from.
remedy_ccusage_upgrade() {
  local p
  p=$(command -v ccusage 2>/dev/null)
  case "$p" in
    *"/.bun/"*)                      echo "bun add -g ccusage@latest"; return ;;
    */Cellar/*|/opt/homebrew/*|/home/linuxbrew/*|/usr/local/Cellar/*)
                                     echo "brew upgrade ccusage"; return ;;
  esac
  if have brew; then echo "brew upgrade ccusage"
  elif have npm;  then echo "npm install -g ccusage@latest   # may need sudo with a system node"
  elif have bun;  then echo "bun add -g ccusage@latest"
  else echo "upgrade ccusage through whichever channel installed $p"
  fi
}

remedy_flock() {
  case "$os_kind" in
    macos) have brew && echo "brew install flock" || echo "install Homebrew (https://brew.sh), then: brew install flock" ;;
    *)     echo "part of util-linux; install util-linux with your package manager" ;;
  esac
}

# On macOS the fix is coreutils, and the reason it works is worth stating:
# Homebrew g-prefixes only the commands macOS also ships. macOS ships no
# `timeout`, so coreutils installs it unprefixed and `command -v timeout`
# finds it. No gnubin PATH entry is needed, and none should be added: that
# directory also shadows the system `date`, `stat` and `sort`, whose BSD
# behaviour this plugin's fallbacks are written against.
remedy_timeout() {
  case "$os_kind" in
    macos) have brew && echo "brew install coreutils" || echo "install Homebrew (https://brew.sh), then: brew install coreutils" ;;
    *)     echo "part of coreutils; install coreutils with your package manager" ;;
  esac
}

# ---------------------------------------------------------------------------
# ccusage schema probe (--probe)
#
# The authoritative check, and the only one that proves the cost windows
# will actually fill: run the real command against a one-day window and
# look for the field the refresher reads. A version comparison cannot do
# this, because the field name is not a documented function of the version.
# Costs seconds (it reads transcripts), which is why it is opt-in.
#
# It runs before the checks below, not after, because a failed probe is
# what downgrades the ccusage record: a binary that answers with the wrong
# schema is exactly as useless as one that is too old, and saying so in
# the record is what gives the setup skill something to act on.
# ---------------------------------------------------------------------------

probe_result="skipped"
if [ "$probe" -eq 1 ]; then
  if have ccusage && have jq; then
    today=$(date +%Y%m%d)
    if ccusage daily --since "$today" --json 2>/dev/null \
       | jq -e '(.daily // []) | length == 0 or (.[0] | has("period"))' >/dev/null 2>&1; then
      probe_result="ok"
    else
      probe_result="fail"
    fi
  else
    probe_result="unavailable"
  fi
fi

# ---------------------------------------------------------------------------
# checks
#
# Records are emitted as:
#   dep <name> <tier> <verdict> <version> <path> <remedy> <cost if absent>
# verdict is ok | old | missing. `-` stands in for an empty field so the
# record always has the same number of columns.
# ---------------------------------------------------------------------------

required_bad=0
records=""

add_dep() { # name tier verdict version path remedy loss
  records="$records$1$tab$2$tab$3$tab${4:--}$tab${5:--}$tab${6:--}$tab${7:--}
"
  [ "$2" = "required" ] && [ "$3" != "ok" ] && required_bad=1
  return 0
}

# jq. The one hard requirement: every script reads and writes its JSON
# through it. 1.6 is the floor, not because 1.5 is known to fail (every
# builtin and flag these scripts use predates it) but because 1.6 is the
# oldest version still shipped by a supported distro, so anything below it
# is a machine worth flagging rather than a machine worth supporting.
JQ_MIN="1.6"
if have jq; then
  # An empty version means `--version` printed something the pattern does
  # not match, which says nothing about how old the tool is. Reporting that
  # as `old` would fail the run and block the install over a parsing miss,
  # so an unknown version is reported as ok with no version, the same way
  # the optional tools below treat one.
  v=$(ver_of jq)
  if [ -z "$v" ]; then
    add_dep jq required ok - "$(command -v jq)" - -
  elif ver_ge "$v" "$JQ_MIN"; then
    add_dep jq required ok "$v" "$(command -v jq)" - -
  else
    add_dep jq required old "$v" "$(command -v jq)" "$(remedy_jq)" "the plugin is only tested from >= $JQ_MIN"
  fi
else
  add_dep jq required missing - - "$(remedy_jq)" "the status line cannot run at all"
fi

# bash. Reported, never remedied: the plugin is written for stock bash 3.2
# precisely so that macOS needs no newer one, and telling a macOS user to
# install bash would be telling them to fix a problem they do not have.
if have bash; then
  v=$(ver_of bash)
  if [ -z "$v" ]; then
    add_dep bash required ok - "$(command -v bash)" - -
  elif ver_ge "$v" "3.2"; then
    add_dep bash required ok "$v" "$(command -v bash)" - -
  else
    add_dep bash required old "$v" "$(command -v bash)" "install bash 3.2 or newer" "the plugin is only tested from >= 3.2"
  fi
else
  add_dep bash required missing - - "install bash" "the status line cannot run at all"
fi

# ccusage. No version floor is asserted here, and that is deliberate. The
# scripts read `.daily[].period`, a field older releases called something
# else; 19.0.3 is the oldest release the field is confirmed in, but the
# release notes never documented the rename, so any number written here
# would be a guess. A fresh install gets the latest and the question does
# not arise; an existing install is settled by --probe, which asks the
# binary instead of asking a changelog, and keeps working if the field is
# ever renamed again.
if have ccusage; then
  v=$(ver_of ccusage)
  if [ "$probe_result" = "fail" ]; then
    # Installed, and answering with a schema the refresher cannot read. The
    # windows stay empty exactly as if it were absent, so it is reported as
    # `old` with an upgrade command rather than `ok`: a verdict the setup
    # skill already knows how to act on.
    add_dep ccusage optional old "$v" "$(command -v ccusage)" "$(remedy_ccusage_upgrade)" \
      "answers without the .daily[].period field; the cost windows stay empty"
  else
    add_dep ccusage optional ok "$v" "$(command -v ccusage)" - -
  fi
else
  add_dep ccusage optional missing - - "$(remedy_ccusage)" \
    "today / week / month / all-time stay empty; reset-all-time unavailable"
fi

# claude on PATH. Only used by the background probe that decides whether
# this account has rate limits at all.
if have claude; then
  add_dep claude optional ok "$(ver_of claude)" "$(command -v claude)" - -
else
  add_dep claude optional missing - - "already installed if you are reading this; check your PATH" \
    "line 3 can show a 0% row it should have left out"
fi

# flock. Guarded everywhere it is used, so its absence costs no
# correctness: the writes are atomic (temp file, validate, rename) and the
# ledger merge is idempotent, so concurrent refreshes lose nothing worse
# than repeated work. What it buys is that repeated work not happening.
if have flock; then
  add_dep flock optional ok "$(ver_of flock)" "$(command -v flock)" - -
else
  add_dep flock optional missing - - "$(remedy_flock)" \
    "concurrent refreshes are not serialised (wasted work, no data loss)"
fi

# timeout. Same shape: guarded, so its absence is a missing safety net
# rather than a failure. Without it a hung `claude auth status` is never
# cut short, and reset-all-time can hang instead of failing at 90s.
if have timeout; then
  add_dep timeout optional ok "$(ver_of timeout)" "$(command -v timeout)" - -
else
  add_dep timeout optional missing - - "$(remedy_timeout)" \
    "hung auth probe and reset-all-time are not cut short"
fi

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

install_state="ok"
for f in $NUT_INSTALLED_FILES; do
  [ -x "$NUT_BIN_DIR/$f" ] || install_state="incomplete"
done
[ -n "$NUT_INSTALLED_FILES" ] || install_state="unknown"

if [ "$porcelain" -eq 1 ]; then
  printf 'os\t%s\t%s\t%s\t%s\n' "$os_kind" "$os_name" "${os_version:--}" "${os_arch:--}"
  printf 'pkgmgr\t%s\n' "$pkgmgrs"
  printf 'install\t%s\t%s\n' "$install_state" "$NUT_BIN_DIR"
  printf 'probe\tccusage_schema\t%s\n' "$probe_result"
  printf '%s' "$records" | while IFS="$tab" read -r n t v ver p r l; do
    [ -n "$n" ] || continue
    printf 'dep\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$t" "$v" "$ver" "$p" "$r" "$l"
  done
  exit "$required_bad"
fi

printf '%s %s (%s), %s\n' "$os_name" "${os_version:-?}" "$os_kind" "${os_arch:-?}"
printf 'package managers: %s\n' "$pkgmgrs"
printf 'installed scripts: %s (%s)\n' "$install_state" "$NUT_BIN_DIR"
[ "$probe_result" = "skipped" ] || printf 'ccusage schema probe: %s\n' "$probe_result"
printf '\n%-9s %-9s %-8s %-9s %s\n' DEP TIER STATUS VERSION "FIX"
printf '%s' "$records" | while IFS="$tab" read -r n t v ver p r l; do
  [ -n "$n" ] || continue
  if [ "$v" = "ok" ]; then
    printf '%-9s %-9s %-8s %-9s %s\n' "$n" "$t" "$v" "$ver" "-"
  else
    printf '%-9s %-9s %-8s %-9s %s\n' "$n" "$t" "$v" "$ver" "$r"
    # One label for all three verdicts. The sentence differs (a version
    # floor, a lost feature, a binary answering with the wrong schema) but
    # every one of them is the reason to run the command on the line above.
    printf '%-9s %-9s %-8s %-9s   why: %s\n' "" "" "" "" "$l"
  fi
done
exit "$required_bad"
