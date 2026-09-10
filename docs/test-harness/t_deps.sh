#!/usr/bin/env bash
# Assertions for nutshell-doctor.sh and nutshell-install-deps.sh: what the
# doctor reports per OS, and what the installer decides to run.
#
# Nothing here installs anything or reaches the network. Every package
# manager is a stub in a directory ahead of PATH that records its argv, and
# the OS is decided by a stub uname, so the macOS and Windows arms are
# exercised on Linux.
REPO="$1"; export HOME="$2"
W="$HOME/deps"; mkdir -p "$W/bin" "$W/stub"
for f in nutshell-lib.sh nutshell-doctor.sh nutshell-install-deps.sh; do
  cp "$REPO/skills/nutshell-setup/scripts/$f" "$W/bin/$f"
done
DOC="$W/bin/nutshell-doctor.sh"; INS="$W/bin/nutshell-install-deps.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

# A PATH with every dependency and every package manager removed, so each
# case can put back exactly the ones it is about. Symlinks, not functions:
# the scripts decide with `command -v`.
MIRROR="$W/mirror"; mkdir -p "$MIRROR"
IFS=: read -r -a _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -x "$f" ] && [ ! -d "$f" ] || continue
    b=${f##*/}
    case "$b" in jq|ccusage|claude|curl|brew|npm|bun|pnpm|nix|winget|scoop|choco|sudo|uname|sw_vers) continue ;; esac
    [ -e "$MIRROR/$b" ] || ln -s "$f" "$MIRROR/$b" 2>/dev/null
  done
done
# uname has to be there for the doctor to run at all; the OS stubs below
# shadow it from $W/stub.
ln -s "$(command -v uname)" "$MIRROR/uname" 2>/dev/null

