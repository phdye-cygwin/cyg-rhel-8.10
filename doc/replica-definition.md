# Replica definition

What "an established `cyg-rhel-8.10` instance" means, in checkable terms.
This is the target `bin/verify-replica.sh` asserts against after install; if
a version here changes, that script and this file change in the same
commit.

## Base

- Cygwin Time Machine snapshot, 2019-08-01:
  `http://ctm.crouchingtigerhiddenfruitbat.org/pub/cygwin/circa/64bit/2019/08/01/131636`
- Cygwin `3.0.7(0.338/5/3)` (`uname -r`)

## Core tools (from the snapshot, installed by `install-rhel810-noadmin.sh`)

| Tool | Version | RHEL 8.10 |
|---|---|---|
| bash | 4.4.12 | 4.4.20 (series match) |
| python3 (python36) | 3.6.9 | 3.6.8 (upstream match) |
| perl | 5.26.3 | 5.26.3 (upstream match) |
| git | 2.21.0 | newer on RHEL (8.x); tracked, not matched |
| tcsh | 6.21.00 | 6.20.00 (series match) |
| gcc | 7.4.0 | 8.5.0; known gap, see `gap-gcc-toolchain.md` |
| make | 4.2.1 | 4.2.1 (upstream match) |
| openssh | 8.0p1 (OpenSSL 1.1.1c) | upstream match |
| cygport | 0.33.1 | n/a (build tool only) |

## RHEL-parity packages (built here, not from the frozen Cygwin package set)

| Package | Version | Source |
|---|---|---|
| postfix | 3.5.8-1 | matches `postfix-3.5.8-7.el8`; pinned in `DEPENDENCIES.lock` |
| heirloom-mailx | 12.5-1 | matches RHEL 8.10's `mailx`; pinned in `DEPENDENCIES.lock` |

## Explicitly not part of this definition

`$HOME` layout, `PATH` assembly, personal shims (age/sops and similar),
git identity, `~/.local` contents. These are workstation- or CI-run-specific
and are set up separately from establishing the replica itself.

## Known, accepted deviations from RHEL 8.10

Recorded so a consumer of the replica knows the boundary of what it proves,
not because any of these are considered defects:

- gcc 7.4.0 vs RHEL's 8.5.0 (`gap-gcc-toolchain.md`)
- Local mail delivery is Maildir; RHEL's default is mbox
- `/sbin` and `/usr/sbin` are two real directories here; RHEL 8 merges them
  via symlink (`gap-filesystem-layout.md`)
- cron is Vixie; RHEL 8 ships cronie
- No `/lib64` (Cygwin is not multilib); RHEL's 64-bit libs live there

## Verifying

    bin/verify-replica.sh

Run from inside the replica's own bash after install. Exits non-zero and
names the mismatch if any pinned version disagrees with this file.
