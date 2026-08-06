#!/usr/bin/env bash
# Start, stop, restart, or check the unprivileged Postfix master with no service
# manager. A per-user logon Scheduled Task calls "start"; you can also run it by
# hand. master runs with -d (foreground) in its own session via setsid, and
# master.pid records the running pid. stop reaps the whole instance: the tracked
# master, any orphaned daemons, and the stale pid/lock files.
set -u
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

PROG=${0##*/}
VERSION='postfix-user-launch 1.0'
MASTER=/usr/libexec/postfix/master

usage() {
	cat <<EOF
Start, stop, or check the unprivileged Postfix master.

Usage:
  $PROG [options] (start | stop | restart | status)

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
		start|stop|restart|status) [ -z "$ACTION" ] || die_usage "one command only"; ACTION=$1; shift ;;
		-*)                die_usage "unknown option: $1 (try --help)" ;;
		*)                 die_usage "unknown command: $1 (try --help)" ;;
	esac
done
[ -n "$ACTION" ] || die_usage "need a command: start, stop, restart, or status"
[ "$DEBUG" = 1 ] && set -x

say() { [ "$TERSE" = 1 ] || printf '%s\n' "$*"; }
queue_dir()  { postconf -c "$CONFIG_DIR" -h queue_directory 2>/dev/null; }
master_pid() { head -1 "$(queue_dir)/pid/master.pid" 2>/dev/null | tr -dc '0-9'; }
is_running() { local pid; pid=$(master_pid); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

# master.pid is bookkeeping, and on 2026-08-05 it lied in both directions on the
# same day: "stopped" against a live master on ins-15, where the file belonged to
# a service-era master this script no longer tracks, and "already running"
# against a dead one on the client, where the recorded pid had been reused by
# something else and kill -0 was happy to confirm it. Neither answer cost
# nothing -- the first invites a second master onto a queue that already has
# one, which is how that instance ended up with stale sockets in
# public/ and private/ and three daemons timing out.
#
# So ask the port. A listener answering 220 is the only evidence that matters to
# a caller, since that is what submitting mail actually needs.
smtp_port() {
	local svc port
	svc=$(postconf -c "$CONFIG_DIR" -M 2>/dev/null | awk '$2=="inet"{print $1; exit}')
	port=${svc##*:}
	case $port in *[!0-9]*|'')
		port=$(python3 -c "import socket,sys; print(socket.getservbyname(sys.argv[1]))" "$port" 2>/dev/null) ;;
	esac
	case $port in *[!0-9]*|'') port=25 ;; esac
	printf '%s\n' "$port"
}

answering() {
	local port
	port=${1:-$(smtp_port)}
	python3 - "$port" <<'PY' 2>/dev/null
import socket, sys
try:
    s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), 3)
    s.settimeout(3)
    banner = s.recv(64).decode('utf-8', 'replace')
    s.close()
except Exception:
    sys.exit(1)
sys.exit(0 if banner.startswith('220') else 1)
PY
}

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

do_start() {
	local port
	port=$(smtp_port)
	# The port first. Starting a second master onto a queue that already has one
	# is the expensive mistake here, and the pid file cannot rule it out: an
	# untracked master answers :25 while master.pid says nothing at all.
	if answering "$port"; then
		if is_running; then
			say "postfix already running ($CONFIG_DIR, pid $(master_pid))"
		else
			say "postfix already answering on :$port ($CONFIG_DIR), though master.pid does not name a live pid -- not starting a second master"
		fi
		return 0
	fi
	if is_running; then
		say "master.pid names live pid $(master_pid) but nothing answers :$port -- reaping it before starting"
		do_stop >/dev/null 2>&1 || true
	fi
	local log
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
	# Either signal is enough to call it up. A master that bound the port but
	# has not written master.pid yet is started; so is one whose pid we have.
	if answering "$port" || is_running; then
		say "postfix started ($CONFIG_DIR, pid $(master_pid))"
	else
		err "failed to start; maillog is often empty here (see below for why)"
		diag_start
		return 1
	fi
}

do_stop() {
	local dd pids tp still p dt
	dd=$(postconf -c "$CONFIG_DIR" -h daemon_directory 2>/dev/null); [ -n "$dd" ] || dd=/usr/libexec/postfix
	# Every postfix daemon for this tree reparented to init (ppid 1): the setsid
	# master and any children orphaned when a master was killed. ps here lists only
	# this tree's processes, so matching the daemon path is scope enough.
	pids=$(ps -ef 2>/dev/null | awk -v d="$dd/" '$3==1 && index($0,d){print $2}')
	# Include the tracked master in case it has not reparented yet.
	tp=$(master_pid); [ -n "$tp" ] && kill -0 "$tp" 2>/dev/null && pids="$pids $tp"
	pids=$(printf '%s\n' $pids | sort -un | sed '/^$/d')
	if [ -n "$pids" ]; then
		kill $pids 2>/dev/null || true
		for _ in 1 2 3 4 5; do
			still=
			for p in $pids; do kill -0 "$p" 2>/dev/null && still="$still $p"; done
			[ -z "$still" ] && break
			sleep 1
		done
		[ -n "$still" ] && kill -9 $still 2>/dev/null || true
	fi
	# Clear stale bookkeeping so the next start does not trip on a dead pid or a
	# left-behind lock.
	dt=$(postconf -c "$CONFIG_DIR" -h data_directory 2>/dev/null)
	rm -f "$(queue_dir)/pid/master.pid" 2>/dev/null
	[ -n "$dt" ] && rm -f "$dt/master.lock" 2>/dev/null
	if [ -n "$pids" ]; then say "postfix stopped ($(echo $pids))"; else say "postfix not running"; fi
}

case $ACTION in
	start)   do_start ;;
	stop)    do_stop ;;
	restart) do_stop; sleep 1; do_start ;;
	# The listener is the verdict and the pid file is a detail, so a disagreement
	# between them is reported rather than resolved silently -- it is the single
	# most useful thing this command can say, and both directions have happened.
	status)
		port=$(smtp_port)
		if answering "$port"; then
			if is_running; then say "running (pid $(master_pid), :$port answering)"
			else say "running (:$port answering, but master.pid names no live pid -- untracked master)"; fi
			exit 0
		fi
		if is_running; then
			say "stopped (master.pid names live pid $(master_pid), but nothing answers :$port)"
			exit 1
		fi
		say "stopped"
		exit 1 ;;
esac
