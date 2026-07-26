# Create a mintty terminal shortcut for the replica: one in the base directory,
# and by default one on the Desktop. Pass -NoDesktop to skip the Desktop copy.
# No admin needed. -Base points at the install base (default C:\cyg-rhel-8.10);
# the Cygwin root is expected at <Base>\cygwin64.
param(
    [string]$Base = 'C:\cyg-rhel-8.10',
    [switch]$NoDesktop
)
$ErrorActionPreference = 'Stop'

$Root   = Join-Path $Base 'cygwin64'
$Mintty = Join-Path $Root 'bin\mintty.exe'
$Name   = 'Cygwin RHEL 8.10 Terminal'

if (-not (Test-Path -LiteralPath $Mintty)) {
    Write-Error "mintty not found at $Mintty -- is the replica installed under $Base?"
    exit 1
}

# A -n -d install leaves no Cygwin-Terminal.ico; fall back to mintty's own icon
# and drop the -i argument so mintty does not warn about a missing file.
$Ico = Join-Path $Root 'Cygwin-Terminal.ico'
if (Test-Path -LiteralPath $Ico) {
    $MinttyArgs = '-i /Cygwin-Terminal.ico -'
    $Icon       = $Ico
} else {
    $MinttyArgs = '-'
    $Icon       = $Mintty
}

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
    $S.IconLocation     = $Icon
    $S.Description       = 'RHEL 8.10 Cygwin replica terminal (mintty login shell)'
    $S.Save()
    Write-Host "created: $Lnk"
}

New-MinttyShortcut $Base
if ($NoDesktop) {
    Write-Host 'skipped Desktop (-NoDesktop)'
} else {
    New-MinttyShortcut ([Environment]::GetFolderPath('Desktop'))
}
