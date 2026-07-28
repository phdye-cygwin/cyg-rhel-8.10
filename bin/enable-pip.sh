#!/usr/bin/env bash
# Bootstrap pip for Python 3 via ensurepip. The replica's python36 snapshot
# ships ensurepip but does not pre-install pip, so this fills the gap.
# Run inside the replica tree.
set -eu
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

PROG=${0##*/}
VERSION='enable-pip 1.0'

usage() {
	cat <<EOF
Bootstrap pip for Python 3 in the current Cygwin tree.

Usage:
  $PROG [options]

Options:
  -n, --dry-run   show what would run; change nothing
  -v, --verbose   more detail
  -t, --terse     minimal output
  -d, --debug     debug/trace output (implies --verbose)
  -h, --help      show this help and exit
      --version   show version and exit
EOF
}

err()       { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()       { err "$*"; exit 1; }
die_usage() { err "$*"; exit 2; }

DRY_RUN=0 VERBOSE=0 TERSE=0 DEBUG=0
while [ $# -gt 0 ]; do
	case $1 in
		--)           shift; break ;;
		-n|--dry-run) DRY_RUN=1; shift ;;
		-v|--verbose) VERBOSE=$((VERBOSE + 1)); shift ;;
		-t|--terse)   TERSE=1; shift ;;
		-d|--debug)   DEBUG=1; VERBOSE=$((VERBOSE + 1)); shift ;;
		-h|--help)    usage; exit 0 ;;
		--version)    printf '%s\n' "$VERSION"; exit 0 ;;
		-*)           die_usage "unknown option: $1 (try --help)" ;;
		*)            die_usage "unexpected argument: $1 (try --help)" ;;
	esac
done
if [ "$DEBUG" = 1 ]; then set -x; fi
say() { [ "$TERSE" = 1 ] || printf '%s\n' "$*"; }

# -- preflight ---------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

if python3 -m pip --version >/dev/null 2>&1; then
	pip_ver=$(python3 -m pip --version)
	say "pip already installed: $pip_ver"
	exit 0
fi

python3 -c 'import ensurepip' 2>/dev/null \
	|| die "ensurepip module missing -- install the python36 package first"

# -- bootstrap ----------------------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
	say "would run: python3 -m ensurepip --upgrade"
	exit 0
fi

say "== bootstrapping pip via ensurepip =="
python3 -m ensurepip --upgrade

pip_ver=$(python3 -m pip --version) \
	|| die "ensurepip ran but pip is still not loadable"

if [ "$VERBOSE" -ge 1 ]; then
	say "  $pip_ver"
fi

say "enable-pip: done."
