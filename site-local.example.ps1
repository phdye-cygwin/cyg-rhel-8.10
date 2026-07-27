# Per-site settings for the cyg-rhel-8.10 tools.
#
# Copy this file to site-local.ps1 (gitignored) and edit the values, then
# dot-source it before a run:
#
#     . .\site-local.ps1
#
# Every value is optional. Anything left unset falls back to a generic default,
# so a fresh clone runs without editing this at all - just at C:\cyg-rhel-8.10.

# The replica tree root (the Cygwin root the install builds). install-all.ps1
# and diag-mta.ps1 read this as $env:CYG_RHEL_ROOT.
# Default when unset: C:\cyg-rhel-8.10\cygwin64
$env:CYG_RHEL_ROOT = 'C:\cyg-rhel-8.10\cygwin64'

# The setup / package cache directory (setup-x86_64.exe and downloaded packages).
# Default when unset: C:\cyg-rhel-8.10\packages
$env:CYG_RHEL_SETUP_DIR = 'C:\cyg-rhel-8.10\packages'

# Where run logs go. Keep them off the repo and off C:\ root (which a standard
# user often cannot write). The run commands in the README build their -Log path
# from this. A per-user temp folder is always writable.
$env:CYG_RHEL_LOGDIR = Join-Path $env:TEMP 'cyg-rhel-8.10'

# Extra strings to mask in the shared (redacted) log, on top of the Windows host,
# user, domain, and profile path that are masked automatically. Use it for a
# Cygwin username that differs from your Windows one, or a specific hostname.
# Comma- or semicolon-separated. Leave unset if the automatic masking is enough.
# $env:CYG_RHEL_REDACT_ALSO = 'mycyguser,myhostname'
