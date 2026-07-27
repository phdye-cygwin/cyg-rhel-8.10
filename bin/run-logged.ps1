<#
.SYNOPSIS
  Run a PowerShell script with COMPLETE output capture - its own streams and
  every child's, native and Cygwin - and write a redacted log by default.

.DESCRIPTION
  Start-Transcript captures only PowerShell's own streams, so a native child
  (setup-x86_64.exe, the tree's bash) that writes straight to the console is
  missed; that is why a transcript logs less than Cygwin `script`. This runs the
  target as a child process whose stdout and stderr cmd merges at the byte level,
  tees the raw output live to the console, then scrubs it into the redacted log.

  The redacted log (host, user, domain, profile path masked) is safe to share.
  The full, unredacted capture is written only with -Unredacted (or
  CYG_RHEL_UNREDACTED), to a sibling *.unredacted.log that .gitignore excludes.

.PARAMETER Log
  Explicit redacted-log path. Optional. When omitted the name is
  <date>.<time>.redacted.log under -LogDir.

.PARAMETER File
  The .ps1 to run.

.PARAMETER Unredacted
  Also keep the raw capture. CYG_RHEL_UNREDACTED=1 makes this the default.

.PARAMETER RedactAlso
  Extra literal strings to mask (e.g. a Cygwin username that differs from the
  Windows one).

.PARAMETER LogDir
  Directory for the logs. Default: CYG_RHEL_LOGDIR, else %TEMP%\cyg-rhel-8.10.

.PARAMETER Rest
  Remaining arguments, passed through to the script.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$Log = '',
  [Parameter(Mandatory=$true)][string]$File,
  [switch]$Unredacted,
  [string[]]$RedactAlso = @(),
  [string]$LogDir = '',
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'

# Read a boolean-ish environment value the way a person would expect from EITHER
# background. In PowerShell [bool]'0' and [bool]'false' are both $true (any
# non-empty string is truthy), and in POSIX shells `[ -n "$X" ]` is likewise true
# for "0" and "false" - both traps. So only 1/true/yes/on (any case) count as set;
# 0/false/no/off/empty/unset count as clear. To turn a flag OFF, unset it or set
# it to 0.
function Test-EnvFlag {
  param($v)
  if ($null -eq $v) { return $false }
  return @('1','true','yes','on') -contains ($v.ToString().Trim().ToLowerInvariant())
}

$explicitLog = -not [string]::IsNullOrEmpty($Log)
$keepRaw     = $Unredacted -or (Test-EnvFlag $env:CYG_RHEL_UNREDACTED)

# Log names are <date>.<time>.redacted.log and <date>.<time>.unredacted.log. The
# stamp is built with .NET format strings, because this is a native PowerShell
# tool and Get-Date speaks .NET, not strftime. The system we are BUILDING is
# POSIX, so for anyone reading from that side, here is the mapping:
#
#     .NET   strftime   meaning
#     ----   --------   -------
#     yyyy     %Y       4-digit year
#     MM       %m       2-digit month
#     dd       %d       2-digit day
#     HH       %H       2-digit hour (24-hour)
#     mm       %M       2-digit minute
#     ss       %S       2-digit second
#
# Watch the case swap: .NET 'MM' is month and 'mm' is minute, which is the
# reverse feel from strftime's %m (month) and %M (minute). That collision is why
# these are .NET strings and not strftime: feeding '%Y-%m-%d' to .NET does NOT
# error, it silently returns a wrong-but-plausible name ('%m' resolves to MINUTES
# in .NET), and a silent wrong stamp is worse than a loud one. Keep them .NET.
$dateFmt = if ($env:CYG_RHEL_DATE_STAMP) { $env:CYG_RHEL_DATE_STAMP } else { 'yyyy-MM-dd' }
$timeFmt = if ($env:CYG_RHEL_TIME_STAMP) { $env:CYG_RHEL_TIME_STAMP } else { 'HH-mm-ss' }
$now = Get-Date
try {
  $stamp = $now.ToString($dateFmt) + '.' + $now.ToString($timeFmt)
} catch {
  Write-Host "run-logged: bad CYG_RHEL_DATE_STAMP/TIME_STAMP ('$dateFmt'/'$timeFmt'); using defaults. These are .NET format strings, not strftime."
  $stamp = $now.ToString('yyyy-MM-dd') + '.' + $now.ToString('HH-mm-ss')
}

if (-not $LogDir) {
  $LogDir = if ($env:CYG_RHEL_LOGDIR) { $env:CYG_RHEL_LOGDIR } else { Join-Path $env:TEMP 'cyg-rhel-8.10' }
}

# Resolve the two paths. An explicit -Log names the redacted file and the raw one
# pairs beside it as <base>.unredacted<ext>; otherwise both come off one stamp.
if ($explicitLog) {
  $red    = $Log
  $rdir   = Split-Path $red -Parent; if (-not $rdir) { $rdir = (Get-Location).Path }
  $rawlog = [IO.Path]::Combine($rdir, [IO.Path]::GetFileNameWithoutExtension($red) + '.unredacted' + [IO.Path]::GetExtension($red))
} else {
  $red    = Join-Path $LogDir "$stamp.redacted.log"
  $rawlog = Join-Path $LogDir "$stamp.unredacted.log"
}

# Make sure the target directory is writable; fall back to %TEMP%, keeping the
# pair together, if not.
$dir = Split-Path -Parent $red
if (-not $dir) { $dir = (Get-Location).Path }
$can = $false
try {
  New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
  $probe = Join-Path $dir ('.probe-' + $PID)
  Set-Content -Path $probe -Value 'x' -ErrorAction Stop
  Remove-Item $probe -Force -ErrorAction SilentlyContinue
  $can = $true
} catch {}
if (-not $can) {
  $red    = Join-Path $env:TEMP (Split-Path $red -Leaf)
  $rawlog = Join-Path $env:TEMP (Split-Path $rawlog -Leaf)
  Write-Host "note: log directory is not writable; logging to $env:TEMP"
}

if (-not (Test-Path $File)) { throw "run-logged: script not found: $File" }

$argline = (@($Rest) | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$inner = ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" {1} 2>&1' -f $File, $argline).Trim()

# Raw capture, teed live to the console.
& $env:ComSpec /c $inner | Tee-Object -FilePath $rawlog
$rc = $LASTEXITCODE

# scrub-log reads the raw capture and writes the redacted, shareable copy.
& (Join-Path $PSScriptRoot 'scrub-log.ps1') -Path $rawlog -Out $red -Also $RedactAlso | Out-Null
Write-Host ""
Write-Host "run-logged: redacted log at $red"
if ($keepRaw) {
  Write-Host "run-logged: unredacted log at $rawlog (keep private; git ignores it)"
} else {
  Remove-Item $rawlog -Force -ErrorAction SilentlyContinue
}
Write-Host ("run-logged: {0} exited {1}" -f (Split-Path $File -Leaf), $rc)
exit $rc
