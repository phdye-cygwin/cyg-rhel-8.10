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

DEF_BASE='C:\cyg-rhel-8.10'
DEF_SNAPSHOT='http://ctm.crouchingtigerhiddenfruitbat.org/pub/cygwin/circa/64bit/2019/08/01/131636'
DEF_SETUP_URL='https://cygwin.com/setup-x86_64.exe'
DEF_PKGS='bash,coreutils,sed,gawk,grep,findutils,diffutils,patch,tar,gzip,bzip2,xz,which,less,procps-ng,util-linux,ncurses,zlib,rpm,gcc-core,gcc-g++,make,autoconf,automake,libtool,flex,bison,binutils,gdb,pkg-config,perl,python36,python3,openssh,openssl,curl,wget,rsync,git,vim,nano,tcsh,cygrunsrv,csih,cron,cygport,cpio,alternatives,editrights,getent,file,m4,texinfo,patchutils,libdb-devel,libpcre-devel,libpcre2-devel,libssl-devel,libsasl2-devel,libsqlite3-devel,libmysqlclient-devel,libpq-devel,libpq5,openldap-devel,libintl-devel,gettext-devel,zlib-devel,libiconv-devel'

usage() {
	cat <<EOF
Install the RHEL 8.10 Cygwin replica with no administrator rights.

Usage:
  $PROG [options]

Options:
  -b, --base DIR        base directory; root and pkg-dir sit under it
                        [default: $DEF_BASE]
  -R, --root DIR        Cygwin root directory [default: <base>\\cygwin64]
  -l, --pkg-dir DIR     setup-x86_64.exe and package-cache dir (alias --setup-dir)
                        [default: <base>\\packages]
  -e, --setup-exe PATH  path to setup-x86_64.exe [default: <pkg-dir>\\setup-x86_64.exe]
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
REPLICA_BASE, REPLICA_ROOT, PKG_DIR, SETUP_EXE, SETUP_URL, SNAPSHOT, PKGS,
DRY_RUN, NO_DOWNLOAD.
EOF
}

