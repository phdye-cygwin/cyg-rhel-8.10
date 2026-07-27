<#
Stop every Postfix process belonging to one replica tree, so a re-install or a
fresh start begins with nothing left over. Cygwin's own `ps` shows only
`/usr/libexec/postfix/master` with no arguments and no Windows path, so it can't
tell one tree's daemons from another's. Get-Process can: it sees the full image
path, and the daemons all live under <root>\usr\libexec\postfix. Match on that
path (authoritative), and also on the known daemon names scoped to the tree in
case a process reports no path.

This is a hard stop (TerminateProcess). That is fine here: it runs before the
tree is rebuilt or before a clean start, and postfix-user-launch.sh clears the
stale master.pid / master.lock afterward.
#>
param([Parameter(Mandatory=$true)][string]$Root)

$root = $Root.TrimEnd('\','/')
$pfx  = Join-Path $root 'usr\libexec\postfix'
$ic   = [System.StringComparison]::OrdinalIgnoreCase

$names = @('master','pickup','qmgr','oqmgr','cleanup','smtpd','postscreen','tlsproxy',
           'local','virtual','lmtp','pipe','spawn','error','discard','bounce','defer',
           'flush','trace','verify','proxymap','proxywrite','trivial-rewrite','anvil',
           'scache','tlsmgr','postlogd','dnsblog','showq')

$targets = Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -and (
    $_.Path.StartsWith($pfx, $ic) -or
    ($_.Name -in $names -and $_.Path.StartsWith($root, $ic))
  )
}

if (-not $targets) { Write-Host "reap: no postfix processes under $root"; return }

# Resolve the owning account for a pid, so an un-killable leftover names its token.
# An "Access is denied" on Kill almost always comes down to that: a daemon left by
# an elevated or service context the current run can't terminate. Best-effort - the
# owner query can itself be refused, in which case '?'.
function Get-OwnerString([int]$id) {
  try {
    $cp = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
    if ($cp) {
      $o = Invoke-CimMethod -InputObject $cp -MethodName GetOwner -ErrorAction Stop
      if ($o -and $o.User) { return ('{0}\{1}' -f $o.Domain, $o.User) }
    }
  } catch {}
  return '?'
}

# The pid here is the Windows (OS) pid - the WINPID column in Cygwin `ps -W`, not a
# Cygwin pid. Log it with the image path and owner so a process is identifiable
# from the log alone; a bare pid is recycled and useless after the fact.
$failed = @()
foreach ($p in $targets) {
  $desc = "{0} winpid {1} owner {2} path {3}" -f $p.Name, $p.Id, (Get-OwnerString $p.Id), $p.Path
  try   { $p.Kill(); Write-Host "reap: stopped $desc" }
  catch { Write-Host "reap: COULD NOT STOP $desc"; Write-Host ("       reason: {0}" -f $_.Exception.Message); $failed += $desc }
}
Start-Sleep -Milliseconds 500

if ($failed.Count) {
  Write-Host ""
  Write-Host ("reap: WARNING - {0} leftover process(es) under {1} could not be stopped," -f $failed.Count, $root)
  Write-Host  "      likely a different or elevated token. Identify with: bin\identify-proc.ps1 -Root $root"
  foreach ($d in $failed) { Write-Host "        $d" }
}
