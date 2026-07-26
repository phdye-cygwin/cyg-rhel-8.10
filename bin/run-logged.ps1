<#
.SYNOPSIS
  Run a PowerShell script with COMPLETE output capture - its own streams and
  every child's, native and Cygwin - to the console and a log file at once.

.DESCRIPTION
  Start-Transcript captures only PowerShell's own streams, so a native child
  (setup-x86_64.exe, the tree's bash) that writes straight to the console is
  missed; that is why a transcript logs less than Cygwin `script`. This runs the
  target as a child process whose stdout and stderr are merged by cmd at the byte
  level (clean, no PowerShell error-record wrapping) and teed. The child and
  every process IT starts inherit that stdout, so their output is captured too.

.PARAMETER Log
  Log file. If its directory is not writable, falls back to %TEMP%.

.PARAMETER File
  The .ps1 to run.

.PARAMETER Rest
  Remaining arguments, passed through to the script.

.EXAMPLE
  run-logged.ps1 -Log C:\tmp\rhel-install.log -File .\install-all.ps1 -Root C:\-\rhel\root
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Log,
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)

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

& $env:ComSpec /c $inner | Tee-Object -FilePath $Log
$rc = $LASTEXITCODE
Write-Host ""
Write-Host ("run-logged: {0} exited {1}; full log at {2}" -f (Split-Path $File -Leaf), $rc, $Log)
exit $rc
