# Create a mintty terminal shortcut for the replica: one in the base directory,
# and by default one on the Desktop. Pass -NoDesktop to skip the Desktop copy.
# No admin needed.
#
# -Root is the Cygwin root, authoritative. -Base is the install base; when -Root
# is not given the root is <Base>\cygwin64. install-all.ps1 passes -Root so a
# non-default CYG_RHEL_ROOT (e.g. C:\-\rhel\root) is honored instead of guessing.
#
# The shortcut and the mintty window both use the project icon, so the replica
# reads as distinct from live Cygwin at a glance. Icon resolution: -Icon if given
# and present, else <Root>\usr\share\rhel-cygwin.ico (the project icon that
# install-all stages there), else the tree's own Cygwin-Terminal.ico, else
# mintty's built-in icon.
param(
    [string]$Root = '',
    [string]$Base = 'C:\cyg-rhel-8.10',
    [string]$Icon = '',
    [switch]$NoDesktop
)
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Join-Path $Base 'cygwin64' }
$Mintty = Join-Path $Root 'bin\mintty.exe'
$Name   = 'Cygwin RHEL 8.10 Terminal'

if (-not (Test-Path -LiteralPath $Mintty)) {
    Write-Error "mintty not found at $Mintty -- is 'mintty' installed in the tree under $Root?"
    exit 1
}

$projIco = Join-Path $Root 'usr\share\rhel-cygwin.ico'
$cygIco  = Join-Path $Root 'Cygwin-Terminal.ico'
if     ($Icon -and (Test-Path -LiteralPath $Icon)) { $IconPath = $Icon }
elseif (Test-Path -LiteralPath $projIco)           { $IconPath = $projIco }
elseif (Test-Path -LiteralPath $cygIco)            { $IconPath = $cygIco }
else                                               { $IconPath = $Mintty }

# mintty's -i takes a Windows path even from a Cygwin context. When only the exe
# is left, drop -i so mintty does not warn about a missing icon file.
if ($IconPath -eq $Mintty) { $MinttyArgs = '-' }
else                       { $MinttyArgs = ('-i "{0}" -' -f $IconPath) }

function New-MinttyShortcut([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $Lnk = Join-Path $Dir "$Name.lnk"
    $Ws  = New-Object -ComObject WScript.Shell
    $S   = $Ws.CreateShortcut($Lnk)
    $S.TargetPath       = $Mintty
    $S.Arguments        = $MinttyArgs
    $S.WorkingDirectory = (Join-Path $Root 'bin')
    $S.IconLocation     = $IconPath
    $S.Description      = 'RHEL 8.10 Cygwin replica terminal (mintty login shell)'
    $S.Save()
    Write-Host "created: $Lnk  (icon: $IconPath)"
}

New-MinttyShortcut $Base
if ($NoDesktop) {
    Write-Host 'skipped Desktop (-NoDesktop)'
} else {
    New-MinttyShortcut ([Environment]::GetFolderPath('Desktop'))
}
