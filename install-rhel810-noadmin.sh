#!/bin/bash
# Install the RHEL 8.10 Cygwin replica tree with no administrator rights, from
# the 2019-08-01 Cygwin Time Machine snapshot. This is the same --no-admin
# mechanism the original replica was built with; nothing here needs elevation.
#
# The target root is configurable (REPLICA_ROOT / SETUP_DIR) so you can install
# a throwaway tree for testing without touching an existing C:\cyg-rhel-8.10. Set
# DRY_RUN=1 to print the setup command instead of running it.
#
# Run from any shell that can exec the Cygwin setup .exe (the box's existing
# Cygwin bash, or cmd). It does NOT install services or accounts -- that is
# deliberate; see postfix-user-setup.sh and install-logon-task.ps1.
set -u

REPLICA_ROOT=${REPLICA_ROOT:-'C:\cyg-rhel-8.10\cygwin64'}
SETUP_DIR=${SETUP_DIR:-'C:\cyg-rhel-8.10\packages'}
SETUP_EXE=${SETUP_EXE:-"$SETUP_DIR\\setup-x86_64.exe"}
SNAPSHOT=${SNAPSHOT:-'http://ctm.crouchingtigerhiddenfruitbat.org/pub/cygwin/circa/64bit/2019/08/01/131636'}
DRY_RUN=${DRY_RUN:-0}

# Package set. Base RHEL-parity tools plus the runtime/-devel libraries the
# built Postfix and mailx link against. The stock Cygwin `postfix` (2.11.9,
# frozen 2014) is deliberately left out: install the built 3.5.8 from
# packages/ afterward with install-packages.sh. csih/cygrunsrv/alternatives/
# editrights/getent satisfy the postfix package's own install scripts even
# though we never register a service.
PKGS=${PKGS:-'bash,coreutils,sed,gawk,grep,findutils,diffutils,patch,tar,gzip,bzip2,xz,which,less,procps-ng,util-linux,ncurses,zlib,rpm,gcc-core,gcc-g++,make,autoconf,automake,libtool,flex,bison,binutils,gdb,pkg-config,perl,python36,python3,openssh,openssl,curl,wget,rsync,git,vim,nano,tcsh,cygrunsrv,csih,cron,cygport,cpio,alternatives,editrights,getent,file,m4,texinfo,patchutils,libdb-devel,libpcre-devel,libpcre2-devel,libssl-devel,libsasl2-devel,libsqlite3-devel,libmysqlclient-devel,libpq-devel,openldap-devel,libintl-devel,gettext-devel,zlib-devel,libiconv-devel'}

set -- -q -X -n -d -N --no-admin \
	-R "$REPLICA_ROOT" -s "$SNAPSHOT" -l "$SETUP_DIR" -P "$PKGS"

echo "setup exe : $SETUP_EXE"
echo "root      : $REPLICA_ROOT"
echo "snapshot  : $SNAPSHOT"
echo "packages  : $(echo "$PKGS" | tr ',' ' ' | wc -w) requested"

if [ "$DRY_RUN" = "1" ]; then
	printf 'DRY RUN, would run:\n  %s' "$SETUP_EXE"
	for a in "$@"; do printf ' %s' "$a"; done
	printf '\n'
	exit 0
fi

# -X is required (the archived setup.ini is unsigned). setup detaches; watch the
# log it writes under the new root. From a Cygwin shell the .exe must be invoked
# by its POSIX path; from cmd the Windows path runs as-is. The Windows-path args
# (-R/-l) stay literal -- setup is a native program and wants them that way.
RUN_EXE="$SETUP_EXE"
command -v cygpath >/dev/null 2>&1 && RUN_EXE="$(cygpath -u "$SETUP_EXE")"
"$RUN_EXE" "$@"
echo "setup launched. Watch: $REPLICA_ROOT\\var\\log\\setup.log.full"
