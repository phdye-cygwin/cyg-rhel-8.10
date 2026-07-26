#!/bin/bash
# Isolated proof that Postfix runs unprivileged with no admin: stand up a second
# instance under $PREFIX on 127.0.0.1:2525, submit through the sendmail shim,
# confirm local delivery, tear it down. Touches nothing in /etc/postfix or the
# system instance. Run as your normal user, no elevation.
set -u
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BIN=$REPO/bin
PREFIX=${PF_TEST_PREFIX:-/tmp/pf-test}
PORT=2525
STAMP=$(date +%s 2>/dev/null || echo now)
SUBJ="unpriv-postfix-test-$STAMP"
ME=$(id -un)

cleanup() {
	PF_CONFIG_DIR="$PREFIX/etc" "$BIN/postfix-user-launch.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== fresh test tree at $PREFIX =="
PF_CONFIG_DIR="$PREFIX/etc" "$BIN/postfix-user-launch.sh" stop >/dev/null 2>&1 || true
sleep 1
rm -rf "$PREFIX"
mkdir -p "$PREFIX/etc" "$PREFIX/spool" "$PREFIX/data" "$PREFIX/mail" "$PREFIX/bin"

echo "== configure instance (as $ME, port $PORT) =="
PF_CONFIG_DIR="$PREFIX/etc" PF_QUEUE_DIR="$PREFIX/spool" \
	PF_DATA_DIR="$PREFIX/data" PF_MAILBOX_DIR="$PREFIX/mail" \
	PF_SMTP_PORT="$PORT" PF_MAILLOG="$PREFIX/maillog" \
	PF_INSTALL_SENDMAIL=0 \
	"$BIN/postfix-user-setup.sh" || exit 1

# Private shim copy pinned to the test port; the system sendmail is left alone.
install -m 0755 "$BIN/sendmail-smtp-shim" "$PREFIX/bin/sendmail"
sed -i "s/\"SENDMAIL_SMTP_PORT\", \"[0-9]*\"/\"SENDMAIL_SMTP_PORT\", \"$PORT\"/" \
	"$PREFIX/bin/sendmail"

echo "== start master =="
PF_CONFIG_DIR="$PREFIX/etc" "$BIN/postfix-user-launch.sh" start || exit 1

echo "== check smtpd listening on 127.0.0.1:$PORT =="
python3 - "$PORT" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); print("LISTEN_OK"); s.close()
except Exception as e:
    print("LISTEN_FAIL", e); sys.exit(1)
PY

echo "== submit a message via the shim =="
printf 'From: tester@localdomain\nTo: %s@localdomain\nSubject: %s\n\nbody %s\n' \
	"$ME" "$SUBJ" "$STAMP" | "$PREFIX/bin/sendmail" -i "$ME@localdomain"

echo "== wait for local delivery =="
box="$PREFIX/mail/$ME"
found=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if grep -rl "$SUBJ" "$box" >/dev/null 2>&1; then found=yes; break; fi
	sleep 1
done

echo "== result =="
if [ -n "$found" ]; then
	echo "PASS: message delivered to $box"
	grep -rl "$SUBJ" "$box"
	exit 0
fi
echo "FAIL: message not delivered; tail of maillog:"
tail -30 "$PREFIX/maillog" 2>/dev/null
exit 1
