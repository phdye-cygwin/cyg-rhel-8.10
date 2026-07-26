# Register a per-user logon Scheduled Task that starts the unprivileged Postfix
# master at each logon. No admin: /RL LIMITED keeps it at your normal integrity
# and /SC ONLOGON runs it under your own account. Re-run to update; pass -Remove
# to delete. schtasks is not on the desktop-commander block list, so this also
# runs fine through the bridge.
param([switch]$Remove)

$Task = "rhel810-postfix"
$Cmd  = "$PSScriptRoot\start-postfix.cmd"

if ($Remove) {
    schtasks /Delete /TN $Task /F
    return
}

if (-not (Test-Path $Cmd)) {
    Write-Error "not found: $Cmd"
    exit 1
}

schtasks /Create /TN $Task /TR "`"$Cmd`"" /SC ONLOGON /RL LIMITED /F
Write-Host "Registered logon task '$Task' -> $Cmd"
Write-Host "Start now without logging out:  schtasks /Run /TN $Task"
