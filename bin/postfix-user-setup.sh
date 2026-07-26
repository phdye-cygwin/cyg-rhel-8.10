#!/bin/bash
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

OWNER=${PF_OWNER:-$(id -un)}
GROUP=${PF_GROUP:-$(id -gn)}
CONFIG_DIR=${PF_CONFIG_DIR:-/etc/postfix}
QUEUE_DIR=${PF_QUEUE_DIR:-/var/spool/postfix}
DATA_DIR=${PF_DATA_DIR:-/var/lib/postfix}
MAILBOX_DIR=${PF_MAILBOX_DIR:-/var/spool/mail}
SMTP_PORT=${PF_SMTP_PORT:-25}
MAILLOG=${PF_MAILLOG:-/var/log/maillog}
INSTALL_SENDMAIL=${PF_INSTALL_SENDMAIL:-1}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "postfix-user-setup: owner=$OWNER group=$GROUP config=$CONFIG_DIR port=$SMTP_PORT"

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
	echo "postfix-user-setup: generated /etc/passwd and /etc/group"
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

# 4. Ownership. chown to yourself needs no privilege; it corrects files the tar
#    unpack left with foreign owners.
chown -R "$OWNER":"$GROUP" "$QUEUE_DIR" "$DATA_DIR" 2>/dev/null || true
chmod 700 "$DATA_DIR"

# 5. sendmail shim -> smtpd, so mailx/cron/apps submit with no postdrop. The sed
#    bakes the port into the installed copy so callers need no environment.
if [ "$INSTALL_SENDMAIL" = "1" ]; then
	install -m 0755 "$HERE/sendmail-smtp-shim" /usr/local/sbin/sendmail-smtp-shim
	sed -i "s/\"SENDMAIL_SMTP_PORT\", \"[0-9]*\"/\"SENDMAIL_SMTP_PORT\", \"$SMTP_PORT\"/" \
		/usr/local/sbin/sendmail-smtp-shim
	ln -sf /usr/local/sbin/sendmail-smtp-shim /usr/sbin/sendmail
fi

echo "postfix-user-setup: done ($CONFIG_DIR)"
