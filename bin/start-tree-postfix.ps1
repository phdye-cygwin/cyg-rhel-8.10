<#
.SYNOPSIS
  Start the unprivileged Postfix master in a replica tree, fully detached, and
  wait for it to report running.

.DESCRIPTION
  The daemon is launched with WMI Win32_Process.Create, which gives it no console
  and no inherited handles. That matters: a -NoNewWindow or -Wait launch lets the
  daemon hold the caller's console/pty, which hangs an install captured under
  `script`; a new hidden console is worse still, because closing it when the
  launcher exits kills the daemon. Console-less is the only launch that both frees
  the caller and keeps the daemon alive. Readiness is confirmed by polling
  master.pid via postfix-user-launch.sh, not by waiting on the process.

.PARAMETER Root
  Replica tree root (its bash and postfix live here).

.PARAMETER Config
  Postfix config dir to pass through as -c. Default: the launch script's own
  default (/etc/postfix).

.PARAMETER TimeoutSec
  Seconds to wait for master to report running. Default 20.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Root,
  [string]$Config = '',
  [int]$TimeoutSec = 20
)

$bash = Join-Path $Root 'bin\bash.exe'
if (-not (Test-Path $bash)) { throw "start-tree-postfix: no bash at $bash" }

# Unset HOME so the replica's bash resolves it from its own /etc/passwd rather
# than inheriting the primary Cygwin's home (whose .bash_profile references
# things that don't exist in the replica). With HOME clear, -l sources the
# replica's /etc/profile for PATH and finds no user profile on a fresh tree.
$savedHome = $env:HOME
try { Remove-Item Env:HOME -ErrorAction SilentlyContinue } catch {}

$launchWin = Join-Path $PSScriptRoot 'postfix-user-launch.sh'
$launchU = (& $bash -lc "cygpath -u '$launchWin'").Trim()

$startScript  = if ($Config) { "'$launchU' -c '$Config' start" }  else { "'$launchU' start" }
$statusScript = if ($Config) { "'$launchU' -c '$Config' status" } else { "'$launchU' status" }

$cmd = ('"{0}" -lc "{1}"' -f $bash, $startScript)
$res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
if ($res.ReturnValue -ne 0) {
  if ($savedHome) { $env:HOME = $savedHome }
  throw "start-tree-postfix: Win32_Process.Create returned $($res.ReturnValue) launching the MTA"
}

$ok = $false
for ($i = 0; $i -lt $TimeoutSec; $i++) {
  Start-Sleep -Seconds 1
  $st = (& $bash -lc $statusScript 2>&1) -join ' '
  if ($st -match 'running') { $ok = $true; Write-Host "MTA: $st"; break }
}
if (-not $ok) {
  Write-Host "start-tree-postfix: MTA did not report running within ${TimeoutSec}s"
  (& $bash -lc $statusScript 2>&1) | ForEach-Object { Write-Host "  $_" }
  (& $bash -lc "tail -15 /var/log/maillog 2>/dev/null") | ForEach-Object { Write-Host "  $_" }
  if ($savedHome) { $env:HOME = $savedHome }
  throw "start-tree-postfix: MTA failed to start"
}

if ($savedHome) { $env:HOME = $savedHome }
