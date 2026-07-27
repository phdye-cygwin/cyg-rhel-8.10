<#
.SYNOPSIS
  Run a PowerShell script with COMPLETE output capture - its own streams and
  every child's, native and Cygwin - and write a redacted log by default.

.DESCRIPTION
  Start-Transcript captures only PowerShell's own streams, so a native child
  (setup-x86_64.exe, the tree's bash) that writes straight to the console is
  missed; that is why a transcript logs less than Cygwin `script`. This runs the
  target as a child process whose stdout and stderr cmd merges at the byte level,
  tees the raw output live to the console, then scrubs it into the log at -Log.

  The -Log file is REDACTED (host, user, domain, profile path masked) so it is
  safe to share. The full, unredacted capture is written only with -Unredacted,
  to a sibling file with "unredacted" in its name (which .gitignore excludes).

.PARAMETER Log
  The redacted log to write. If its directory is not writable, falls back to
  %TEMP%.

.PARAMETER File
  The .ps1 to run.

.PARAMETER Unredacted
  Also keep the raw capture, at <name>.unredacted<ext> beside -Log.

.PARAMETER RedactAlso
  Extra literal strings to mask (e.g. a Cygwin username that differs from the
  Windows one).

.PARAMETER Rest
  Remaining arguments, passed through to the script.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Log,
  [Parameter(Mandatory=$true)][string]$File,
  [switch]$Unredacted,
  [string[]]$RedactAlso = @(),
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

# Raw capture goes to the .unredacted sibling and is teed live to the console;
# the default -Log is the redacted copy, produced from it after the run.
$rdir = Split-Path $Log -Parent; if (-not $rdir) { $rdir = (Get-Location).Path }
$rawlog = [IO.Path]::Combine($rdir, [IO.Path]::GetFileNameWithoutExtension($Log) + '.unredacted' + [IO.Path]::GetExtension($Log))

& $env:ComSpec /c $inner | Tee-Object -FilePath $rawlog
$rc = $LASTEXITCODE

& (Join-Path $PSScriptRoot 'scrub-log.ps1') -Path $rawlog -Out $Log -Also $RedactAlso | Out-Null
Write-Host ""
Write-Host "run-logged: redacted log at $Log"
if ($Unredacted) {
  Write-Host "run-logged: unredacted log at $rawlog (keep private; git ignores it)"
} else {
  Remove-Item $rawlog -Force -ErrorAction SilentlyContinue
}
Write-Host ("run-logged: {0} exited {1}" -f (Split-Path $File -Leaf), $rc)
exit $rc
