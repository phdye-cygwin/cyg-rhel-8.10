#!/usr/bin/env bash
# One-shot harness: install the RHEL 8.10 Cygwin replica tree, then install and
# start the Postfix + mailx MTA inside it. Run from your existing Cygwin shell;
# no administrator rights.
#
# The MTA steps must run under the NEW tree's bash, and a replica binary cannot
# be launched directly from another Cygwin shell -- the two cygwin1.dll
# instances deadlock. So phase 2 crosses into the new tree through cmd.exe, a
# native bridge, which sidesteps the collision.
set -u

PROG=${0##*/}
VERSION='install-all 1.0'
HERE=$(cd "$(dirname "$0")" && pwd)
DEF_BASE='C:\cyg-rhel-8.10'

usage() {
	cat <<EOF
Install the replica tree and bring up the MTA in one shot.

Usage:
  $PROG [options]

Options:
  -b, --base DIR        base directory; root and pkg-dir sit under it
                        [default: $DEF_BASE]
  -R, --root DIR        Cygwin root, a Windows path [default: <base>\\cygwin64]
  -l, --pkg-dir DIR     setup-x86_64.exe and package cache (alias --setup-dir)
                        [default: <base>\\packages]
  -e, --setup-exe PATH  setup-x86_64.exe to use (else auto-located)
      --setup-url URL   where to download setup if none is found
      --no-download     never download setup; fail if none is found locally
  -s, --snapshot URL    snapshot URL, passed to the installer
  -P, --packages LIST   package set, passed to the installer
      --no-start        configure Postfix but do not start it
      --shortcut        also create the mintty terminal shortcut
      --logon-task      also register the per-user logon task
  -n, --dry-run         print the plan and the generated runner; change nothing
  -v, --verbose         more detail
  -t, --terse           minimal output
  -d, --debug           debug/trace output (implies --verbose)
  -h, --help            show this help and exit
      --version         show version and exit
EOF
}

err()       { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()       { err "$*"; exit 1; }
die_usage() { err "$*"; exit 2; }
say()       { [ "$TERSE" = 1 ] || printf '%s\n' "$*"; }

BASE= ROOT= SETUP_DIR= SETUP_EXE= SETUP_URL= SNAPSHOT= PKGS=
NO_DOWNLOAD=0 NO_START=0 WANT_SHORTCUT=0 WANT_LOGON=0
DRY_RUN=0 VERBOSE=0 TERSE=0 DEBUG=0

while [ $# -gt 0 ]; do
	case $1 in
		--)              shift; break ;;
		-b|--base)       BASE=${2?missing value for $1}; shift 2 ;;
		--base=*)        BASE=${1#*=}; shift ;;
		-R|--root)       ROOT=${2?missing value for $1}; shift 2 ;;
		--root=*)        ROOT=${1#*=}; shift ;;
		-l|--pkg-dir|--setup-dir) SETUP_DIR=${2?missing value for $1}; shift 2 ;;
		--pkg-dir=*|--setup-dir=*) SETUP_DIR=${1#*=}; shift ;;
		-e|--setup-exe)  SETUP_EXE=${2?missing value for $1}; shift 2 ;;
		--setup-exe=*)   SETUP_EXE=${1#*=}; shift ;;
		--setup-url)     SETUP_URL=${2?missing value for $1}; shift 2 ;;
		--setup-url=*)   SETUP_URL=${1#*=}; shift ;;
		--no-download)   NO_DOWNLOAD=1; shift ;;
		-s|--snapshot)   SNAPSHOT=${2?missing value for $1}; shift 2 ;;
		--snapshot=*)    SNAPSHOT=${1#*=}; shift ;;
		-P|--packages)   PKGS=${2?missing value for $1}; shift 2 ;;
		--packages=*)    PKGS=${1#*=}; shift ;;
		--no-start)      NO_START=1; shift ;;
		--shortcut)      WANT_SHORTCUT=1; shift ;;
		--logon-task)    WANT_LOGON=1; shift ;;
		-n|--dry-run)    DRY_RUN=1; shift ;;
		-v|--verbose)    VERBOSE=$((VERBOSE + 1)); shift ;;
		-t|--terse)      TERSE=1; shift ;;
		-d|--debug)      DEBUG=1; VERBOSE=$((VERBOSE + 1)); shift ;;
		-h|--help)       usage; exit 0 ;;
		--version)       printf '%s\n' "$VERSION"; exit 0 ;;
		-*)              die_usage "unknown option: $1 (try --help)" ;;
		*)               die_usage "unexpected argument: $1 (try --help)" ;;
	esac
