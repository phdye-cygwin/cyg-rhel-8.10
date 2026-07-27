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
  [switch]$NoShortcut,
  [switch]$LogonTask,
  [switch]$DryRun,
  [switch]$NoCapture,
  [switch]$Unredacted,
  [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

# Load per-site settings if present (CYG_RHEL_ROOT / CYG_RHEL_SETUP_DIR and the
# log / redaction knobs), so running this from Explorer with no arguments still
# knows where the install goes.
$siteLocal = Join-Path $Here 'site-local.ps1'
if (Test-Path $siteLocal) { . $siteLocal }

# Read a boolean-ish environment value the way a person expects from EITHER
# background. In PowerShell [bool]'0' and [bool]'false' are both $true (any
# non-empty string is truthy); in POSIX shells `[ -n "$X" ]` is likewise true for
# "0" and "false". Both are traps. So only 1/true/yes/on (any case) mean set;
# 0/false/no/off/empty/unset mean clear. To turn a flag OFF, unset it or set 0.
function Test-EnvFlag {
  param($v)
  if ($null -eq $v) { return $false }
  return @('1','true','yes','on') -contains ($v.ToString().Trim().ToLowerInvariant())
}

# Switch knobs also honor site-local env, so a fully hands-off Explorer run can
# set them without a command line.
if (Test-EnvFlag $env:CYG_RHEL_NO_START)    { $NoStart     = $true }
if (Test-EnvFlag $env:CYG_RHEL_NO_DOWNLOAD) { $NoDownload  = $true }
if (Test-EnvFlag $env:CYG_RHEL_NO_PAUSE)    { $NoPause     = $true }
if (Test-EnvFlag $env:CYG_RHEL_NO_SHORTCUT) { $NoShortcut  = $true }
if (Test-EnvFlag $env:CYG_RHEL_LOGON_TASK)  { $LogonTask   = $true }

# Pause at the end so an Explorer double-click leaves the window open to read the
# result. Skipped when captured (the outer run owns the pause), non-interactive,
# or -NoPause / CYG_RHEL_NO_PAUSE.
function Invoke-EndPause {
  if ($NoPause -or $env:CYG_RHEL_CAPTURED) { return }
  if (-not [Environment]::UserInteractive) { return }
  try { Read-Host 'Install finished. Press Enter to close this window' | Out-Null } catch {}
}

# Self-capture. Unless -NoCapture, or already inside a capture, re-run this script
# through run-logged so the whole run - native and Cygwin children included - is
# logged, redacted by default. This is what lets "Run with PowerShell" from
# Explorer do everything and still leave a shareable log. run-logged owns the log
# name (built from the configured stamp), so no -Log is passed.
if (-not $NoCapture -and -not $env:CYG_RHEL_CAPTURED) {
  $capAlso = @(); if ($env:CYG_RHEL_REDACT_ALSO) { $capAlso = $env:CYG_RHEL_REDACT_ALSO -split '\s*[,;]\s*' }
  # Forward the original parameters, minus -Log (run-logged owns the log),
  # -NoCapture (would defeat the re-run), and the pause/redaction knobs the outer
  # run handles here.
  $fwd = @()
  foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    if ($kv.Key -in 'Log','NoCapture','Unredacted','NoPause') { continue }
    if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
      if ($kv.Value.IsPresent) { $fwd += "-$($kv.Key)" }
    } else { $fwd += "-$($kv.Key)"; $fwd += [string]$kv.Value }
  }
  if ($NoPause) { $fwd += '-NoPause' }
  $rlParams = @{ RedactAlso = $capAlso; File = (Join-Path $Here 'install-all.ps1') }
  if ($Unredacted) { $rlParams['Unredacted'] = $true }
  $env:CYG_RHEL_CAPTURED = '1'
  & (Join-Path $Here 'bin\run-logged.ps1') @rlParams -NoCapture @fwd
  $code = $LASTEXITCODE
  # This is the console-owning process (the one Explorer launched); pause here
  # regardless of the CYG_RHEL_CAPTURED flag it just set for the child.
  if (-not $NoPause -and [Environment]::UserInteractive) {
    try { Read-Host 'Install finished. Press Enter to close this window' | Out-Null } catch {}
  }
  exit $code
}

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
# Precedence per the CLI convention: option, then environment, then default.
# CYG_RHEL_ROOT / CYG_RHEL_SETUP_DIR let a site set the install location once
# for the whole tool family without a path living in the repo.
if (-not $Root   -and $env:CYG_RHEL_ROOT)       { $Root   = $env:CYG_RHEL_ROOT }
if (-not $PkgDir -and $env:CYG_RHEL_SETUP_DIR)  { $PkgDir = $env:CYG_RHEL_SETUP_DIR }
if (-not $Base   -and $env:CYG_RHEL_BASE)       { $Base   = $env:CYG_RHEL_BASE }
if (-not $PSBoundParameters.ContainsKey('Snapshot') -and $env:CYG_RHEL_SNAPSHOT) { $Snapshot = $env:CYG_RHEL_SNAPSHOT }
if (-not $Packages -and $env:CYG_RHEL_PACKAGES) { $Packages = $env:CYG_RHEL_PACKAGES }
if (-not $Base) {
  if ($Root) { $Base = [IO.Path]::GetDirectoryName($Root) } else { $Base = 'C:\cyg-rhel-8.10' }
}
if (-not $Root)   { $Root = [IO.Path]::Combine($Base, 'cygwin64') }
if (-not $PkgDir) { $PkgDir = [IO.Path]::Combine($Base, 'packages') }
if (-not $Packages) {
  $Packages = 'bash,coreutils,sed,gawk,grep,findutils,diffutils,patch,tar,gzip,bzip2,xz,which,less,procps-ng,util-linux,ncurses,zlib,rpm,gcc-core,gcc-g++,make,autoconf,automake,libtool,flex,bison,binutils,gdb,pkg-config,perl,python36,python3,openssh,openssl,curl,wget,rsync,git,vim,nano,mintty,tcsh,cygrunsrv,csih,cron,cygport,cpio,alternatives,editrights,getent,file,m4,texinfo,patchutils,libdb-devel,libpcre-devel,libpcre2-devel,libssl-devel,libsasl2-devel,libsqlite3-devel,libmysqlclient-devel,libpq-devel,libpq5,openldap-devel,libintl-devel,gettext-devel,zlib-devel,libiconv-devel'
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
  Invoke-EndPause
  exit 1
}

