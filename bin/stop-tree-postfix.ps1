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

foreach ($p in $targets) {
  try   { $p.Kill(); Write-Host ("reap: stopped {0} (pid {1})" -f $p.Name, $p.Id) }
  catch { Write-Host ("reap: could not stop pid {0}: {1}" -f $p.Id, $_.Exception.Message) }
}
Start-Sleep -Milliseconds 500
