#!/usr/bin/env bash
# Install the RHEL 8.10 Cygwin replica with no administrator rights, from the
# 2019-08-01 Cygwin Time Machine snapshot. Same --no-admin mechanism the replica
# was built with; nothing here needs elevation. It installs no services or
# accounts on purpose (see postfix-user-setup.sh and install-logon-task.ps1).
#
# Run from any shell that can exec the Cygwin setup .exe (the machine's existing
# Cygwin bash, or cmd).
set -u

PROG=${0##*/}
VERSION='install-rhel810-noadmin 1.0'

DEF_ROOT='C:\cyg-rhel-8.10\cygwin64'
DEF_SETUP_DIR='C:\cyg-rhel-8.10\packages'
DEF_SNAPSHOT='http://ctm.crouchingtigerhiddenfruitbat.org/pub/cygwin/circa/64bit/2019/08/01/131636'
DEF_SETUP_URL='https://cygwin.com/setup-x86_64.exe'
DEF_PKGS='bash,coreutils,sed,gawk,grep,findutils,diffutils,patch,tar,gzip,bzip2,xz,which,less,procps-ng,util-linux,ncurses,zlib,rpm,gcc-core,gcc-g++,make,autoconf,automake,libtool,flex,bison,binutils,gdb,pkg-config,perl,python36,python3,openssh,openssl,curl,wget,rsync,git,vim,nano,tcsh,cygrunsrv,csih,cron,cygport,cpio,alternatives,editrights,getent,file,m4,texinfo,patchutils,libdb-devel,libpcre-devel,libpcre2-devel,libssl-devel,libsasl2-devel,libsqlite3-devel,libmysqlclient-devel,libpq-devel,libpq5,openldap-devel,libintl-devel,gettext-devel,zlib-devel,libiconv-devel'

usage() {
	cat <<EOF
Install the RHEL 8.10 Cygwin replica with no administrator rights.

Usage:
  $PROG [options]

Options:
  -R, --root DIR        Cygwin root directory [default: $DEF_ROOT]
  -l, --setup-dir DIR   setup-x86_64.exe and package-cache dir
                        [default: $DEF_SETUP_DIR]
  -e, --setup-exe PATH  path to setup-x86_64.exe [default: <setup-dir>\\setup-x86_64.exe]
      --setup-url URL   where to download setup if none is found [default: cygwin.com]
      --no-download     never download; fail if no setup is found locally
  -s, --snapshot URL    Cygwin Time Machine snapshot URL [default: 2019-08-01 snapshot]
  -P, --packages LIST   comma-separated package set
  -n, --dry-run         print the setup command; install nothing
  -v, --verbose         more detail (repeatable)
  -t, --terse           minimal output
  -d, --debug           debug/trace output (implies --verbose)
  -h, --help            show this help and exit
      --version         show version and exit

Each option can also be set by environment variable (the option wins):
REPLICA_ROOT, SETUP_DIR, SETUP_EXE, SETUP_URL, SNAPSHOT, PKGS, DRY_RUN, NO_DOWNLOAD.
EOF
}

err()       { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()       { err "$*"; exit 1; }          # runtime failure
die_usage() { err "$*"; exit 2; }          # bad invocation

win2posix() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

# Download url ($1) to a POSIX path ($2) with whatever fetcher is available.
download_to() {
	local url=$1 dest=$2 ps
	if command -v curl >/dev/null 2>&1; then
		curl -fLo "$dest" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$dest" "$url"
	else
		ps="$(cygpath -S 2>/dev/null)/WindowsPowerShell/v1.0/powershell.exe"
		"$ps" -NoProfile -Command "Invoke-WebRequest -Uri '$url' -OutFile '$(cygpath -w "$dest")'"
	fi
}

# Print the newest setup-x86_64.exe found in the usual download spots, or
# nothing. Lets the installer grab an already-downloaded setup instead of
# demanding one be pre-placed.
find_setup_exe() {
	local dirs=() home d f cands=() cache k
	home=$(win2posix "${USERPROFILE:-}")
	[ -n "$home" ] && dirs+=("$home/Downloads" "$home/Desktop" "$home")
	d=$(cygpath -D 2>/dev/null) && [ -n "$d" ] && dirs+=("$d")
	# The local package directory Cygwin setup used last (registry) usually
	# holds a setup-x86_64.exe. Check per-user, then system-wide.
	if command -v regtool >/dev/null 2>&1; then
		for k in /HKCU/Software/Cygwin/setup/last-cache \
			/HKLM/Software/Cygwin/setup/last-cache; do
			cache=$(regtool -q get "$k" 2>/dev/null)
			[ -n "$cache" ] && dirs+=("$(win2posix "$cache")")
		done
	fi
	dirs+=(".")
	for d in "${dirs[@]}"; do
		[ -d "$d" ] || continue
		for f in "$d"/setup-x86_64.exe; do
			[ -f "$f" ] && cands+=("$f")
		done
	done
	[ ${#cands[@]} -gt 0 ] || return 1
	ls -t "${cands[@]}" 2>/dev/null | head -1
}

# Environment values seed the defaults; command-line options override them.
ROOT=${REPLICA_ROOT:-$DEF_ROOT}
SETUP_DIR=${SETUP_DIR:-$DEF_SETUP_DIR}
SETUP_EXE=${SETUP_EXE:-}
SNAPSHOT=${SNAPSHOT:-$DEF_SNAPSHOT}
SETUP_URL=${SETUP_URL:-$DEF_SETUP_URL}
PKGS=${PKGS:-$DEF_PKGS}
DRY_RUN=${DRY_RUN:-0}
NO_DOWNLOAD=${NO_DOWNLOAD:-0}
VERBOSE=0 TERSE=0 DEBUG=0

while [ $# -gt 0 ]; do
	case $1 in
		--)               shift; break ;;
		-R|--root)        ROOT=${2?missing value for $1}; shift 2 ;;
		--root=*)         ROOT=${1#*=}; shift ;;
		-l|--setup-dir)   SETUP_DIR=${2?missing value for $1}; shift 2 ;;
		--setup-dir=*)    SETUP_DIR=${1#*=}; shift ;;
		-e|--setup-exe)   SETUP_EXE=${2?missing value for $1}; shift 2 ;;
		--setup-exe=*)    SETUP_EXE=${1#*=}; shift ;;
		--setup-url)      SETUP_URL=${2?missing value for $1}; shift 2 ;;
		--setup-url=*)    SETUP_URL=${1#*=}; shift ;;
		--no-download)    NO_DOWNLOAD=1; shift ;;
		-s|--snapshot)    SNAPSHOT=${2?missing value for $1}; shift 2 ;;
		--snapshot=*)     SNAPSHOT=${1#*=}; shift ;;
		-P|--packages)    PKGS=${2?missing value for $1}; shift 2 ;;
		--packages=*)     PKGS=${1#*=}; shift ;;
		-n|--dry-run)     DRY_RUN=1; shift ;;
		-v|--verbose)     VERBOSE=$((VERBOSE + 1)); shift ;;
		-t|--terse)       TERSE=1; shift ;;
		-d|--debug)       DEBUG=1; VERBOSE=$((VERBOSE + 1)); shift ;;
		-h|--help)        usage; exit 0 ;;
		--version)        printf '%s\n' "$VERSION"; exit 0 ;;
		-*)               die_usage "unknown option: $1 (try --help)" ;;
		*)                die_usage "unexpected argument: $1 (try --help)" ;;
	esac