done
[ $# -eq 0 ] || die_usage "unexpected argument: $1 (try --help)"
[ "$DEBUG" = 1 ] && set -x

command -v cygpath >/dev/null 2>&1 || die "cygpath not found; run this from a Cygwin shell"

CMD="$(cygpath -S)/cmd.exe"
PS="$(cygpath -S)/WindowsPowerShell/v1.0/powershell.exe"
REPO_WIN=$(cygpath -w "$HERE")

# Resolve base first, then root and pkg-dir under it, so relocating the whole
# install is one --base. An explicit --root without --base takes its base from
# the root's parent; otherwise the default base wins. Explicit --pkg-dir and
# --root always override.
if [ -z "$BASE" ]; then
	if [ -n "$ROOT" ]; then
		BASE=$(cygpath -w "$(dirname "$(cygpath -u "$ROOT")")")
	else
		BASE=$DEF_BASE
	fi
fi
[ -n "$ROOT" ]      || ROOT="$BASE\\cygwin64"
[ -n "$SETUP_DIR" ] || SETUP_DIR="$BASE\\packages"
BASE_WIN=$(cygpath -w "$BASE")
ROOT_POSIX=$(cygpath -u "$ROOT")
NEWBASH_WIN="$ROOT\\bin\\bash.exe"
RUNNER_WIN="$ROOT\\tmp\\install-all-mta.sh"

vflag=
[ "$VERBOSE" -ge 1 ] && vflag=--verbose
[ "$TERSE" = 1 ] && vflag=--terse

# The phase-2 runner, executed by the NEW tree's bash. REPO is baked in as a
# Windows path and converted with the new tree's own cygpath.
build_runner() {
	echo '#!/bin/bash'
	echo 'set -e'
	echo 'export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin'
	printf "REPO=\$(cygpath -u '%s')\n" "$REPO_WIN"
	printf '"$REPO/bin/install-packages.sh" %s\n' "$vflag"
	printf '"$REPO/bin/postfix-user-setup.sh" %s\n' "$vflag"
	[ "$NO_START" = 1 ] || printf '"$REPO/bin/postfix-user-launch.sh" start %s\n' "$vflag"
	echo 'echo "install-all: MTA phase done"'
}

# Pass-through args for the tree installer.
inst=(--root "$ROOT" --pkg-dir "$SETUP_DIR")
[ -n "$SETUP_EXE" ]   && inst+=(--setup-exe "$SETUP_EXE")
[ -n "$SETUP_URL" ]   && inst+=(--setup-url "$SETUP_URL")
[ "$NO_DOWNLOAD" = 1 ] && inst+=(--no-download)
[ -n "$SNAPSHOT" ]    && inst+=(--snapshot "$SNAPSHOT")
[ -n "$PKGS" ]        && inst+=(--packages "$PKGS")
[ "$DRY_RUN" = 1 ]    && inst+=(--dry-run)
[ -n "$vflag" ]       && inst+=("$vflag")

if [ "$DRY_RUN" = 1 ]; then
	say "== phase 1: install the tree =="
	"$HERE/install-rhel810-noadmin.sh" "${inst[@]}"
	say ""
	say "== phase 2: run inside $ROOT via cmd bridge =="
	say "cmd /c \"$NEWBASH_WIN $RUNNER_WIN\"  where the runner is:"
	build_runner | sed 's/^/    /'
	[ "$WANT_SHORTCUT" = 1 ] && say "then: install-mintty-shortcut.ps1 -Base $BASE_WIN"
	[ "$WANT_LOGON" = 1 ]    && say "then: install-logon-task.ps1"
	exit 0
fi

say "== phase 1: install the Cygwin tree =="
"$HERE/install-rhel810-noadmin.sh" "${inst[@]}" || die "tree install failed"

[ -f "$(cygpath -u "$NEWBASH_WIN")" ] || die "new tree bash missing: $NEWBASH_WIN (did the install finish?)"

mkdir -p "$ROOT_POSIX/tmp"
build_runner > "$ROOT_POSIX/tmp/install-all-mta.sh"

say "== phase 2: install and start the MTA inside the new tree (cmd bridge) =="
"$CMD" /c "$NEWBASH_WIN $RUNNER_WIN" || die "MTA phase failed inside the new tree"

if [ "$WANT_SHORTCUT" = 1 ]; then
	say "== mintty shortcut =="
	"$PS" -NoProfile -ExecutionPolicy Bypass -File "$REPO_WIN\\bin\\install-mintty-shortcut.ps1" -Base "$BASE_WIN" || err "shortcut step failed"
fi
if [ "$WANT_LOGON" = 1 ]; then
	say "== logon task =="
	"$PS" -NoProfile -ExecutionPolicy Bypass -File "$REPO_WIN\\bin\\install-logon-task.ps1" || err "logon-task step failed"
fi

say "install-all: done. Replica at $ROOT"
