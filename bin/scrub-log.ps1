<#
.SYNOPSIS
  Mask site-identifying strings in a captured log before it is shared (e.g.
  attached to a public issue).

.DESCRIPTION
  Replaces this machine's identifiers - computer name, user, Windows domain and
  DNS domain, and the user-profile path - with neutral placeholders. Run it on
  the machine that produced the log, so those environment values match what the
  log contains. Anything the environment can't supply (a Cygwin username that
  differs from the Windows one, a specific hostname) can be passed with -Also.

  Matching is case-insensitive and literal (not regex), longest first, so a
  domain isn't half-masked by a shorter overlapping token.

.PARAMETER Path
  The log file to scrub.

.PARAMETER Out
  Where to write the scrubbed text. Default: stdout.

.PARAMETER Also
  Extra literal strings to mask (Cygwin username, hostnames, anything else).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)][string]$Path,
  [string]$Out = '',
  [string[]]$Also = @()
)

if (-not (Test-Path $Path)) { throw "scrub-log: file not found: $Path" }

$map = [ordered]@{}
function AddMask($val, $tag) { if ($val -and -not $map.Contains($val)) { $map[$val] = $tag } }
AddMask $env:COMPUTERNAME   '<HOST>'
AddMask $env:USERDNSDOMAIN  '<DNSDOMAIN>'
AddMask $env:USERDOMAIN     '<DOMAIN>'
AddMask $env:USERPROFILE    '<USERPROFILE>'
AddMask $env:USERNAME       '<USER>'
foreach ($a in $Also) { AddMask $a '<REDACTED>' }

$text = Get-Content -Raw -Path $Path
foreach ($k in ($map.Keys | Sort-Object { $_.Length } -Descending)) {
  $text = [regex]::Replace($text, [regex]::Escape($k), $map[$k], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

if ($Out) { Set-Content -Path $Out -Value $text -Encoding ASCII; Write-Host "scrubbed -> $Out" }
else { $text }
