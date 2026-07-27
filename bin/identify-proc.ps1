<#
.SYNOPSIS
  Identify a process by its Windows pid, or list every live process running from a
  Cygwin tree, with image path and owning account.

.DESCRIPTION
  The reaper and Task Manager report an OS pid - a Windows pid, not a Cygwin pid,
  and pids are recycled - so a bare number is a poor handle. This resolves a pid to
  its image path, command line, owner, and session; or, given a root, sweeps every
  process whose image lives under it (the durable way to find a leftover, since it
  does not depend on a number that may already be gone).

  The pid this reports is the WINPID column in a Cygwin `ps -W`. A process from one
  Cygwin root shows up in another root's `ps -W` as a plain Windows process, with
  the same path you see here.

.PARAMETER Id
  A Windows pid to resolve.

.PARAMETER Root
  A Cygwin root; list every live process whose image is under it. Used when -Id is
  not given; defaults to CYG_RHEL_ROOT.

.EXAMPLE
  bin\identify-proc.ps1 -Id 6892
.EXAMPLE
  bin\identify-proc.ps1 -Root C:\-\rhel\root
#>
[CmdletBinding()]
param(
  [int]$Id = 0,
  [string]$Root = '',
  [Alias('h')][switch]$Help,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)

# --help arrives as a bare token (PowerShell can't bind '--help' to a switch), so
# catch the usual help spellings from whatever landed in $Rest or -Root too.
$helpWanted = $Help -or ((@($Rest) + @($Root)) | Where-Object { $_ -match '^(--help|-help|help|/\?|-\?)$' })
if ($helpWanted) {
@'
identify-proc.ps1 - resolve a Windows pid, or list a Cygwin tree's processes.

  identify-proc.ps1 -Id <pid>        show path, command line, owner, session
  identify-proc.ps1 -Root <root>     list every live process under that root
  identify-proc.ps1                  same, using CYG_RHEL_ROOT

The pid is the OS/Windows pid (the WINPID in Cygwin `ps -W`), not a Cygwin pid.
'@ | Write-Output
  return
}

function Get-OwnerString($cp) {
  try {
    $o = Invoke-CimMethod -InputObject $cp -MethodName GetOwner -ErrorAction Stop
    if ($o -and $o.User) { return ('{0}\{1}' -f $o.Domain, $o.User) }
  } catch {}
  return '?'
}

function Show-Proc($cp) {
  Write-Output ("winpid {0}  session {1}  owner {2}" -f $cp.ProcessId, $cp.SessionId, (Get-OwnerString $cp))
  Write-Output ("  path: {0}" -f $cp.ExecutablePath)
  if ($cp.CommandLine) { Write-Output ("  cmd : {0}" -f $cp.CommandLine) }
}

if ($Id -gt 0) {
  $cp = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
  if ($cp) { Show-Proc $cp }
  else { Write-Output "winpid $Id is not live (it exited, or the pid was recycled)." }
  return
}

if (-not $Root) { $Root = $env:CYG_RHEL_ROOT }
if (-not $Root) { Write-Output "give -Id <pid> or -Root <cygwin root> (or set CYG_RHEL_ROOT). -Help for usage."; return }

$pfx = $Root.TrimEnd('\','/') + '\'
$hits = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($pfx, [System.StringComparison]::OrdinalIgnoreCase) }
if (-not $hits) { Write-Output "no live processes under $Root"; return }
Write-Output ("processes under {0}:" -f $Root)
foreach ($cp in $hits) { Show-Proc $cp }
