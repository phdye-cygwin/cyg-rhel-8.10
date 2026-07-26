<#
One-shot installer for the RHEL 8.10 Cygwin replica that needs NO existing
Cygwin. Run from Windows PowerShell (or via install-all.cmd), no admin.

Phase 1 runs setup-x86_64.exe (a native program) with --no-admin to build the
tree; if no setup-x86_64.exe is found locally it downloads one. Phase 2 launches
the new tree's own bash to install and start the MTA -- safe, because PowerShell
is a native parent, so there is no cygwin1.dll collision and no cmd bridge.
#>
param(
  [string]$Root      = 'C:\cyg-rhel-8.10\cygwin64',
  [string]$SetupDir  = '',
  [string]$SetupExe  = '',
  [string]$SetupUrl  = 'https://cygwin.com/setup-x86_64.exe',
  [string]$Snapshot  = 'http://ctm.crouchingtigerhiddenfruitbat.org/pub/cygwin/circa/64bit/2019/08/01/131636',
  [string]$Packages  = '',
  [switch]$NoDownload,
  [switch]$NoStart,
  [switch]$Shortcut,
  [switch]$LogonTask,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

if (-not $SetupDir) { $SetupDir = Join-Path (Split-Path $Root -Parent) 'packages' }
if (-not $Packages) {
  $Packages = 'bash,coreutils,sed,gawk,grep,findutils,diffutils,patch,tar,gzip,bzip2,xz,which,less,procps-ng,util-linux,ncurses,zlib,rpm,gcc-core,gcc-g++,make,autoconf,automake,libtool,flex,bison,binutils,gdb,pkg-config,perl,python36,python3,openssh,openssl,curl,wget,rsync,git,vim,nano,tcsh,cygrunsrv,csih,cron,cygport,cpio,alternatives,editrights,getent,file,m4,texinfo,patchutils,libdb-devel,libpcre-devel,libpcre2-devel,libssl-devel,libsasl2-devel,libsqlite3-devel,libmysqlclient-devel,libpq-devel,libpq5,openldap-devel,libintl-devel,gettext-devel,zlib-devel,libiconv-devel'
}

function Find-SetupExe {
  $cands = @()
  $dirs = @((Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Desktop'),
            $env:USERPROFILE, $SetupDir)
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

# Resolve which setup-x86_64.exe to use: explicit, else already in the setup
# dir, else the newest found locally (copied in), else downloaded.
$import = $null; $download = $null
if (-not $SetupExe) {
  $intended = Join-Path $SetupDir 'setup-x86_64.exe'
  if (Test-Path $intended) { $SetupExe = $intended }
  else {
    $found = Find-SetupExe
    if ($found) { $import = $found; $SetupExe = $intended }
    elseif (-not $NoDownload) { $download = $SetupUrl; $SetupExe = $intended }
    else { throw "no setup-x86_64.exe found; put one in $SetupDir, pass -SetupExe, or drop -NoDownload" }
  }
}

$NewBash = Join-Path $Root 'bin\bash.exe'
$Base    = Split-Path $Root -Parent
$setupArgs = @('-q','-X','-n','-d','-N','--no-admin','-R',$Root,'-s',$Snapshot,'-l',$SetupDir,'-P',$Packages)

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
  exit 0
}

New-Item -ItemType Directory -Force -Path $SetupDir | Out-Null
$dest = Join-Path $SetupDir 'setup-x86_64.exe'
if ($import)   { Copy-Item -Force $import $dest; Write-Host "imported setup: $import" }
if ($download) { Write-Host "downloading setup from $download"; Invoke-WebRequest -Uri $download -OutFile $dest }
if (-not (Test-Path $SetupExe)) { throw "setup program not found: $SetupExe" }

Write-Host "== phase 1: install the Cygwin tree (no admin) =="
$p = Start-Process -FilePath $SetupExe -ArgumentList $setupArgs -Wait -NoNewWindow -PassThru
if ($p.ExitCode -ne 0) { throw "setup exited $($p.ExitCode); see $Root\var\log\setup.log.full" }
if (-not (Test-Path $NewBash)) { throw "new tree bash missing: $NewBash (did the install finish?)" }

# Phase 2: a bash runner executed by the NEW tree's bash. REPO is baked in as a
# Windows path and converted with the new tree's own cygpath.
$tmp = Join-Path $Root 'tmp'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$runnerWin = Join-Path $tmp 'install-all-mta.sh'
$startLine = if ($NoStart) { '' } else { '"$REPO/bin/postfix-user-launch.sh" start' }
$runner = @"
#!/bin/bash
set -e
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
REPO=`$(cygpath -u '$Here')
"`$REPO/bin/install-packages.sh"
"`$REPO/bin/postfix-user-setup.sh"
$startLine
echo "install-all: MTA phase done"
"@
[IO.File]::WriteAllText($runnerWin, ($runner -replace "`r`n","`n"))

Write-Host "== phase 2: install and start the MTA inside the new tree =="
$p2 = Start-Process -FilePath $NewBash -ArgumentList $runnerWin -Wait -NoNewWindow -PassThru
if ($p2.ExitCode -ne 0) { throw "MTA phase failed inside the new tree (exit $($p2.ExitCode))" }

if ($Shortcut)  { & (Join-Path $Here 'bin\install-mintty-shortcut.ps1') -Base $Base }
if ($LogonTask) { & (Join-Path $Here 'bin\install-logon-task.ps1') }

Write-Host "install-all: done. Replica at $Root"