done
[ $# -eq 0 ] || die_usage "unexpected argument: $1 (try --help)"

[ "$DEBUG" = 1 ] && set -x

# Resolve which setup-x86_64.exe to use. Order: an explicit --setup-exe/env
# value; else the one already in the setup dir; else the newest one found in the
# usual download spots, which gets copied into the setup dir. IMPORT_FROM holds a
# source path when we had to go find it.
IMPORT_FROM= DOWNLOAD=
if [ -z "$SETUP_EXE" ]; then
	intended="$SETUP_DIR\\setup-x86_64.exe"
	if [ -f "$(win2posix "$intended")" ]; then
		SETUP_EXE=$intended
	else
		IMPORT_FROM=$(find_setup_exe)
		SETUP_EXE=$intended
		[ -n "$IMPORT_FROM" ] || [ "$NO_DOWNLOAD" = 1 ] || DOWNLOAD=$SETUP_URL
	fi
fi
RUN_EXE=$(win2posix "$SETUP_EXE")

if [ "$TERSE" != 1 ]; then
	printf 'setup exe : %s\n' "$SETUP_EXE"
	[ -n "$IMPORT_FROM" ] && printf 'import    : %s\n' "$IMPORT_FROM"
	[ -n "$DOWNLOAD" ] && printf 'download  : %s\n' "$DOWNLOAD"
	printf 'root      : %s\n' "$ROOT"
	printf 'snapshot  : %s\n' "$SNAPSHOT"
	printf 'packages  : %s requested\n' "$(printf '%s' "$PKGS" | tr ',' ' ' | wc -w)"
fi

setup_args=(-q -X -n -d -N --no-admin
	-R "$ROOT" -s "$SNAPSHOT" -l "$SETUP_DIR" -P "$PKGS")

if [ "$DRY_RUN" = 1 ]; then
	[ -n "$IMPORT_FROM" ] && err "would copy newest setup: $IMPORT_FROM -> $SETUP_DIR"
	[ -n "$DOWNLOAD" ] && err "would download setup: $DOWNLOAD -> $SETUP_DIR"
	printf 'DRY RUN, would run:\n  %s' "$SETUP_EXE"
	printf ' %s' "${setup_args[@]}"
	printf '\n'
	exit 0
fi

# Get a setup exe into the setup dir: copy the discovered one, or download it.
if [ -n "$IMPORT_FROM" ] || [ -n "$DOWNLOAD" ]; then
	dest=$(win2posix "$SETUP_DIR")
	mkdir -p "$dest"
	if [ -n "$IMPORT_FROM" ]; then
		cp -f "$IMPORT_FROM" "$dest/setup-x86_64.exe" || die "could not copy setup into $SETUP_DIR"
		[ "$TERSE" = 1 ] || err "imported newest setup: $IMPORT_FROM"
	else
		[ "$TERSE" = 1 ] || err "downloading setup from $DOWNLOAD"
		download_to "$DOWNLOAD" "$dest/setup-x86_64.exe" || die "download failed: $DOWNLOAD"
	fi
fi

# Fail loudly if the setup program is still missing, instead of claiming success.
[ -f "$RUN_EXE" ] || die "setup program not found: $SETUP_EXE
  download setup-x86_64.exe into $SETUP_DIR, or point --setup-exe at it"

[ "$VERBOSE" -ge 1 ] && err "exec: $RUN_EXE ${setup_args[*]}"

# -X is required (the archived setup.ini is unsigned).
if "$RUN_EXE" "${setup_args[@]}"; then
	[ "$TERSE" = 1 ] || printf 'setup finished; log: %s\\var\\log\\setup.log.full\n' "$ROOT"
else
	die "setup exited non-zero ($?); see $ROOT\\var\\log\\setup.log.full"
fi
