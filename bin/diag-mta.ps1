<#
Diagnose an install-all phase-2 hang and inventory the Python interpreters on
this box. Run it in a second window while a run is stuck. It only reads state
(processes, fds, versions, the runner log) and changes nothing, and it self-logs
so the log can be shipped back.

  powershell -NoProfile -ExecutionPolicy Bypass -File bin\diag-mta.ps1

The log lands in %TEMP% (C:\ root is often not writable to a standard user); the
path is printed at the top and bottom.
#>
param(
  [string]$Root = 'C:\-\rhel\root',
  [string]$Log  = ''
)

if (-not $Log) { $Log = Join-Path $env:TEMP ('diag-mta-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
try { Start-Transcript -Path $Log -Force -ErrorAction Stop | Out-Null; Write-Host "logging to $Log" }
catch { $Log = Join-Path $env:TEMP ('diag-mta-' + $PID + '.log'); Start-Transcript -Path $Log -Force -ErrorAction SilentlyContinue | Out-Null; Write-Host "logging to $Log" }

$bash = Join-Path $Root 'bin\bash.exe'
function Section($t) { Write-Host ''; Write-Host ('==== ' + $t + ' ====') }

Section 'host / date'
Write-Host ("date : {0}" -f (Get-Date -Format o))
Write-Host ("host : {0} / {1}" -f $env:COMPUTERNAME, $env:USERNAME)
Write-Host ("root : {0}   bash present: {1}" -f $Root, (Test-Path $bash))

Section 'phase-2 runner log tail (shows how far phase 2 got)'
$mta = Join-Path $Root 'tmp\install-all-mta.log'
if (Test-Path $mta) { Get-Content $mta -Tail 40 -ErrorAction SilentlyContinue } else { Write-Host "no $mta" }

Section 'python interpreters'
try { & py -0p 2>&1 | ForEach-Object { Write-Host ("py -0p: " + $_) } } catch { Write-Host "py launcher: not found" }
foreach ($p in @('C:\Program Files\Python313\python.exe','C:\Python314\python.exe','C:\Python313\python.exe','C:\Program Files\Python312\python.exe')) {
  if (Test-Path $p) { Write-Host ("native: {0}  ->  {1}" -f $p, (& $p --version 2>&1)) }
}
if (Test-Path $bash) { Write-Host ("cygwin : " + (& $bash -lc 'python3 --version 2>&1; command -v python3')) }

Section 'postfix processes under root (native, full image path)'
$names = 'master','pickup','qmgr','cleanup','smtpd','postscreen','tlsproxy','local','virtual','lmtp','bounce','trivial-rewrite','anvil','scache','tlsmgr','postlogd'
$hit = Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -and $_.Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase) -and
  ($_.Name -in $names -or $_.Path -like '*\usr\libexec\postfix\*')
}
if ($hit) { $hit | ForEach-Object { Write-Host ("  pid {0,-7} {1}" -f $_.Id, $_.Path) } } else { Write-Host "  none" }

Section 'master pid + open fds (from the new tree)'
if (Test-Path $bash) {
  & $bash -lc 'p=$(tr -dc 0-9 < /var/spool/postfix/pid/master.pid 2>/dev/null); echo "master.pid = $p"; if [ -n "$p" ]; then echo "--- /proc/$p/fd ---"; ls -l /proc/$p/fd 2>&1; else echo "no master.pid"; fi'
}

Section 'process tree (ps -efW)'
if (Test-Path $bash) {
  & $bash -lc 'ps -efW 2>/dev/null | grep -Ei "master|smtpd|pickup|qmgr|bash|dash|tee|powershell|script|python" | grep -v grep'
}

Section 'done'
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
Write-Host "log written to $Log"