stub() { # name body
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$W/stub/$1"; chmod +x "$W/stub/$1"
}
clear_stubs() { rm -f "$W"/stub/*; }
P() { PATH="$W/stub:$MIRROR" "$@"; }

field() { # kind name column   -> that column of the first matching record
  awk -F'\t' -v k="$1" -v n="$2" -v c="$3" '$1 == k && $2 == n { print $c; exit }'
}

# --- the doctor on this machine, with everything really installed --------
out=$(bash "$DOC" --porcelain 2>/dev/null); rc=$?
case "$out" in *"dep"*jq*) ok "the doctor emits a jq record" ;; *) bad "doctor jq record" "$out" ;; esac
eq "five dependencies are reported" "$(printf '%s\n' "$out" | grep -c '^dep')" "5"
eq "curl is the one optional tier" "$(printf '%s\n' "$out" | field dep curl 3)" "optional"
eq "exit 0 while every required dependency is present" "$rc" "0"

# --- nothing installed at all --------------------------------------------
clear_stubs
out=$(P bash "$DOC" --porcelain 2>/dev/null); rc=$?
eq "a missing jq is reported missing" "$(printf '%s\n' "$out" | field dep jq 4)" "missing"
eq "and the run exits 1" "$rc" "1"
eq "bash is still found" "$(printf '%s\n' "$out" | field dep bash 4)" "ok"
# A missing curl must never fail the run on its own, which is the whole
# point of the tier: it costs one experimental segment.
clear_stubs
stub jq 'exit 0'
stub ccusage 'echo 20.0.20'
stub claude 'echo 2.1.267'
out=$(P bash "$DOC" --porcelain 2>/dev/null); rc=$?
eq "a missing curl is reported missing" "$(printf '%s\n' "$out" | field dep curl 4)" "missing"
eq "and does not fail the run" "$rc" "0"
clear_stubs

# --- Windows (Git Bash) ---------------------------------------------------
clear_stubs
stub uname 'case "$1" in -s) echo MINGW64_NT-10.0-22631 ;; -m) echo x86_64 ;; -r) echo 3.4.10 ;; *) echo MINGW64_NT-10.0-22631 ;; esac'
out=$(P bash "$DOC" --porcelain 2>/dev/null)
eq "Git Bash reports the windows kind" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "os" { print $2; exit }')" "windows"
case "$(printf '%s\n' "$out" | field dep jq 7)" in
  *winget*jqlang.jq*) ok "with no package manager it names the winget package" ;;
  *) bad "windows jq remedy" "$(printf '%s\n' "$out" | field dep jq 7)" ;;
esac
# scoop is preferred over winget: it needs no elevation.
stub scoop 'printf "Name: jq\r\nVersion: 1.8.2\r\n"'
stub winget 'printf "Version: 1.8.2\r\n"'
out=$(P bash "$DOC" --porcelain 2>/dev/null)
eq "scoop wins over winget" "$(printf '%s\n' "$out" | field dep jq 7)" "scoop install jq"
# The CRLF those native tools answer with must never reach the record.
plan=$(P bash "$INS" --plan --porcelain 2>/dev/null)
eq "the scoop version reaches the plan" "$(printf '%s\n' "$plan" | field plan jq 5)" "1.8.2"
case "$plan" in *$'\r'*) bad "CRLF" "a carriage return survived into the plan" ;; *) ok "no carriage return survives a native package manager" ;; esac

# --- macOS ---------------------------------------------------------------
clear_stubs
stub uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac'
stub sw_vers 'echo 15.1'
out=$(P bash "$DOC" --porcelain 2>/dev/null)
eq "Darwin reports the macos kind" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "os" { print $2; exit }')" "macos"
case "$(printf '%s\n' "$out" | field dep jq 7)" in
  *Homebrew*) ok "no brew means the remedy is prose, not a command" ;;
  *) bad "macos jq remedy" "$(printf '%s\n' "$out" | field dep jq 7)" ;;
esac
# Homebrew is never installed on the user's behalf, so that prose must be
# classified as something to report rather than something to run.
eq "and the installer refuses to act on it" "$(P bash "$INS" --plan --porcelain 2>/dev/null | field plan jq 3)" "skip"
stub brew '[ "$1" = info ] && { echo "==> jq: stable 1.8.2 (bottled)"; exit 0; }; exit 0'
eq "with brew present it plans a run" "$(P bash "$INS" --plan --porcelain 2>/dev/null | field plan jq 3)" "run"
eq "and reads the version from brew" "$(P bash "$INS" --plan --porcelain 2>/dev/null | field plan jq 5)" "1.8.2"

# --- claude is never an install ------------------------------------------
clear_stubs
eq "claude is reported, never planned" "$(P bash "$INS" --plan --porcelain 2>/dev/null | field plan claude 3)" "skip"

# --- sudo without a password ----------------------------------------------
clear_stubs
stub uname 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; -r) echo 6.0.0 ;; *) echo Linux ;; esac'
stub apt-get 'exit 0'
stub apt-cache 'echo "  Candidate: 1.7.1-3"'
stub sudo '[ "$1" = -n ] && [ "$2" = true ] && exit 1; exit 1'
mkdir -p "$W/osr"; printf 'ID=ubuntu\nVERSION_ID="24.04"\nID_LIKE=debian\n' > "$W/osr/os-release"
plan=$(P bash "$INS" --plan --porcelain 2>/dev/null)
eq "a sudo fix nobody can answer is skipped" "$(printf '%s\n' "$plan" | field plan jq 3)" "skip"
case "$(printf '%s\n' "$plan" | field plan jq 6)" in
  *"run it yourself"*) ok "and the skip hands back the command to run" ;;
  *) bad "sudo reason" "$(printf '%s\n' "$plan" | field plan jq 6)" ;;
esac
# Passwordless sudo turns the same gap into a run.
stub sudo '[ "$1" = -n ] && [ "$2" = true ] && exit 0; shift; "$@"'
eq "passwordless sudo plans a run" "$(P bash "$INS" --plan --porcelain 2>/dev/null | field plan jq 3)" "run"

# --- apply ---------------------------------------------------------------
clear_stubs
LOG="$W/npm.log"; MARK="$W/installed"; rm -f "$LOG" "$MARK"
stub uname 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac'
stub jq 'exit 0'
stub claude 'echo 2.1.267'
# The install is what puts ccusage on PATH, exactly as the real one does.
# It cannot be stubbed up front: the doctor decides with `command -v`, which
# finds a stub whatever its exit status, and would report ccusage present.
stub npm 'case "$1" in view) echo 20.0.20 ;; install) echo "$*" >> '"$LOG"'; : > '"$MARK"'; printf "#!/usr/bin/env bash\necho 20.0.20\n" > '"$W/stub/ccusage"'; chmod +x '"$W/stub/ccusage"' ;; esac; exit 0'
eq "a dry run installs nothing" "$(P bash "$INS" --apply ccusage --dry-run --porcelain 2>/dev/null | field result ccusage 3)" "dry-run"
eq "and left no trace" "$([ -f "$LOG" ] && echo ran || echo clean)" "clean"
out=$(P bash "$INS" --apply ccusage --porcelain 2>&1); rc=$?
eq "applying it runs the channel command" "$(cat "$LOG" 2>/dev/null)" "install -g ccusage"
eq "the result is read back from the doctor" "$(printf '%s\n' "$out" | field result ccusage 4)" "ok"
eq "and the run exits 0" "$rc" "0"
# A name that was not asked for is never touched.
rm -f "$LOG" "$MARK"
P bash "$INS" --apply jq >/dev/null 2>&1
eq "--apply only touches the names it is given" "$([ -f "$LOG" ] && echo ran || echo clean)" "clean"

# --- a failing install ----------------------------------------------------
rm -f "$LOG" "$MARK" "$W/stub/ccusage"
stub npm 'case "$1" in view) echo 20.0.20 ;; install) exit 243 ;; esac; exit 0'
out=$(P bash "$INS" --apply ccusage --porcelain 2>/dev/null); rc=$?
case "$(printf '%s\n' "$out" | field result ccusage 3)" in
  failed*) ok "a failing install is reported failed" ;;
  *) bad "failed install" "$(printf '%s\n' "$out" | field result ccusage 3)" ;;
esac
eq "and the run exits 1" "$rc" "1"

# --- usage errors ---------------------------------------------------------
bash "$INS" >/dev/null 2>&1; eq "no mode exits 2" "$?" "2"
bash "$INS" --apply >/dev/null 2>&1; eq "--apply with no name exits 2" "$?" "2"
bash "$INS" --plan --nonsense >/dev/null 2>&1; eq "an unknown option exits 2" "$?" "2"

printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
