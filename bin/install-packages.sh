#!/usr/bin/env bash
# Install the built Postfix 3.5.8 and Heirloom mailx packages into the current
# Cygwin tree by unpacking the .tar.xz archives, then seed /etc/postfix from the
# packaged defaults. Run inside the replica -- its / is the tree root. No admin,
# no service registration; that is postfix-user-setup.sh's job.
set -eu
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

PROG=${0##*/}
VERSION='install-packages 1.0'

usage() {
	cat <<EOF
Install the built Postfix and Heirloom mailx packages into the current tree.

Usage:
  $PROG [options]

Options:
  -n, --dry-run   list the archives that would be unpacked; change nothing
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

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PKG=$REPO/packages

archives="
$PKG/postfix/postfix-3.5.8-1.tar.xz
$PKG/postfix/postfix-doc-3.5.8-1.tar.xz
$PKG/postfix/postfix-tools-3.5.8-1.tar.xz
$PKG/heirloom-mailx/heirloom-mailx-12.5-1.tar.xz
"

if [ "$DRY_RUN" = 1 ]; then
	say "would unpack into / :"
	for f in $archives; do printf '  %s\n' "$f"; done
	exit 0
fi

say "== unpack packages into / =="
for f in $archives; do
	[ -f "$f" ] || die "missing package: $f"
	say "  $f"
	tar -C / -xJf "$f"
done

say "== seed /etc/postfix from packaged defaults =="
if [ -d /etc/defaults/etc/postfix ]; then
	mkdir -p /etc/postfix
	cp -rn /etc/defaults/etc/postfix/. /etc/postfix/
fi

# Until the shim is installed, point sendmail at the postfix binary so mailx has
# a target. postfix-user-setup.sh replaces this with the SMTP shim.
[ -e /usr/sbin/sendmail ] || ln -sf sendmail.postfix.exe /usr/sbin/sendmail

say "install-packages: done. Next: bin/postfix-user-setup.sh"
