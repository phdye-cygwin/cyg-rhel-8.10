<#
One-shot installer for the RHEL 8.10 Cygwin replica that needs NO existing
Cygwin. Run from Windows PowerShell (or via install-all.cmd), no admin.

Phase 1 runs setup-x86_64.exe (a native program) with --no-admin to build the
tree; if no setup-x86_64.exe is found locally it downloads one. Phase 2 launches
the new tree's own bash to install and start the MTA -- safe, because PowerShell
is a native parent, so there is no cygwin1.dll collision and no cmd bridge.

Any failure prints layered diagnostics: what was attempted, the environment, and
the tail of setup.log.full or the phase-2 runner log, so a failed run can be
reported without a second round of questions.
#>
param(
  [string]$Base      = '',
  [string]$Root      = '',
  [Alias('SetupDir')]
  [string]$PkgDir    = '',
  [string]$SetupExe  = '',
  [string]$SetupUrl  = 'https://cygwin.com/setup-x86_64.exe',
  [string]$Snapshot  = 'http://ctm.crouchingtigerhiddenfruitbat.org/pub/cygwin/circa/64bit/2019/08/01/131636',
  [string]$Packages  = '',
  [string]$Log       = '',
  [switch]$NoDownload,
  [switch]$NoStart,
  [switch]$Shortcut,
  [switch]$LogonTask,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

# -Log is the PowerShell analog of Cygwin's `script`: transcribe everything to a
# file. A transcript can miss a native child's own console output, so on the way
# out we also fold in setup.log.full and the phase-2 runner log (see Stop-Log and
# the end of the run), making the capture complete.
function Stop-Log {
  if ($Log) {
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    if (-not (Test-Path $Log)) {
      Write-Host "note: -Log was requested but no file appeared at $Log; capture with Cygwin 'script' instead."
    }
  }
}
if ($Log) {
  # Pick a writable path up front by actually probe-writing the target dir.
  # Start-Transcript is not a reliable signal: on a protected path (C:\ root,
  # C:\Windows) it can report success and write nothing. If the target is not
  # writable, redirect to TEMP so a run always leaves a capture.
  $logDir = [IO.Path]::GetDirectoryName($Log); if (-not $logDir) { $logDir = (Get-Location).Path }
  $canWrite = $false
  try {
    New-Item -ItemType Directory -Force -Path $logDir -ErrorAction Stop | Out-Null
    $probe = Join-Path $logDir ('.logprobe-' + $PID)
    Set-Content -Path $probe -Value 'x' -ErrorAction Stop
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    $canWrite = $true
  } catch {}
  if (-not $canWrite) {
    $alt = Join-Path $env:TEMP ([IO.Path]::GetFileName($Log))
    Write-Host "note: -Log directory $logDir is not writable; logging to $alt instead"
    $Log = $alt
  }
  try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
  try { Start-Transcript -Path $Log -Force -ErrorAction Stop | Out-Null; Write-Host "logging to $Log" }
  catch { Write-Host "warning: could not start transcript at $Log ($($_.Exception.Message)); capture with Cygwin 'script' instead."; $Log = '' }
}

# Base is the primary knob: root and pkg-dir sit under it. An explicit -Root
# without -Base takes its base from the root's parent; otherwise the default
# base wins. Explicit -Root and -PkgDir always override.
# Use [IO.Path] rather than Join-Path/Split-Path: these are pure string ops, so
# a -Base on a drive that is not mounted yet still resolves (Join-Path checks
# the drive and throws).
if (-not $Base) {
  if ($Root) { $Base = [IO.Path]::GetDirectoryName($Root) } else { $Base = 'C:\cyg-rhel-8.10' }
}
if (-not $Root)   { $Root = [IO.Path]::Combine($Base, 'cygwin64') }
if (-not $PkgDir) { $PkgDir = [IO.Path]::Combine($Base, 'packages') }
if (-not $Packages) {
  $Packages = 'bash,coreutils,sed,gawk,grep,findutils,diffutils,patch,tar,gzip,bzip2,xz,which,less,procps-ng,util-linux,ncurses,zlib,rpm,gcc-core,gcc-g++,make,autoconf,automake,libtool,flex,bison,binutils,gdb,pkg-config,perl,python36,python3,openssh,openssl,curl,wget,rsync,git,vim,nano,tcsh,cygrunsrv,csih,cron,cygport,cpio,alternatives,editrights,getent,file,m4,texinfo,patchutils,libdb-devel,libpcre-devel,libpcre2-devel,libssl-devel,libsasl2-devel,libsqlite3-devel,libmysqlclient-devel,libpq-devel,libpq5,openldap-devel,libintl-devel,gettext-devel,zlib-devel,libiconv-devel'
}

$NewBash = [IO.Path]::Combine($Root, 'bin\bash.exe')

# Dump the environment facts that make a failure diagnosable from the log alone,
# including the tail of setup.log.full when it exists.
function Test-There([string]$p) { return ($p -and (Test-Path $p -ErrorAction SilentlyContinue)) }
function Write-Diag {
  $sl = if ($Root) { [IO.Path]::Combine($Root, 'var\log\setup.log.full') } else { '' }
  Write-Host "---- diagnostics (install-all.ps1) ----"
  Write-Host ("date       : {0}" -f (Get-Date -Format o))
  Write-Host ("host/user  : {0} / {1}" -f $env:COMPUTERNAME, $env:USERNAME)
  Write-Host ("PSVersion  : {0}" -f $PSVersionTable.PSVersion)
  Write-Host ("OS         : {0}" -f [Environment]::OSVersion.VersionString)
  Write-Host ("base       : {0}" -f $Base)
  Write-Host ("root       : {0}" -f $Root)
  Write-Host ("pkg-dir    : {0}" -f $PkgDir)
  Write-Host ("setup exe  : {0}  [{1}]" -f $SetupExe, $(if (Test-There $SetupExe) {'present'} else {'absent'}))
  Write-Host ("new bash   : {0}  [{1}]" -f $NewBash, $(if (Test-There $NewBash) {'present'} else {'absent'}))
  Write-Host ("setup.log  : {0}  [{1}]" -f $sl, $(if (Test-There $sl) {'present'} else {'absent'}))
  Write-Host "---------------------------------------"
  if (Test-There $sl) { Write-Host "-- tail of setup.log.full --"; Get-Content $sl -Tail 20 -ErrorAction SilentlyContinue }
}

# Confirm a directory can be created and written before we rely on it.
function Test-Writable([string]$dir) {
  try {
    New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    $t = Join-Path $dir ('.wtest-' + $PID)
    Set-Content -Path $t -Value 'x' -ErrorAction Stop
    Remove-Item $t -Force -ErrorAction SilentlyContinue
    return $true
  } catch { return $false }
}

function Find-SetupExe {
  $cands = @()
  $dirs = @((Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Desktop'),
            $env:USERPROFILE, $PkgDir)
  foreach ($k in @('HKCU:\Software\Cygwin\setup','HKLM:\Software\Cygwin\setup')) {
    try { $c = (Get-ItemProperty -Path $k -Name 'last-cache' -EA Stop).'last-cache'; if ($c) { $dirs += $c } } catch {}
  }
  foreach ($d in $dirs) {
    if ($d -and (Test-Path $d)) {
      $f = Join-Path $d 'setup-x86_64.exe'
      if (Test-Path $f) { $cands += Get-Item $f }
    }
  }
  if ($cands.Count -eq 0) { return $null }
  ($cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# Any terminating error from here on -- resolution, preflight, setup, phase 2 --
# lands here with layered diagnostics before exiting non-zero.
trap {
  Write-Host ""
  Write-Host "install-all: FAILED -- $($_.Exception.Message)"
  Write-Diag
  Stop-Log
  exit 1
}

# Resolve which setup-x86_64.exe to use: explicit, else already in the package
# dir, else the newest found locally (copied in), else downloaded.
$import = $null; $download = $null
if (-not $SetupExe) {
  $intended = Join-Path $PkgDir 'setup-x86_64.exe'
  if (Test-Path $intended) { $SetupExe = $intended }
  else {
    $found = Find-SetupExe
    if ($found) { $import = $found; $SetupExe = $intended }
    elseif (-not $NoDownload) { $download = $SetupUrl; $SetupExe = $intended }
    else { throw "no setup-x86_64.exe found; put one in $PkgDir, pass -SetupExe, or drop -NoDownload" }
  }
}

# -O (--only-site) pins setup to the snapshot and skips the mirror list; without
# it, older setup can fall back to an empty mirror list and select zero packages
# even when the snapshot is reachable.
$setupArgs = @('-q','-X','-O','-n','-d','-N','--no-admin','-R',$Root,'-s',$Snapshot,'-l',$PkgDir,'-P',$Packages)

if ($DryRun) {
  Write-Host "== phase 1: install the tree =="
  Write-Host "setup exe : $SetupExe"
  if ($import)   { Write-Host "would copy : $import" }
  if ($download) { Write-Host "would download: $download" }
  Write-Host ("would run : {0} {1}" -f $SetupExe, ($setupArgs -join ' '))
  Write-Host "== phase 2: run inside $Root via its own bash =="
  Write-Host "  bin/install-packages.sh"
  Write-Host "  bin/postfix-user-setup.sh"
  if (-not $NoStart) { Write-Host "  bin/postfix-user-launch.sh start" }
  if ($Shortcut)  { Write-Host "then: install-mintty-shortcut.ps1 -Base $Base" }
  if ($LogonTask) { Write-Host "then: install-logon-task.ps1" }
  Stop-Log
  exit 0
}

# Preflight: catch the cheap, common failures before the multi-minute setup run.
if (-not (Test-Writable $PkgDir)) {
    throw "package dir is not writable: $PkgDir  (pick another -PkgDir or -Base)"
  }
  $rootParent = [IO.Path]::GetDirectoryName($Root)
  if ($rootParent -and -not (Test-Writable $rootParent)) {
    throw "the root's parent is not writable: $rootParent  (pick another -Root or -Base)"
  }

  New-Item -ItemType Directory -Force -Path $PkgDir | Out-Null
  $dest = Join-Path $PkgDir 'setup-x86_64.exe'
  if ($import)   { Copy-Item -Force $import $dest; Write-Host "imported setup: $import" }
  if ($download) { Write-Host "downloading setup from $download"; Invoke-WebRequest -Uri $download -OutFile $dest -UseBasicParsing }
  if (-not (Test-Path $SetupExe)) { throw "setup program not found: $SetupExe" }

  # The setup must be a real Windows program. A proxy error page or a truncated
  # download would fail to launch; catch it here with a clear message.
  $fi = Get-Item $SetupExe
  $mz = [System.IO.File]::ReadAllBytes($SetupExe) | Select-Object -First 2
  if ($fi.Length -lt 100000 -or $mz[0] -ne 0x4D -or $mz[1] -ne 0x5A) {
    throw "setup-x86_64.exe is not a valid Windows program (size=$($fi.Length) bytes, header=$($mz -join ',') want 77,90=MZ); a proxy page or partial download? point -SetupExe at a known-good copy"
  }

  # Strip the mark-of-the-web. A downloaded exe carries a Zone.Identifier that
  # SmartScreen / some policies refuse to launch ("Access is denied"); removing
  # it clears that class of block. Harmless when there is no tag.
  try { Unblock-File -LiteralPath $SetupExe -ErrorAction SilentlyContinue } catch {}

  # Reachability preflight: setup pulls its package index from the snapshot
  # mirror. That host is often blocked by corporate web filtering, so warn early
  # -- otherwise a later "0 packages" result looks like a mystery.
  try {
    Invoke-WebRequest -Uri "$Snapshot/x86_64/setup.xz" -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null
  } catch {
    Write-Host "warning: snapshot mirror not reachable ($Snapshot)"
    Write-Host "         reason: $($_.Exception.Message)"
    Write-Host "         unless packages are already staged in $PkgDir, setup will install nothing."
  }

  Write-Host "== phase 1: install the Cygwin tree (no admin) =="
  try {
    $p = Start-Process -FilePath $SetupExe -ArgumentList $setupArgs -Wait -NoNewWindow -PassThru
  } catch {
    throw ("could not launch setup ($($_.Exception.Message)). On a managed machine this is " +
           "application control (AppLocker/WDAC) or SmartScreen refusing a downloaded exe. Try: " +
           "Unblock-File '$SetupExe' then re-run; if still blocked, pass -SetupExe pointing at a " +
           "setup-x86_64.exe your IT already allows, such as the one bundled with the Cygwin " +
           "already installed on this machine.")
  }
  if ($p.ExitCode -ne 0) { throw "setup exited $($p.ExitCode); see $Root\var\log\setup.log.full" }
  if (-not (Test-Path $NewBash)) {
    $sl = [IO.Path]::Combine($Root, 'var\log\setup.log.full')
    if ((Test-Path $sl) -and ((Get-Content $sl -Raw -ErrorAction SilentlyContinue) -match 'Visited: 0 nodes')) {
      $siteTried = (Get-Content $sl -Raw -ErrorAction SilentlyContinue) -match '(?m)^\s*site:'
      throw ("setup ran but selected 0 packages -- it never loaded the package index. " +
             (if ($siteTried) {
                "It reached a site but resolved nothing; the snapshot mirror $Snapshot may be " +
                "blocked or incomplete (confirm: Invoke-WebRequest '$Snapshot/x86_64/setup.xz' -Method Head). "
              } else {
                "Its log shows no 'site:' line, so this setup did a LOCAL install and never went to " +
                "the network -- typical of an older setup that ignores -s. "
              }) +
             "Fixes: use the current setup-x86_64.exe (delete the one in $PkgDir so it re-downloads), " +
             "or pre-stage the full package cache into $PkgDir and install offline.")
    } elseif (Test-Path $sl) {
      throw "setup ran but produced no tree; see $sl (tail in the diagnostics below)."
    } else {
      throw ("setup produced no tree and wrote no log: it likely could not launch (application " +
             "control/AppLocker) or faulted. Use -SetupExe with an IT-approved setup-x86_64.exe.")
    }
  }

  # Phase 2: a bash runner executed by the NEW tree's bash. REPO is baked in as a
  # Windows path and converted with the new tree's own cygpath. The runner sends
  # its output to a plain log file in the tree (not a tee pipe): the postfix
  # master it starts would inherit a process-substitution fd and hold it open,
  # so tee never sees EOF and Start-Process -Wait would hang forever. This side
  # prints the log after the phase instead.
  $tmp = Join-Path $Root 'tmp'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $runnerWin = Join-Path $tmp 'install-all-mta.sh'
  $mtaLog    = Join-Path $tmp 'install-all-mta.log'
  $startLine = if ($NoStart) { '' } else { '"$REPO/bin/postfix-user-launch.sh" start' }
  $runner = @"
#!/bin/bash
set -e
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
exec >/tmp/install-all-mta.log 2>&1
REPO=`$(cygpath -u '$Here')
"`$REPO/bin/install-packages.sh"
"`$REPO/bin/postfix-user-setup.sh"
$startLine
echo "install-all: MTA phase done"
"@
  [IO.File]::WriteAllText($runnerWin, ($runner -replace "`r`n","`n"))

  Write-Host "== phase 2: install and start the MTA inside the new tree =="
  $p2 = Start-Process -FilePath $NewBash -ArgumentList $runnerWin -Wait -NoNewWindow -PassThru
  if (Test-Path $mtaLog) { Write-Host "-- phase-2 runner log --"; Get-Content $mtaLog }
  if ($p2.ExitCode -ne 0) {
    throw "MTA phase failed inside the new tree (exit $($p2.ExitCode))"
  }

  if ($Shortcut)  { & (Join-Path $Here 'bin\install-mintty-shortcut.ps1') -Base $Base }
  if ($LogonTask) { & (Join-Path $Here 'bin\install-logon-task.ps1') }

  Write-Host "install-all: done. Replica at $Root"

# When logging, fold the native children's own output into the transcript so the
# captured log is as complete as `script` would be.
if ($Log) {
  $sl = [IO.Path]::Combine($Root, 'var\log\setup.log.full')
  if (Test-There $sl)     { Write-Host "-- setup.log.full (tail) --"; Get-Content $sl -Tail 40 -ErrorAction SilentlyContinue }
}
Stop-Log
