# Per-site settings for the cyg-rhel-8.10 tools.
#
# Copy this file to site-local.ps1 (gitignored) and edit the values. install-all.ps1
# and diag-mta.ps1 dot-source site-local.ps1 automatically, so a bare "Run with
# PowerShell" from Explorer picks these up with no command line.
#
# Every value is optional. Anything left unset falls back to a generic default,
# so a fresh clone runs without editing this at all - it installs to
# C:\cyg-rhel-8.10 and logs to %TEMP%\cyg-rhel-8.10. Uncomment only what you need.

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

# ---- Logging: names -----------------------------------------------------------

# Log file names are built from a date stamp and a time stamp, joined with a dot:
#   timestamp = <date>.<time>
#   redacted  -> <timestamp>.redacted.log     (shareable; host/user/domain masked)
#   unredacted-> <timestamp>.unredacted.log   (raw; git-ignored, kept only on request)
#
# The stamps are .NET format strings (Get-Date -Format). Defaults match strftime
# %Y-%m-%d and %H-%M-%S.
# $env:CYG_RHEL_DATE_STAMP = 'yyyy-MM-dd'
# $env:CYG_RHEL_TIME_STAMP = 'HH-mm-ss'

# The log-name patterns. {stamp}, {date}, {time} expand. If you set a custom
# unredacted pattern, its glob (placeholders -> *) is added to .gitignore before
# the log is written, so a differently named raw log can never be committed.
# $env:CYG_RHEL_REDACTED_NAME   = '{stamp}.redacted.log'
# $env:CYG_RHEL_UNREDACTED_NAME = '{stamp}.unredacted.log'

# Keep the raw, unredacted capture on every run (same as passing -Unredacted).
# Off by default: only the redacted log is kept.
# $env:CYG_RHEL_UNREDACTED = '1'

# ---- Redaction ----------------------------------------------------------------

# Extra strings to mask in the shared (redacted) log, on top of the Windows host,
# user, domain, and profile path masked automatically. Use it for a Cygwin
# username that differs from your Windows one, or a specific hostname. Comma- or
# semicolon-separated.
# $env:CYG_RHEL_REDACT_ALSO = 'mycyguser,myhostname'

# ---- Run behavior -------------------------------------------------------------

# Configure the MTA but do not start it (same as -NoStart).
# $env:CYG_RHEL_NO_START = '1'

# Never download setup-x86_64.exe; fail if none is staged locally (same as
# -NoDownload).
# $env:CYG_RHEL_NO_DOWNLOAD = '1'

# Do not pause at the end of the run. Leave unset for the Explorer double-click
# case, where the pause keeps the window open to read the result; set it for
# unattended/scripted runs (same as -NoPause).
# $env:CYG_RHEL_NO_PAUSE = '1'
