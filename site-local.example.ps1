# Per-site settings for the cyg-rhel-8.10 tools.
#
# Copy this file to site-local.ps1 (gitignored) and edit the values. install-all.ps1
# and diag-mta.ps1 dot-source site-local.ps1 automatically, so a bare "Run with
# PowerShell" from Explorer picks these up with no command line.
#
# Every value is optional. Anything left unset falls back to a generic default,
# so a fresh clone runs without editing this at all - it installs to
# C:\cyg-rhel-8.10 and logs to %TEMP%\cyg-rhel-8.10. Uncomment only what you need.
#
# On the boolean flags below (CYG_RHEL_UNREDACTED, CYG_RHEL_NO_START,
# CYG_RHEL_NO_DOWNLOAD, CYG_RHEL_NO_PAUSE): only 1/true/yes/on (any case) turn a
# flag ON. Anything else - 0, false, no, off, empty, or unset - leaves it OFF.
# This matters coming from either direction: in PowerShell `[bool]'0'` is $true,
# and in a POSIX shell `[ -n "$X" ]` is true for "0" too, so the naive read of
# both languages would treat CYG_RHEL_NO_PAUSE=0 as "pause off". It does not here.
# To disable a flag, unset it or set it to 0.

# ---- Install location -------------------------------------------------------

# The replica tree root (the Cygwin root the install builds).
# Default: C:\cyg-rhel-8.10\cygwin64
$env:CYG_RHEL_ROOT = 'C:\cyg-rhel-8.10\cygwin64'

# The setup / package cache directory (setup-x86_64.exe and downloaded packages).
# Default: C:\cyg-rhel-8.10\packages
$env:CYG_RHEL_SETUP_DIR = 'C:\cyg-rhel-8.10\packages'

# The parent that root and packages sit under when you'd rather set one path than
# both above. Root/setup-dir override it. Default: C:\cyg-rhel-8.10
# $env:CYG_RHEL_BASE = 'D:\cyg-rhel-8.10'

# ---- Source and package set (rarely changed) --------------------------------

# The Cygwin Time Machine snapshot the install pulls from.
# Default: the 2019-08-01 64-bit snapshot that matches RHEL 8.10 tool versions.
# $env:CYG_RHEL_SNAPSHOT = 'http://ctm.crouchingtigerhiddenfruitbat.org/pub/cygwin/circa/64bit/2019/08/01/131636'

# Comma-separated package list. Default: the full development set install-all.ps1
# ships. Set this only to install a different set.
# $env:CYG_RHEL_PACKAGES = 'bash,coreutils,openssh,git,vim'

# ---- Logging: where -----------------------------------------------------------

# Where run logs go. Keep them off the repo and off C:\ root (which a standard
# user often cannot write). A per-user temp folder is always writable.
# Default: %TEMP%\cyg-rhel-8.10
$env:CYG_RHEL_LOGDIR = Join-Path $env:TEMP 'cyg-rhel-8.10'

# ---- Logging: the timestamp ---------------------------------------------------

# Log file names are fixed as <date>.<time>.redacted.log and
# <date>.<time>.unredacted.log. Only the date and time stamps are configurable,
# and they are .NET format strings (this is a native PowerShell tool; Get-Date
# speaks .NET, not strftime). The system being built is POSIX, so the mapping:
#
#     .NET   strftime   meaning
#     yyyy     %Y       4-digit year
#     MM       %m       2-digit month
#     dd       %d       2-digit day
#     HH       %H       2-digit hour (24-hour)
#     mm       %M       2-digit minute
#     ss       %S       2-digit second
#
# Case swap to watch: .NET 'MM' is month and 'mm' is minute - the reverse feel
# from strftime. Do NOT put strftime here: '%Y-%m-%d' does not error in .NET, it
# silently yields a wrong name ('%m' resolves to minutes). Keep them .NET.
# $env:CYG_RHEL_DATE_STAMP = 'yyyy-MM-dd'
# $env:CYG_RHEL_TIME_STAMP = 'HH-mm-ss'

# Keep the raw, unredacted capture on every run (same as passing -Unredacted).
# Off by default: only the redacted log (safe to attach to a bug report) is kept.
# $env:CYG_RHEL_UNREDACTED = '1'

# Every captured line is prefixed with a wall-clock timestamp in the log file (not
# on the console), so a stalled run shows exactly where it stopped. On by default.
# Set this to turn stamping off.
# $env:CYG_RHEL_NO_TIMESTAMP = '1'

# ---- Redaction ----------------------------------------------------------------

# Extra strings to mask in the shared (redacted) log, on top of the Windows host,
# user, domain, and profile path masked automatically. Use it for a Cygwin
# username that differs from your Windows one, or a specific hostname. Comma- or
# semicolon-separated.
# $env:CYG_RHEL_REDACT_ALSO = 'mycyguser,myhostname'

# ---- Run behavior -------------------------------------------------------------

# Configure the MTA but do not start it (same as -NoStart).
# $env:CYG_RHEL_NO_START = '1'

# Never download setup-x86_64.exe; fail if none is staged locally (-NoDownload).
# $env:CYG_RHEL_NO_DOWNLOAD = '1'

# Do not pause at the end of the run. Leave unset for the Explorer double-click
# case, where the pause keeps the window open to read the result; set it for
# unattended/scripted runs (same as -NoPause).
# $env:CYG_RHEL_NO_PAUSE = '1'

# A mintty terminal shortcut (base folder + Desktop), carrying the project icon,
# is created by default. Set this to skip it (same as -NoShortcut).
# $env:CYG_RHEL_NO_SHORTCUT = '1'

# Register a per-user logon task so the MTA starts at each sign-in. Off by
# default; no admin needed (same as -LogonTask).
# $env:CYG_RHEL_LOGON_TASK = '1'
