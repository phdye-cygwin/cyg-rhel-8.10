#!/usr/bin/env bash
# Start, stop, or check the unprivileged Postfix master with no service manager.
# A per-user logon Scheduled Task calls "start"; you can also run it by hand.
# master runs with -d (foreground) under nohup so this launcher owns the pid; a
# bare 3.x master would self-detach and we would lose track.
set -u
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

PROG=${0##*/}
VERSION='postfix-user-launch 1.0'
MASTER=/usr/libexec/postfix/master

usage() {
	cat <<EOF
Start, stop, or check the unprivileged Postfix master.

Usage:
  $PROG [options] (start | stop | status)

Options:
  -c, --config-dir DIR  Postfix config directory [default: /etc/postfix]
  -v, --verbose         more detail
  -t, --terse           minimal output
  -d, --debug           debug/trace output (implies --verbose)
  -h, --help            show this help and exit
      --version         show version and exit

Environment (option wins): PF_CONFIG_DIR.
EOF
}

err()       { printf '%s: %s\n' "$PROG" "$*" >&2; }
die_usage() { err "$*"; exit 2; }

CONFIG_DIR=${PF_CONFIG_DIR:-/etc/postfix}
VERBOSE=0 TERSE=0 DEBUG=0
ACTION=

while [ $# -gt 0 ]; do
	case $1 in
		--)                shift; break ;;
		-c|--config-dir)   CONFIG_DIR=${2?missing value for $1}; shift 2 ;;
		--config-dir=*)    CONFIG_DIR=${1#*=}; shift ;;
		-v|--verbose)      VERBOSE=$((VERBOSE + 1)); shift ;;
		-t|--terse)        TERSE=1; shift ;;
		-d|--debug)        DEBUG=1; VERBOSE=$((VERBOSE + 1)); shift ;;
		-h|--help)         usage; exit 0 ;;
		--version)         printf '%s\n' "$VERSION"; exit 0 ;;
		start|stop|status) [ -z "$ACTION" ] || die_usage "one command only"; ACTION=$1; shift ;;
		-*)                die_usage "unknown option: $1 (try --help)" ;;
		*)                 die_usage "unknown command: $1 (try --help)" ;;
	esac
done
[ -n "$ACTION" ] || die_usage "need a command: start, stop, or status"
[ "$DEBUG" = 1 ] && set -x

say() { [ "$TERSE" = 1 ] || printf '%s\n' "$*"; }
queue_dir()  { postconf -c "$CONFIG_DIR" -h queue_directory 2>/dev/null; }
master_pid() { head -1 "$(queue_dir)/pid/master.pid" 2>/dev/null | tr -dc '0-9'; }
is_running() { local pid; pid=$(master_pid); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

case $ACTION in
start)
	if is_running; then say "postfix already running ($CONFIG_DIR, pid $(master_pid))"; exit 0; fi
	log=$(postconf -c "$CONFIG_DIR" -h maillog_file 2>/dev/null)
	[ -n "$log" ] || log=/var/log/maillog
	mkdir -p "$(dirname "$log")"
	[ "$VERBOSE" -ge 1 ] && err "exec: $MASTER -c $CONFIG_DIR -d  (log: $log)"
	nohup "$MASTER" -c "$CONFIG_DIR" -d >>"$log" 2>&1 &
	sleep 2
	if is_running; then
		say "postfix started ($CONFIG_DIR, pid $(master_pid))"
	else
		err "failed to start; see $log"; exit 1
	fi
	;;
stop)
	pid=$(master_pid)
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || true
		say "postfix stopped (pid $pid)"
	else
		say "postfix not running"
	fi
	;;
status)
	if is_running; then say "running (pid $(master_pid))"; exit 0; else say "stopped"; exit 1; fi
	;;
esac
