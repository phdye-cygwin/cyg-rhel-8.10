# RHEL 8.10 Cygwin replica, no-admin build

Build a RHEL 8.10 Cygwin replica on a Windows machine where you do not have local
administrator rights. Everything comes up under your own account: the install,
the Postfix 3.5.8 MTA, and the Heirloom mailx client. The one capability it needs
beyond a plain login is a writable target directory. Developer Mode (for native
symlinks) is a convenience, not a requirement.

## Quick start

All you need is a writable directory and your own account. If no
`setup-x86_64.exe` is on the machine, the installer downloads one. Clone the
repo, then pick the harness that fits where you are.

From Windows with no Cygwin yet (PowerShell, or double-click the `.cmd`):

```powershell
.\install-all.ps1         # -DryRun to preview the plan
```

From an existing Cygwin shell:

```sh
./install-all.sh          # --dry-run to preview; --help for options
```

Either one installs the tree, then installs, configures, and starts the MTA
inside it. They differ only in how they reach the new tree: `install-all.ps1`
launches its bash from PowerShell, a native parent, while `install-all.sh`
crosses through `cmd.exe`. Both sidestep the deadlock you would hit launching a
replica binary straight from another Cygwin shell, where two `cygwin1.dll`
instances collide.

`install-all.ps1` logs itself. Every run is captured in full (the output of setup
and the tree's own bash included, which a PowerShell transcript drops) to a
redacted log under `%TEMP%\cyg-rhel-8.10\` (or `CYG_RHEL_LOGDIR`), safe to attach
to a bug report: your host, user, and domain are masked. The log is named
`<date>.<time>.redacted.log` (default `2026-07-26.14-32-05.redacted.log`); the
stamp and the name pattern are configurable in `site-local.ps1`. Add `-Unredacted`
to also keep the raw capture beside it as `<date>.<time>.unredacted.log`, which
git ignores. The capture is built in; there is nothing extra to invoke.

From Windows Explorer, right-click `install-all.ps1` and choose "Run with
PowerShell": with a `site-local.ps1` in place it needs no arguments and does the
whole install, then pauses on the finished window so you can read the result.
`site-local.example.ps1` lists every knob - paths, log directory, stamp and
name patterns, extra redactions, and whether to pause - with an example for each.

`bin\run-logged.ps1` is the capture mechanism and works for any script (such as
`diag-mta.ps1`); `bin\scrub-log.ps1` redacts a log you already have. From a Cygwin
shell you can still wrap `./install-all.sh` with `script`.

Prefer to run the phases yourself? The same steps by hand:

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

A writable base directory and your own account. A `setup-x86_64.exe` if one is
already on the machine; if not, the installer downloads it from cygwin.com. The
scripts default to `C:\cyg-rhel-8.10`, with the Cygwin root at `cygwin64\` beside
the setup program and package cache in `packages\`. Point `--base` (`-Base` for
the `.ps1`) elsewhere to move the whole install; `--root` and `--pkg-dir`
override each half on its own if you want them apart. To relocate the install
without editing anything tracked, set `CYG_RHEL_ROOT` and `CYG_RHEL_SETUP_DIR`;
the tools read them, and a command-line `-Root`/`-PkgDir` still wins.
`site-local.example.ps1` templates these (plus a log directory): copy it to
`site-local.ps1`, which git ignores, and dot-source it.
Network access to the Time Machine snapshot. No administrator rights.

## What each step does

Install the tree. `install-rhel810-noadmin.sh` runs setup with `--no-admin` from
the 2019-08-01 snapshot into the target root. It finds the newest
`setup-x86_64.exe` in the usual download spots (Downloads, Desktop) and copies it
into the setup dir, so you need not pre-place it, or point `--setup-exe` at one.
If none is found anywhere, it downloads one from cygwin.com, which `--no-download`
refuses. To rehearse first, add `--dry-run`. Every option also has an environment variable
and the option wins; run `--help` for the full list.

Install the built MTA. From inside the replica, `bin/install-packages.sh` unpacks
the Postfix 3.5.8 and mailx packages from `packages/` and seeds `/etc/postfix`.
Both were built against the Cygwin 3.0.7, gcc 7.4.0, and openssl 1.1.1c the
snapshot provides, so they drop straight in. To rebuild from source instead, the
cygports and patches are under `cygport/`.

Configure Postfix to run as you. `bin/postfix-user-setup.sh` sets `mail_owner` to
your account, binds smtpd to `127.0.0.1:25`, creates the queue directories, and
installs the sendmail shim. It also seeds `/etc/aliases` and builds its database,
without which the loopback smtpd refuses every local recipient with a 451. Run it
once. On a fresh tree it also generates
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
install-all.ps1              native one-shot harness (no existing Cygwin needed)
install-all.cmd              wrapper so install-all.ps1 runs from cmd or a click
install-all.sh               one-shot harness from an existing Cygwin shell
install-rhel810-noadmin.sh   setup wrapper (--no-admin, configurable root)
site-local.example.ps1       template for per-site paths and log dir (copy to site-local.ps1)
bin/install-packages.sh      unpack built postfix + mailx into the tree
bin/postfix-user-setup.sh     configure Postfix to run as your user
bin/postfix-user-launch.sh    start/stop/restart/status the master, no service manager
bin/start-tree-postfix.ps1    start the MTA detached and console-less
bin/stop-tree-postfix.ps1     reap any MTA left running under a tree
bin/sendmail-smtp-shim        /usr/sbin/sendmail replacement, submits over SMTP
bin/start-postfix.cmd         wrapper the logon task runs
bin/install-logon-task.ps1    register the per-user logon task
bin/install-mintty-shortcut.ps1  mintty terminal shortcut (base + Desktop)
bin/run-logged.ps1            run a script, capturing all output (native + Cygwin) to a log
bin/diag-mta.ps1              read-only probe for a stuck run (fds, process tree, logs)
bin/scrub-log.ps1             mask host/user/domain in a log before sharing
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
the built 3.5.8 instead. Most runtime libraries Postfix links (pcre, openssl,
sasl2, sqlite3, mysqlclient, ldap, db) arrive through the -devel packages in that
set. `libpq5` is listed on its own: `libpq-devel` does not pull it on the 2019
snapshot, and the prebuilt Postfix needs `cygpq-5.dll` to start.

mailx is built without SSL (12.5 predates OpenSSL 1.1's opaque structs). gcc is
7.4.0. Neither affects local mail.
