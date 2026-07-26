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

# Why did master fail to come up? master owns the inet listener sockets and
# routes its own fatals through postlogd, which is not up yet at startup, so an
# early bind failure never reaches maillog. The port probe is what actually
# exposes "address already in use" (the usual cause, e.g. another postfix on 25);
# Windows netstat -ano names the process holding it.
diag_start() {
	local svc port winnet
	winnet="$(cygpath -S 2>/dev/null)/netstat.exe"
	{
		echo "---- postfix start diagnostics ----"
		echo "config     : $CONFIG_DIR"
		echo "user       : $(id -un) ($(id -u):$(id -g))"
		echo "queue dir  : $(ls -ld "$(queue_dir)" 2>&1)"
		echo "maillog    : $log"
		echo "-- key settings --"
		postconf -c "$CONFIG_DIR" -h inet_interfaces inet_protocols mynetworks mail_owner 2>&1
		echo "-- smtpd inet services --"
		postconf -c "$CONFIG_DIR" -M 2>/dev/null | awk '$2=="inet"{print}'
		for svc in $(postconf -c "$CONFIG_DIR" -M 2>/dev/null | awk '$2=="inet"{print $1}'); do
			port=${svc##*:}
			# A named service (stock "smtp inet") maps to its well-known port.
			case $port in *[!0-9]*|'')
				port=$(python3 -c "import socket,sys; print(socket.getservbyname(sys.argv[1]))" "$port" 2>/dev/null) ;;
			esac
			case $port in *[!0-9]*|'') continue ;; esac
			echo "-- port $port (from $svc) --"
			python3 -c "import socket
s=socket.socket()
try:
 s.bind(('127.0.0.1',$port)); print(' bindable: yes (nothing is holding it)')
except OSError as e: print(' bindable: NO -', e)
finally: s.close()" 2>&1
			[ -f "$winnet" ] && "$winnet" -ano 2>/dev/null | grep -E "[:.]$port " | head -5
		done
		echo "-- last maillog lines --"
		tail -15 "$log" 2>&1
		echo "-----------------------------------"
	} >&2
}

case $ACTION in
start)
	if is_running; then say "postfix already running ($CONFIG_DIR, pid $(master_pid))"; exit 0; fi
	log=$(postconf -c "$CONFIG_DIR" -h maillog_file 2>/dev/null)
	[ -n "$log" ] || log=/var/log/maillog
	mkdir -p "$(dirname "$log")"
	[ "$VERBOSE" -ge 1 ] && err "exec: $MASTER -c $CONFIG_DIR -d  (log: $log)"
	# Fully detach master from the caller. setsid puts it in its own session with
	# no controlling terminal; the redirects give it maillog/dev-null for all three
	# std streams. Without the new session, an install run captured under `script`
	# (or any pty) keeps that pty open through master and never sees EOF, so the
	# whole run hangs long after the MTA is already up. The std fds alone were
	# already clean here; the session was the missing piece.
	setsid "$MASTER" -c "$CONFIG_DIR" -d >>"$log" 2>&1 </dev/null &
	sleep 2
	if is_running; then
		say "postfix started ($CONFIG_DIR, pid $(master_pid))"
	else
		err "failed to start; maillog is often empty here (see below for why)"
		diag_start
		exit 1
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
