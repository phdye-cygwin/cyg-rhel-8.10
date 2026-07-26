#!/usr/bin/env bash
# Configure an already-installed Postfix to run as an ordinary, unprivileged
# user: no cyg_server service account, no cygrunsrv, no admin. This is what lets
# the replica's MTA come up on a locked-down machine where you have
# Developer Mode but not local administrator.
#
# Everything is driven by environment variables, so the same script configures
# the real system instance (the defaults below) and a throwaway side-by-side
# test instance (paths overridden, a different port). Run it as the user that
# will own and run Postfix.
#
# It does NOT create accounts, register services, or call `postfix
# set-permissions` (that needs a root Cygwin doesn't have). It sets ownership
# and the config directly.
set -eu
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

PROG=${0##*/}
VERSION='postfix-user-setup 1.0'

usage() {
	cat <<EOF
Configure an already-installed Postfix to run as an unprivileged user.

Usage:
  $PROG [options]

Options:
  -o, --owner USER        mail_owner / run-as user [default: current user]
  -g, --group GROUP       setgid_group [default: current group]
  -c, --config-dir DIR    Postfix config directory [default: /etc/postfix]
  -Q, --queue-dir DIR     queue directory [default: /var/spool/postfix]
  -D, --data-dir DIR      data directory [default: /var/lib/postfix]
  -m, --mailbox-dir DIR   local mailbox base [default: /var/spool/mail]
  -p, --port PORT         smtpd loopback port [default: 25]
  -L, --maillog FILE      maillog file [default: /var/log/maillog]
      --install-sendmail      install the sendmail shim (default)
      --no-install-sendmail   leave /usr/sbin/sendmail untouched
  -v, --verbose           more detail
  -t, --terse             minimal output
  -d, --debug             debug/trace output (implies --verbose)
  -h, --help              show this help and exit
      --version           show version and exit

Each option can also be set by environment variable (the option wins):
PF_OWNER, PF_GROUP, PF_CONFIG_DIR, PF_QUEUE_DIR, PF_DATA_DIR, PF_MAILBOX_DIR,
PF_SMTP_PORT, PF_MAILLOG, PF_INSTALL_SENDMAIL.
EOF
}

err()       { printf '%s: %s\n' "$PROG" "$*" >&2; }
die_usage() { err "$*"; exit 2; }
say()       { [ "$TERSE" = 1 ] || printf '%s\n' "$*"; }

OWNER=${PF_OWNER:-$(id -un)}
GROUP=${PF_GROUP:-$(id -gn)}
CONFIG_DIR=${PF_CONFIG_DIR:-/etc/postfix}
QUEUE_DIR=${PF_QUEUE_DIR:-/var/spool/postfix}
DATA_DIR=${PF_DATA_DIR:-/var/lib/postfix}
MAILBOX_DIR=${PF_MAILBOX_DIR:-/var/spool/mail}
SMTP_PORT=${PF_SMTP_PORT:-25}
MAILLOG=${PF_MAILLOG:-/var/log/maillog}
INSTALL_SENDMAIL=${PF_INSTALL_SENDMAIL:-1}
VERBOSE=0 TERSE=0 DEBUG=0
HERE=$(cd "$(dirname "$0")" && pwd)

while [ $# -gt 0 ]; do
	case $1 in
		--)                    shift; break ;;
		-o|--owner)            OWNER=${2?missing value for $1}; shift 2 ;;
		--owner=*)             OWNER=${1#*=}; shift ;;
		-g|--group)            GROUP=${2?missing value for $1}; shift 2 ;;
		--group=*)             GROUP=${1#*=}; shift ;;
		-c|--config-dir)       CONFIG_DIR=${2?missing value for $1}; shift 2 ;;
		--config-dir=*)        CONFIG_DIR=${1#*=}; shift ;;
		-Q|--queue-dir)        QUEUE_DIR=${2?missing value for $1}; shift 2 ;;
		--queue-dir=*)         QUEUE_DIR=${1#*=}; shift ;;
		-D|--data-dir)         DATA_DIR=${2?missing value for $1}; shift 2 ;;
		--data-dir=*)          DATA_DIR=${1#*=}; shift ;;
		-m|--mailbox-dir)      MAILBOX_DIR=${2?missing value for $1}; shift 2 ;;
		--mailbox-dir=*)       MAILBOX_DIR=${1#*=}; shift ;;
		-p|--port)             SMTP_PORT=${2?missing value for $1}; shift 2 ;;
		--port=*)              SMTP_PORT=${1#*=}; shift ;;
		-L|--maillog)          MAILLOG=${2?missing value for $1}; shift 2 ;;
		--maillog=*)           MAILLOG=${1#*=}; shift ;;
		--install-sendmail)    INSTALL_SENDMAIL=1; shift ;;
		--no-install-sendmail) INSTALL_SENDMAIL=0; shift ;;
		-v|--verbose)          VERBOSE=$((VERBOSE + 1)); shift ;;
		-t|--terse)            TERSE=1; shift ;;
		-d|--debug)            DEBUG=1; VERBOSE=$((VERBOSE + 1)); shift ;;
		-h|--help)             usage; exit 0 ;;
		--version)             printf '%s\n' "$VERSION"; exit 0 ;;
		-*)                    die_usage "unknown option: $1 (try --help)" ;;
		*)                     die_usage "unexpected argument: $1 (try --help)" ;;
	esac
