#!/bin/bash
# Start, stop, or check the unprivileged Postfix master with no service manager.
# A per-user logon Scheduled Task calls "start"; you can also run it by hand.
# master runs with -d (stay in foreground) under nohup, so this launcher owns the
# logfile and the pid; a bare 3.x master would self-detach and we'd lose track.
set -u
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

CONFIG_DIR=${PF_CONFIG_DIR:-/etc/postfix}
ACTION=${1:-start}
MASTER=/usr/libexec/postfix/master

queue_dir() { postconf -c "$CONFIG_DIR" -h queue_directory 2>/dev/null; }

master_pid() {
	head -1 "$(queue_dir)/pid/master.pid" 2>/dev/null | tr -dc '0-9'
}

is_running() {
	local pid
	pid=$(master_pid)
	[ -n "$pid" ] || return 1
	kill -0 "$pid" 2>/dev/null
}

case "$ACTION" in
start)
	if is_running; then
		echo "postfix already running ($CONFIG_DIR, pid $(master_pid))"
		exit 0
	fi
	log=$(postconf -c "$CONFIG_DIR" -h maillog_file 2>/dev/null)
	[ -n "$log" ] || log=/var/log/maillog
	mkdir -p "$(dirname "$log")"
	nohup "$MASTER" -c "$CONFIG_DIR" -d >>"$log" 2>&1 &
	sleep 2
	if is_running; then
		echo "postfix started ($CONFIG_DIR, pid $(master_pid))"
	else
		echo "postfix failed to start; see $log" >&2
		exit 1
	fi
	;;
stop)
	pid=$(master_pid)
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || true
		echo "postfix stopped (pid $pid)"
	else
		echo "postfix not running"
	fi
	;;
status)
	if is_running; then echo "running (pid $(master_pid))"; else echo "stopped"; exit 1; fi
	;;
*)
	echo "usage: ${0##*/} {start|stop|status}" >&2
	exit 2
	;;
esac