# Resolve which setup-x86_64.exe to use: explicit, else already in the package
# dir, else the newest found locally (copied in), else downloaded.
$import = $null; $download = $null
if (-not $SetupExe) {
  $intended = [IO.Path]::Combine($PkgDir, 'setup-x86_64.exe')
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
  Write-Host "== preflight: reap any postfix left running under $Root =="
  Write-Host "  bin/stop-tree-postfix.ps1 -Root $Root"
  Write-Host "== phase 2: configure inside $Root via its own bash =="
  Write-Host "  bin/install-packages.sh"
  Write-Host "  bin/postfix-user-setup.sh"
  Write-Host "  bin/postfix-user-launch.sh stop"
  if (-not $NoStart) { Write-Host "== phase 3: start the MTA (detached) =="; Write-Host "  bin/start-tree-postfix.ps1 -Root $Root" }
  if (-not $NoShortcut) { Write-Host "then: install-mintty-shortcut.ps1 -Root $Root -Base $Base (mintty shortcut + project icon)" }
  if ($LogonTask) { Write-Host "then: install-logon-task.ps1" }
  Stop-Log
  Invoke-EndPause
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

  # Reap any Postfix still running from a previous install of this tree. A stray
  # master holds port 25 and its files, which would break both the re-install and
  # a clean start; it is also what turned an earlier hung run into a cascade of
  # openpty failures. Scoped to $Root by full image path, so another tree's (or a
  # service's) postfix is left alone.
  if (Test-Path $NewBash) {
    & (Join-Path $Here 'bin\stop-tree-postfix.ps1') -Root $Root
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

  # Phase 2: a bash runner (config + reap only, no daemon) executed by the NEW
  # tree's bash. REPO is baked in as a Windows path and converted with the new
  # tree's own cygpath. It starts nothing that lingers, so -Wait on it is safe;
  # the MTA is started separately and detached in phase 3. Output goes to a plain
  # log file that this side prints after the phase.
  $tmp = Join-Path $Root 'tmp'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $runnerWin = Join-Path $tmp 'install-all-mta.sh'
  $mtaLog    = Join-Path $tmp 'install-all-mta.log'
  $runner = @"
#!/bin/bash
set -e
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
exec >/tmp/install-all-mta.log 2>&1
REPO=`$(cygpath -u '$Here')
"`$REPO/bin/install-packages.sh"
"`$REPO/bin/postfix-user-setup.sh"
"`$REPO/bin/postfix-user-launch.sh" stop
echo "install-all: config phase done"
"@
  [IO.File]::WriteAllText($runnerWin, ($runner -replace "`r`n","`n"))

  Write-Host "== phase 2: install and configure the MTA inside the new tree =="
  $p2 = Start-Process -FilePath $NewBash -ArgumentList $runnerWin -Wait -NoNewWindow -PassThru
  if (Test-Path $mtaLog) { Write-Host "-- phase-2 runner log --"; Get-Content $mtaLog }
  if ($p2.ExitCode -ne 0) {
    throw "MTA config phase failed inside the new tree (exit $($p2.ExitCode))"
  }

  # Phase 3: start the MTA detached and console-less (Win32_Process.Create). Doing
  # this inside the -Wait'd phase-2 runner is what hung every prior attempt: the
  # daemon held the run's console/pty and nothing after "phase done" returned.
  # Here the run never waits on the daemon; the helper polls master.pid instead.
  if (-not $NoStart) {
    Write-Host "== phase 3: start the MTA (detached) =="
    & (Join-Path $Here 'bin\start-tree-postfix.ps1') -Root $Root
  }

  if (-not $NoShortcut) {
    # Stage the project icon to a stable path in the tree (survives a rebuild),
    # then make the shortcut, which picks it up. If the repo has no icon yet, the
    # helper falls back to mintty's own icon - the shortcut still gets created.
    $icoSrc = Join-Path $Here 'share\rhel-cygwin.ico'
    if (Test-Path $icoSrc) {
      $icoDst = [IO.Path]::Combine($Root, 'usr\share\rhel-cygwin.ico')
      New-Item -ItemType Directory -Force -Path (Split-Path $icoDst) | Out-Null
      Copy-Item -Force $icoSrc $icoDst
    }
    & (Join-Path $Here 'bin\install-mintty-shortcut.ps1') -Root $Root -Base $Base
  }
  if ($LogonTask) { & (Join-Path $Here 'bin\install-logon-task.ps1') }

  Write-Host "install-all: done. Replica at $Root"

# When logging, fold the native children's own output into the transcript so the
# captured log is as complete as `script` would be.
if ($Log) {
  $sl = [IO.Path]::Combine($Root, 'var\log\setup.log.full')
  if (Test-There $sl)     { Write-Host "-- setup.log.full (tail) --"; Get-Content $sl -Tail 40 -ErrorAction SilentlyContinue }
}
Stop-Log
Invoke-EndPause
