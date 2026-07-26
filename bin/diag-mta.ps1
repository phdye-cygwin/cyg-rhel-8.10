<#
.SYNOPSIS
  Read-only probe for an install-all phase-2 hang, with a Python interpreter
  inventory. Run it in a second window while a run is stuck.

.DESCRIPTION
  Changes nothing. The report goes to stdout so a script/tee/redirect wrapper
  captures it; -Out writes an extra copy to a file. Invoke with the call
  operator so PowerShell runs the script instead of printing its name:
      & .\diag-mta.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\diag-mta.ps1

.PARAMETER Root
  Replica tree root to inspect. Default C:\cyg-rhel-8.10\cygwin64.

.PARAMETER Out
  Optional file to also receive the report.

.PARAMETER Help
  Show usage and exit. Also accepts -h and --help.
#>
[CmdletBinding()]
param(
  [Alias('h')]
  [switch]$Help,
  [string]$Root = 'C:\cyg-rhel-8.10\cygwin64',
  [string]$Out  = '',
  [Parameter(ValueFromRemainingArguments=$true)]
  $Rest
)

function Show-Usage {
@'
diag-mta.ps1 - read-only probe for an install-all phase-2 hang.

Usage:
  & .\diag-mta.ps1 [-Root DIR] [-Out FILE] [-h | -Help]

Run it with the call operator (&) or `powershell -File`, in a second window
while an install is stuck. It reads process/fd state, tails the phase-2 runner
log, and inventories Python; it changes nothing. Output goes to stdout so a
script/tee/redirect wrapper captures it; -Out writes an extra copy to a file.

Options:
  -Root DIR   replica tree to inspect      [default: C:\cyg-rhel-8.10\cygwin64]
  -Out FILE   also write the report here
  -h, -Help   show this help and exit      (--help works too)
'@
}

# -Help / -h bind normally. --help (and a bare "help") is not a PowerShell
# parameter, so it lands positionally in $Root or in $Rest; catch it either way.
$helpTokens = @('--help','-help','-h','/?','/h','help')
if ($Help -or
    ($Rest | Where-Object { $helpTokens -contains $_ }) -or
    ($helpTokens -contains $Root) -or ($helpTokens -contains $Out)) {
  Show-Usage
  return
}

# Collect the report as strings, then emit to stdout (and -Out if given), so a
# capturing harness gets it. No Start-Transcript: it would hide the output in a
# temp file instead of stdout.
$lines = New-Object System.Collections.Generic.List[string]
function Emit($s) { $lines.Add([string]$s) }
function Section($t) { Emit ''; Emit ('==== ' + $t + ' ====') }

$bash = Join-Path $Root 'bin\bash.exe'

Section 'host / date'
Emit ("date : {0}" -f (Get-Date -Format o))
Emit ("host : {0} / {1}" -f $env:COMPUTERNAME, $env:USERNAME)
Emit ("root : {0}   bash present: {1}" -f $Root, (Test-Path $bash))

Section 'phase-2 runner log tail (how far phase 2 got)'
$mta = Join-Path $Root 'tmp\install-all-mta.log'
if (Test-Path $mta) { Get-Content $mta -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Emit $_ } } else { Emit "no $mta" }

Section 'python interpreters'
try { & py -0p 2>&1 | ForEach-Object { Emit ("py -0p: " + $_) } } catch { Emit "py launcher: not found" }
foreach ($p in @('C:\Program Files\Python313\python.exe','C:\Python314\python.exe','C:\Python313\python.exe','C:\Program Files\Python312\python.exe')) {
  if (Test-Path $p) { Emit ("native: {0}  ->  {1}" -f $p, (& $p --version 2>&1)) }
}
if (Test-Path $bash) { Emit ("cygwin : " + (& $bash -lc 'python3 --version 2>&1; command -v python3')) }

Section 'postfix processes under root (native, full image path)'
$names = 'master','pickup','qmgr','cleanup','smtpd','postscreen','tlsproxy','local','virtual','lmtp','bounce','trivial-rewrite','anvil','scache','tlsmgr','postlogd'
$hit = Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -and $_.Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase) -and
  ($_.Name -in $names -or $_.Path -like '*\usr\libexec\postfix\*')
}
if ($hit) { $hit | ForEach-Object { Emit ("  pid {0,-7} {1}" -f $_.Id, $_.Path) } } else { Emit "  none" }

Section 'master pid + open fds (from the new tree)'
if (Test-Path $bash) {
  (& $bash -lc 'p=$(tr -dc 0-9 < /var/spool/postfix/pid/master.pid 2>/dev/null); echo "master.pid = $p"; if [ -n "$p" ]; then echo "--- /proc/$p/fd ---"; ls -l /proc/$p/fd 2>&1; else echo "no master.pid"; fi' 2>&1) | ForEach-Object { Emit $_ }
}

Section 'process tree (ps -efW)'
if (Test-Path $bash) {
  (& $bash -lc 'ps -efW 2>/dev/null | grep -Ei "master|smtpd|pickup|qmgr|bash|dash|tee|powershell|script|python" | grep -v grep' 2>&1) | ForEach-Object { Emit $_ }
}

Section 'done'

$report = ($lines -join "`r`n")
Write-Output $report
if ($Out) {
  try { Set-Content -Path $Out -Value $report -Encoding ASCII -ErrorAction Stop; Write-Output "(report also written to $Out)" }
  catch { Write-Output "note: could not write -Out $Out : $($_.Exception.Message)" }
}
