# RHEL 8.10 Cygwin replica, no-admin build

Build a RHEL 8.10 Cygwin replica on a Windows machine where you do not have local
administrator rights. Everything comes up under your own account: the install,
the Postfix 3.5.8 MTA, and the Heirloom mailx client. The one capability it needs
beyond a plain login is a writable target directory. Developer Mode (for native
symlinks) is a convenience, not a requirement.

## Quick start

You need an existing Cygwin `setup-x86_64.exe` on the machine, a writable
directory, and no administrator rights. Clone the repo, then:

```sh
# 1. Install the Cygwin tree into C:\cyg-rhel-8.10 (no admin). Finds
#    setup-x86_64.exe automatically. --dry-run previews; --help lists options.
./install-rhel810-noadmin.sh

# 2. From the new replica's bash (C:\cyg-rhel-8.10\cygwin64\bin\bash.exe):
bin/install-packages.sh            # unpack Postfix 3.5.8 + Heirloom mailx
bin/postfix-user-setup.sh          # configure Postfix to run as you
bin/postfix-user-launch.sh start   # start the mail system now

# 3. From PowerShell, optional: start at each logon, add a terminal shortcut.
.\bin\install-logon-task.ps1
.\bin\install-mintty-shortcut.ps1

# 4. From the replica's bash: verify end to end (safe on a running instance).
./test/test-unprivileged-postfix.sh
```

Every command takes `-h`/`--help`, and each option also has an environment
variable. The sections below explain each step and the design.

## How it works

The usual way to run this stack registers Postfix, sshd, and cron as Windows
services under a dedicated account that csih creates, which needs administrator
rights. This build does none of that and needs none of it. Postfix runs directly
as your user, started by a per-user logon task; the sendmail shim handles
submission; sshd is dropped. The mechanism that makes it work is in Postfix's own
Cygwin port: when master starts and finds you are not in the Administrators
group, it emulates the root/mail_owner split against your own uid rather than
demanding a privileged account. That behavior is what `postfix-user-setup.sh`
leans on. The unprivileged path is tested end to end, a message submitted through
the sendmail shim and delivered to a Maildir, before each release.

## What you need

An existing Cygwin `setup-x86_64.exe` on the machine (reuse whatever Cygwin is
already there). A writable base directory; the scripts default to
`C:\cyg-rhel-8.10`, with the Cygwin root at `cygwin64\` beside the setup program
and package cache in `packages\`.
Network access to the Time Machine snapshot. No administrator rights.

## What each step does

Install the tree. `install-rhel810-noadmin.sh` runs setup with `--no-admin` from
the 2019-08-01 snapshot into the target root. It finds the newest
`setup-x86_64.exe` in the usual download spots (Downloads, Desktop) and copies it
into the setup dir, so you need not pre-place it, or point `--setup-exe` at one.
To rehearse first, add `--dry-run`. Every option also has an environment variable
and the option wins; run `--help` for the full list.

Install the built MTA. From inside the replica, `bin/install-packages.sh` unpacks
the Postfix 3.5.8 and mailx packages from `packages/` and seeds `/etc/postfix`.
Both were built against the Cygwin 3.0.7, gcc 7.4.0, and openssl 1.1.1c the
snapshot provides, so they drop straight in. To rebuild from source instead, the
cygports and patches are under `cygport/`.

Configure Postfix to run as you. `bin/postfix-user-setup.sh` sets `mail_owner` to
your account, binds smtpd to `127.0.0.1:25`, creates the queue directories, and
installs the sendmail shim. Run it once. On a fresh tree it also generates
`/etc/passwd` and `/etc/group` for your account (via `mkpasswd`/`mkgroup`), so
login shells and the terminal shortcut land in `/home/<you>` rather than your
Windows profile; it skips this if `/etc/passwd` already exists.

Bring it up. `bin/postfix-user-launch.sh start` starts master now.
`bin/install-logon-task.ps1` registers a logon task so it starts every time you
sign in, no admin. `schtasks /Run /TN rhel810-postfix` starts it without logging
out.

Optional, a terminal shortcut. `bin/install-mintty-shortcut.ps1` drops a mintty
login-shell shortcut in the base directory and on your Desktop; pass `-NoDesktop`
to skip the Desktop copy. No admin.

## Verify

`test/test-unprivileged-postfix.sh` stands up a second, throwaway Postfix instance
on `127.0.0.1:2525` under a scratch prefix, submits a message through the shim,
confirms Maildir delivery, then tears down. It touches nothing in `/etc/postfix`
or your live instance, so it is safe against a working setup. That test is what
validates the unprivileged path.

## Layout

```
install-rhel810-noadmin.sh   setup wrapper (--no-admin, configurable root)
bin/install-packages.sh      unpack built postfix + mailx into the tree
bin/postfix-user-setup.sh     configure Postfix to run as your user
bin/postfix-user-launch.sh    start/stop/status the master, no service manager
bin/sendmail-smtp-shim        /usr/sbin/sendmail replacement, submits over SMTP
bin/start-postfix.cmd         wrapper the logon task runs
bin/install-logon-task.ps1    register the per-user logon task
bin/install-mintty-shortcut.ps1  mintty terminal shortcut (base + Desktop)
packages/                     built .tar.xz for postfix and mailx
cygport/                      port sources, patches, pristine tarballs
test/                         the isolated validation
```

`start-postfix.cmd` and the test take paths that depend on where you cloned the
repo and what your Cygwin home is. The shell scripts derive the current user with
`id -un`; edit the launch path in `start-postfix.cmd` and pass `PF_TEST_PREFIX`
to the test if the defaults do not match your layout.

## Command-line conventions

Every shell command follows docopt: `-h`/`--help`, `--version`, `-v`/`-t`/`-d`
for verbosity, `-n`/`--dry-run` where it has side effects, and a command-line
option for each environment variable it reads (the option wins). Errors go to
stderr with a non-zero exit; a bad option exits 2. The `sendmail-smtp-shim` is
the exception: it keeps sendmail's own flag interface. The two `.ps1` helpers
follow PowerShell parameter conventions (`-NoDesktop`, `-Remove`, `-Base`).

## Notes and limits

Submission goes through the sendmail shim, not native postdrop. Cygwin will not
honor setgid-on-exec to hand an ordinary user the postdrop group, so postdrop
submission is broken with or without admin; the shim submits over SMTP to the
loopback smtpd, which works.

Local delivery is Maildir. To use mbox instead, set `postconf -e
mail_spool_directory=/var/spool/mail` (no trailing slash).

The install set omits the stock Cygwin `postfix` (frozen at 2.11.9); you install
the built 3.5.8 instead. The runtime libraries Postfix links (pcre, openssl,
sasl2, sqlite3, mysqlclient, pq, ldap, db) come in through the -devel packages in
that set.

mailx is built without SSL (12.5 predates OpenSSL 1.1's opaque structs). gcc is
7.4.0. Neither affects local mail.