done
[ $# -eq 0 ] || die_usage "unexpected argument: $1 (try --help)"
if [ "$DEBUG" = 1 ]; then set -x; fi

say "postfix-user-setup: owner=$OWNER group=$GROUP config=$CONFIG_DIR port=$SMTP_PORT"

# 0. Cygwin identity. Without /etc/passwd, a login shell resolves HOME to your
#    Windows profile, so mintty and cron land in the wrong home. Generate
#    passwd/group for the CURRENT account (works for local and domain users; -l
#    would miss a domain account). Guarded on /etc/passwd so it runs once on a
#    fresh tree and never disturbs a configured tree or the test's host.
if [ ! -f /etc/passwd ]; then
	mkpasswd -c -p /home > /etc/passwd
	[ -f /etc/group ] || mkgroup -c > /etc/group
	mkdir -p "/home/$OWNER"
	chown "$OWNER":"$GROUP" "/home/$OWNER" 2>/dev/null || true
	say "postfix-user-setup: generated /etc/passwd and /etc/group"
fi

# 1. Directories, owned by the running user. Seed main.cf/master.cf from the
#    packaged system config when building a fresh instance dir; postconf edits
#    them in place and needs them present.
mkdir -p "$CONFIG_DIR" "$QUEUE_DIR" "$DATA_DIR" "$MAILBOX_DIR"
# A fresh queue directory needs its standard subdirs before master will start;
# `postfix set-permissions` would make them but it chowns to root, which Cygwin
# has no user for. Create them directly instead.
for d in incoming active deferred bounce defer flush hold saved corrupt trace \
	public private maildrop pid; do
	mkdir -p "$QUEUE_DIR/$d"
done
[ -f "$CONFIG_DIR/main.cf" ]   || cp /etc/postfix/main.cf   "$CONFIG_DIR/main.cf"
[ -f "$CONFIG_DIR/master.cf" ] || cp /etc/postfix/master.cf "$CONFIG_DIR/master.cf"

# 2. main.cf. mail_owner=$OWNER is the crux: Postfix checks queue ownership
#    against it, and with both it and the running process set to the same user,
#    the "become root" paths in master never fire.
postconf -c "$CONFIG_DIR" -e \
	"queue_directory = $QUEUE_DIR" \
	"data_directory = $DATA_DIR" \
	"mail_owner = $OWNER" \
	"setgid_group = $GROUP" \
	"default_privs = $OWNER" \
	"command_directory = /usr/sbin" \
	"daemon_directory = /usr/libexec/postfix" \
	"mail_spool_directory = $MAILBOX_DIR/" \
	"maillog_file = $MAILLOG" \
	"maillog_file_prefixes = /var, /dev/stdout, $(dirname "$MAILLOG")" \
	"inet_interfaces = loopback-only" \
	"inet_protocols = ipv4" \
	"mynetworks = 127.0.0.0/8" \
	"myhostname = rhel810.localdomain" \
	"mydomain = localdomain" \
	"myorigin = \$mydomain" \
	"mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain" \
	"local_transport = local" \
	"relayhost =" \
	"compatibility_level = 2" \
	"append_dot_mydomain = no"

# 3. master.cf: bind smtpd to loopback on the chosen port, replacing the stock
#    "smtp inet" entry. postscreen and other fd-passing services stay off; the
#    port's AF_UNIX emulation can't pass file descriptors.
postconf -c "$CONFIG_DIR" -MX "smtp/inet" 2>/dev/null || true
postconf -c "$CONFIG_DIR" -MX "127.0.0.1:$SMTP_PORT/inet" 2>/dev/null || true
postconf -c "$CONFIG_DIR" -M -e \
	"127.0.0.1:$SMTP_PORT/inet = 127.0.0.1:$SMTP_PORT inet n - n - - smtpd"

# 3a. Aliases. local_recipient_maps consults alias_maps at RCPT time, so a
#     missing alias database rejects every local recipient with a 451. RHEL
#     keeps this at /etc/aliases; the Cygwin postfix package ships
#     /etc/postfix/aliases instead. Seed the RHEL path from it (or a stub) and
#     build the .db.
if [ ! -f /etc/aliases ]; then
	if [ -f /etc/postfix/aliases ]; then
		cp /etc/postfix/aliases /etc/aliases
	else
		printf 'postmaster: %s\n' "$OWNER" > /etc/aliases
	fi
fi
postalias hash:/etc/aliases

# 4. Ownership. chown to yourself needs no privilege; it corrects files the tar
#    unpack left with foreign owners.
chown -R "$OWNER":"$GROUP" "$QUEUE_DIR" "$DATA_DIR" 2>/dev/null || true
chmod 700 "$DATA_DIR"

# 5. sendmail shim -> smtpd, so mailx/cron/apps submit with no postdrop. The sed
#    bakes the port into the installed copy so callers need no environment.
if [ "$INSTALL_SENDMAIL" = "1" ]; then
	install -D -m 0755 "$HERE/sendmail-smtp-shim" /usr/local/sbin/sendmail-smtp-shim
	sed -i "s/\"SENDMAIL_SMTP_PORT\", \"[0-9]*\"/\"SENDMAIL_SMTP_PORT\", \"$SMTP_PORT\"/" \
		/usr/local/sbin/sendmail-smtp-shim
	ln -sf /usr/local/sbin/sendmail-smtp-shim /usr/sbin/sendmail
fi

say "postfix-user-setup: done ($CONFIG_DIR)"
