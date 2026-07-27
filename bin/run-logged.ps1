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
  The full, unredacted capture is written only with -Unredacted (or the
  CYG_RHEL_UNREDACTED env), to a sibling file whose name .gitignore excludes.

.PARAMETER Log
  Explicit redacted-log path. Optional. When omitted the name is built from the
  configured stamp and name patterns (see NOTES) under -LogDir.

.PARAMETER File
  The .ps1 to run.

.PARAMETER Unredacted
  Also keep the raw capture. CYG_RHEL_UNREDACTED=1 makes this the default.

.PARAMETER RedactAlso
  Extra literal strings to mask (e.g. a Cygwin username that differs from the
  Windows one).

.PARAMETER LogDir
  Directory for pattern-named logs. Default: CYG_RHEL_LOGDIR, else
  %TEMP%\cyg-rhel-8.10.

.PARAMETER Rest
  Remaining arguments, passed through to the script.

.NOTES
  Naming knobs (set in site-local.ps1 or the environment):
    CYG_RHEL_DATE_STAMP       .NET date format  (default yyyy-MM-dd)
    CYG_RHEL_TIME_STAMP       .NET time format  (default HH-mm-ss)
    CYG_RHEL_REDACTED_NAME    name pattern      (default {stamp}.redacted.log)
    CYG_RHEL_UNREDACTED_NAME  name pattern      (default {stamp}.unredacted.log)
  {stamp} expands to <date>.<time>; {date} and {time} expand on their own. A
  custom CYG_RHEL_UNREDACTED_NAME is added to the repo .gitignore before the log
  is written, so a raw capture named outside the default *unredacted* rule can
  never be committed by accident.
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

function Expand-Name([string]$pat, [hashtable]$vars) {
  foreach ($k in $vars.Keys) { $pat = $pat -replace ('\{' + $k + '\}'), [string]$vars[$k] }
  return $pat
}

$explicitLog = -not [string]::IsNullOrEmpty($Log)
$keepRaw     = $Unredacted -or $env:CYG_RHEL_UNREDACTED

# Stamp and name patterns come from the environment (site-local.ps1 sets them).
$dateFmt = if ($env:CYG_RHEL_DATE_STAMP) { $env:CYG_RHEL_DATE_STAMP } else { 'yyyy-MM-dd' }
$timeFmt = if ($env:CYG_RHEL_TIME_STAMP) { $env:CYG_RHEL_TIME_STAMP } else { 'HH-mm-ss' }
$now     = Get-Date
$dateStr = $now.ToString($dateFmt)
$timeStr = $now.ToString($timeFmt)
$vars    = @{ stamp = "$dateStr.$timeStr"; date = $dateStr; time = $timeStr }

$redPat   = if ($env:CYG_RHEL_REDACTED_NAME)   { $env:CYG_RHEL_REDACTED_NAME }   else { '{stamp}.redacted.log' }
$unredPat = if ($env:CYG_RHEL_UNREDACTED_NAME) { $env:CYG_RHEL_UNREDACTED_NAME } else { '{stamp}.unredacted.log' }

if (-not $LogDir) {
  $LogDir = if ($env:CYG_RHEL_LOGDIR) { $env:CYG_RHEL_LOGDIR } else { Join-Path $env:TEMP 'cyg-rhel-8.10' }
}

# A custom unredacted name pattern must be gitignored before it is written. Turn
# the pattern into a glob (placeholders -> *), then add it to the repo .gitignore
# if it is not already listed. Idempotent.
if ($env:CYG_RHEL_UNREDACTED_NAME) {
  $glob = $env:CYG_RHEL_UNREDACTED_NAME
  foreach ($k in @('stamp','date','time')) { $glob = $glob -replace ('\{' + $k + '\}'), '*' }
  while ($glob -match '\*\*') { $glob = $glob -replace '\*\*', '*' }
  $repo = Split-Path $PSScriptRoot -Parent
  $gi   = Join-Path $repo '.gitignore'
  if ((Test-Path $gi) -and ((Get-Content $gi) -notcontains $glob)) {
    Add-Content -Path $gi -Value @('', '# Custom unredacted log pattern (added automatically by run-logged.ps1).', $glob)
    Write-Host "run-logged: added '$glob' to .gitignore"
  }
}

if (-not $explicitLog) { $Log = Join-Path $LogDir (Expand-Name $redPat $vars) }

# Make sure the log directory is writable; fall back to %TEMP% if not.
$dir = Split-Path -Parent $Log
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
  $Log = Join-Path $env:TEMP (Split-Path $Log -Leaf)
  Write-Host "note: log directory is not writable; logging to $Log"
}

if (-not (Test-Path $File)) { throw "run-logged: script not found: $File" }

$argline = (@($Rest) | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$inner = ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" {1} 2>&1' -f $File, $argline).Trim()

# Raw capture, teed live to the console. When -Log was explicit, pair it as
# <base>.unredacted<ext> (old behavior); otherwise use the unredacted pattern so
# the redacted and raw logs share one stamp.
$rdir = Split-Path $Log -Parent; if (-not $rdir) { $rdir = (Get-Location).Path }
if ($explicitLog) {
  $rawlog = [IO.Path]::Combine($rdir, [IO.Path]::GetFileNameWithoutExtension($Log) + '.unredacted' + [IO.Path]::GetExtension($Log))
} else {
  $rawlog = Join-Path $rdir (Expand-Name $unredPat $vars)
}

& $env:ComSpec /c $inner | Tee-Object -FilePath $rawlog
$rc = $LASTEXITCODE

& (Join-Path $PSScriptRoot 'scrub-log.ps1') -Path $rawlog -Out $Log -Also $RedactAlso | Out-Null
Write-Host ""
Write-Host "run-logged: redacted log at $Log"
if ($keepRaw) {
  Write-Host "run-logged: unredacted log at $rawlog (keep private; git ignores it)"
} else {
  Remove-Item $rawlog -Force -ErrorAction SilentlyContinue
}
Write-Host ("run-logged: {0} exited {1}" -f (Split-Path $File -Leaf), $rc)
exit $rc
