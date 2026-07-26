#!/bin/bash
# Install the built Postfix 3.5.8 and Heirloom mailx packages into the current
# Cygwin tree by unpacking the .tar.xz archives, then seed /etc/postfix from the
# packaged defaults. Run inside the replica -- its / is the tree root. No admin,
# no service registration; that is postfix-user-setup.sh's job.
set -eu
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PKG=$REPO/packages

echo "== unpack packages into / =="
for f in "$PKG"/postfix/postfix-3.5.8-1.tar.xz \
	"$PKG"/postfix/postfix-doc-3.5.8-1.tar.xz \
	"$PKG"/postfix/postfix-tools-3.5.8-1.tar.xz \
	"$PKG"/heirloom-mailx/heirloom-mailx-12.5-1.tar.xz; do
	echo "  $f"
	tar -C / -xJf "$f"
done

echo "== seed /etc/postfix from packaged defaults =="
if [ -d /etc/defaults/etc/postfix ]; then
	mkdir -p /etc/postfix
	cp -rn /etc/defaults/etc/postfix/. /etc/postfix/
fi

# Until the shim is installed, point sendmail at the postfix binary so mailx has
# a target. postfix-user-setup.sh replaces this with the SMTP shim.
[ -e /usr/sbin/sendmail ] || ln -sf sendmail.postfix.exe /usr/sbin/sendmail

echo "install-packages: done. Next: bin/postfix-user-setup.sh"
