#!/usr/bin/env bash
# Assert the running Cygwin tree matches doc/replica-definition.md. Run
# inside the replica's own bash. Exits non-zero and names every mismatch
# (not just the first) so a CI failure is diagnosable from one run.
set -u
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

PROG=${0##*/}
VERSION='verify-replica 1.0'

usage() {
	cat <<EOF
Verify the current Cygwin tree matches doc/replica-definition.md.

Usage:
  $PROG [options]

Options:
  -v, --verbose   print each check as it runs, not just failures
  -t, --terse     machine-friendly: one line per failure, nothing on success
  -h, --help      show this help and exit
      --version   show version and exit
EOF
}

err() { printf '%s: %s\n' "$PROG" "$*" >&2; }

VERBOSE=0 TERSE=0
while [ $# -gt 0 ]; do
	case $1 in
		-v|--verbose) VERBOSE=1; shift ;;
		-t|--terse)   TERSE=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		--version)    printf '%s\n' "$VERSION"; exit 0 ;;
		-*)           err "unknown option: $1 (try --help)"; exit 2 ;;
		*)            err "unexpected argument: $1 (try --help)"; exit 2 ;;
	esac
done

FAILED=0
CHECKED=0

extract() {
	# extract PATTERN <<< TEXT -- first regex match group via sed -E
	sed -E -n "s/.*($1).*/\1/p" | head -n1
}

check() {
	# check NAME ACTUAL EXPECTED
	name=$1 actual=$2 expected=$3
	CHECKED=$((CHECKED + 1))
	if [ "$actual" = "$expected" ]; then
		[ "$VERBOSE" = 1 ] && printf 'ok   %-20s %s\n' "$name" "$actual"
	else
		FAILED=$((FAILED + 1))
		printf 'FAIL %-20s got %s, want %s\n' "$name" "${actual:-<empty>}" "$expected"
	fi
}

skip() {
	[ "$TERSE" = 1 ] && return 0
	printf 'skip %-20s %s\n' "$1" "$2"
}

# Core tools, from doc/replica-definition.md. Mandatory: verify-replica is
# meaningless before the base install exists.
check uname   "$(uname -r | extract '3\.0\.7')"                         '3.0.7'
check bash    "$(bash --version | extract '4\.4\.12')"                  '4.4.12'
check python3 "$(python3 --version 2>&1 | extract '3\.6\.9')"           '3.6.9'
check perl    "$(perl -v 2>&1 | extract '5\.26\.3')"                    '5.26.3'
check git     "$(git --version | extract '2\.21\.0')"                   '2.21.0'
check tcsh    "$(tcsh --version 2>&1 | extract '6\.21\.00')"            '6.21.00'
check gcc     "$(gcc -dumpversion 2>&1)"                                '7.4.0'
check make    "$(make --version | extract '4\.2\.1')"                   '4.2.1'
check openssh "$(ssh -V 2>&1 | extract '8\.0p1')"                       '8.0p1'
check cygport "$(cygport --version 2>&1 | extract '0\.33\.1')"          '0.33.1'

# RHEL-parity packages: optional, since this script is meant to run at more
# than one pipeline stage. Skipped, not failed, if not installed yet.
if command -v postconf >/dev/null 2>&1; then
	check postfix "$(postconf mail_version 2>&1 | extract '3\.5\.8')" '3.5.8'
else
	skip postfix "not installed"
fi

if [ -x /usr/bin/mailx ]; then
	# heirloom mailx has no clean --version flag; its release string is
	# embedded in the binary. strings is a weaker check than postconf's
	# direct query, but it is what the binary offers.
	if command -v strings >/dev/null 2>&1 \
		&& strings /usr/bin/mailx 2>/dev/null | grep -q '12\.5'; then
		check heirloom-mailx '12.5' '12.5'
	else
		check heirloom-mailx 'not found in binary' '12.5'
	fi
else
	skip heirloom-mailx "not installed"
fi

if [ "$TERSE" != 1 ]; then
	printf '%d checked, %d failed\n' "$CHECKED" "$FAILED"
fi
[ "$FAILED" -eq 0 ]