err()       { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()       { err "$*"; diag; exit 1; }    # runtime failure, with diagnostics
die_usage() { err "$*"; exit 2; }          # bad invocation (no diag; it is user error)

win2posix() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

pshell() { printf '%s' "$(cygpath -S 2>/dev/null)/WindowsPowerShell/v1.0/powershell.exe"; }

# Dump the environment facts that make a failure diagnosable straight from the
# log, so a failed run can be reported without a second round of questions.
diag() {
	{
		echo "---- diagnostics ($PROG) ----"
		echo "date       : $(date 2>/dev/null)"
		echo "uname      : $(uname -a 2>/dev/null)"
		echo "shell/pwd  : $0  |  $(pwd 2>/dev/null)"
		echo "base       : ${BASE:-<unset>}"
		echo "root       : ${ROOT:-<unset>}"
		echo "pkg-dir    : ${SETUP_DIR:-<unset>}"
		echo "setup exe  : ${SETUP_EXE:-<unset>}"
		echo "snapshot   : ${SNAPSHOT:-<unset>}"
		echo "curl       : $(command -v curl 2>/dev/null || echo absent)  [$(curl --version 2>/dev/null | head -1)]"
		echo "wget       : $(command -v wget 2>/dev/null || echo absent)"
		echo "powershell : $(pshell)  [$( [ -f "$(pshell)" ] && echo present || echo MISSING )]"
		echo "ca-bundle  : $(ls -l /usr/ssl/certs/ca-bundle.crt 2>&1)"
		echo "pkg-dir    : $(ls -ld "$(win2posix "${SETUP_DIR:-/}" 2>/dev/null)" 2>&1)"
		echo "disk free  : $(df -h "$(win2posix "${BASE:-/}" 2>/dev/null)" 2>&1 | tail -1)"
		echo "-----------------------------"
	} >&2
}

# True if any way to download is available. Used both as a preflight gate and to
# decide whether a download attempt is even worth making.
have_fetcher() {
	command -v curl >/dev/null 2>&1 && return 0
	command -v wget >/dev/null 2>&1 && return 0
	[ -f "$(pshell)" ] && return 0
	return 1
}

# Confirm a Windows dir ($1) can be created and written before we rely on it.
check_writable() {
	local win=$1 p
	p=$(win2posix "$win")
	mkdir -p "$p" 2>/dev/null || return 1
	( : > "$p/.wtest.$$" ) 2>/dev/null || return 1
	rm -f "$p/.wtest.$$" 2>/dev/null
	return 0
}

# Download url ($1) to a POSIX path ($2). Tries every fetcher in turn: a
# present-but-broken one (e.g. Cygwin curl with no CA bundle) must not abort the
# download when wget or PowerShell would succeed. PowerShell uses the Windows
# cert store, so it is the reliable last resort. Each attempt is logged.
download_to() {
	local url=$1 dest=$2 ps
	if command -v curl >/dev/null 2>&1; then
		err "download: trying curl"
		curl -fL --retry 2 -o "$dest" "$url" && return 0
		err "download: curl failed (exit $?); trying next method"
	fi
	if command -v wget >/dev/null 2>&1; then
		err "download: trying wget"
		wget -O "$dest" "$url" && return 0
		err "download: wget failed (exit $?); trying next method"
	fi
	ps=$(pshell)
	if [ -f "$ps" ]; then
		err "download: trying PowerShell Invoke-WebRequest"
		"$ps" -NoProfile -Command "\$ErrorActionPreference='Stop'; Invoke-WebRequest -Uri '$url' -OutFile '$(cygpath -w "$dest")' -UseBasicParsing" && return 0
		err "download: PowerShell failed (exit $?)"
	fi
	err "download: no fetcher succeeded (curl/wget/PowerShell)"
	return 1
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
# --root and --pkg-dir stay empty until after parsing, then fall back to the
# base directory, so an explicit --base drives both without repeating yourself.
BASE=${REPLICA_BASE:-$DEF_BASE}
ROOT=${REPLICA_ROOT:-}
SETUP_DIR=${PKG_DIR:-}
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
		-b|--base)        BASE=${2?missing value for $1}; shift 2 ;;
		--base=*)         BASE=${1#*=}; shift ;;
		-R|--root)        ROOT=${2?missing value for $1}; shift 2 ;;
		--root=*)         ROOT=${1#*=}; shift ;;
		-l|--pkg-dir|--setup-dir) SETUP_DIR=${2?missing value for $1}; shift 2 ;;
		--pkg-dir=*|--setup-dir=*) SETUP_DIR=${1#*=}; shift ;;
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

# Fill root and pkg-dir from the base directory unless they were set outright.
[ -n "$ROOT" ]      || ROOT="$BASE\\cygwin64"
[ -n "$SETUP_DIR" ] || SETUP_DIR="$BASE\\packages"

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

# -O (--only-site) pins setup to the snapshot site and skips the mirror list;
# without it, older setup can fall back to an empty mirror list and select zero
# packages even when the snapshot is reachable.
setup_args=(-q -X -O -n -d -N --no-admin
	-R "$ROOT" -s "$SNAPSHOT" -l "$SETUP_DIR" -P "$PKGS")

if [ "$DRY_RUN" = 1 ]; then
	[ -n "$IMPORT_FROM" ] && err "would copy newest setup: $IMPORT_FROM -> $SETUP_DIR"
	[ -n "$DOWNLOAD" ] && err "would download setup: $DOWNLOAD -> $SETUP_DIR"
	printf 'DRY RUN, would run:\n  %s' "$SETUP_EXE"
	printf ' %s' "${setup_args[@]}"
	printf '\n'
	exit 0
fi

# Preflight: catch the cheap, common failures before the multi-minute setup run,
# so a bad target or a missing downloader is reported up front, not midway.
check_writable "$SETUP_DIR" \
	|| die "package dir is not writable: $SETUP_DIR
  pick another --pkg-dir or --base, or check permissions"
check_writable "$(dirname "$(win2posix "$ROOT")")" \
	|| die "the root's parent is not writable, so setup cannot create $ROOT
  pick another --root or --base"
if [ -n "$DOWNLOAD" ] && ! have_fetcher; then
	die "setup must be downloaded but no fetcher is available (curl, wget, or PowerShell)
  pre-place setup-x86_64.exe in $SETUP_DIR, pass --setup-exe, or use --no-download"
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

# Whatever we obtained must be a real Windows program. A proxy error page or a
# truncated download would later exec as "Bad address" or "cannot execute", so
# catch it here with a clear message instead.
setup_sz=$(wc -c < "$RUN_EXE" 2>/dev/null || echo 0)
setup_hdr=$(head -c2 "$RUN_EXE" 2>/dev/null)
if [ "$setup_hdr" != MZ ] || [ "${setup_sz:-0}" -lt 100000 ]; then
	err "setup-x86_64.exe is not a valid Windows program (size=$setup_sz bytes, header='$setup_hdr')"
	die "bad setup at $SETUP_EXE, likely a proxy page or partial download; point --setup-exe at a known-good copy"
fi

# Strip the mark-of-the-web on a downloaded exe; some policies refuse to launch a
# tagged file. Harmless when absent or when PowerShell is unavailable.
ps=$(pshell)
[ -f "$ps" ] && "$ps" -NoProfile -Command "Unblock-File -LiteralPath '$(cygpath -w "$RUN_EXE")' -ErrorAction SilentlyContinue" 2>/dev/null

[ "$VERBOSE" -ge 1 ] && err "exec: $RUN_EXE ${setup_args[*]}"

# -X is required (the archived setup.ini is unsigned). setup blocks until it is
# done, so afterward the new tree's bash must exist. A zero exit with no tree
# (e.g. an exec that faulted with "Bad address" on a locked-down box) is NOT
# success -- report it, with everything needed to see why.
rc=0
"$RUN_EXE" "${setup_args[@]}" || rc=$?
root_bash=$(win2posix "$ROOT")/bin/bash.exe
if [ "$rc" = 0 ] && [ -f "$root_bash" ]; then
	[ "$TERSE" = 1 ] || printf 'setup finished; log: %s\\var\\log\\setup.log.full\n' "$ROOT"
else
	err "setup did not produce a working tree (exit $rc; $ROOT\\bin\\bash.exe $([ -f "$root_bash" ] && echo present || echo MISSING))"
	setup_log=$(win2posix "$ROOT")/var/log/setup.log.full
	if [ -f "$setup_log" ]; then
		err "-- tail of setup.log.full --"; tail -20 "$setup_log" >&2
	else
		err "-- no setup.log.full: setup never got far enough to write one --"
	fi
	if [ "$rc" = 0 ]; then
		err "exit 0 with no tree usually means the .exe could not run: security software"
		err "blocking a freshly downloaded setup, or this Cygwin too old for a current setup."
		err "try --setup-exe pointing at the setup-x86_64.exe already installed on this machine."
	fi
	die "setup failed; see the diagnostics above and $ROOT\\var\\log\\setup.log.full"
fi
