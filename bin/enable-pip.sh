#!/usr/bin/env bash
# Bootstrap pip for Python 3 in the replica Cygwin tree. The 2019 snapshot's
# CA bundle is too old for PyPI, so this script first imports root certificates
# from the Windows certificate store via update-ca-trust, then runs ensurepip.
# Run inside the replica.
set -eu
export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

PROG=${0##*/}
VERSION='enable-pip 1.1'

usage() {
	cat <<EOF
Bootstrap pip for Python 3 in the current Cygwin tree.

Imports the host Windows root CA certificates into the Cygwin trust store
(needed because the 2019 snapshot CA bundle cannot verify modern TLS), then
bootstraps pip via ensurepip.

Usage:
  $PROG [options]

Options:
  --ca-only       update the CA trust store and exit; skip pip
  -n, --dry-run   show what would run; change nothing
  -v, --verbose   more detail
  -t, --terse     minimal output
  -d, --debug     debug/trace output (implies --verbose)
  -h, --help      show this help and exit
      --version   show version and exit
EOF
}

err()       { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()       { err "$*"; exit 1; }
die_usage() { err "$*"; exit 2; }

DRY_RUN=0 VERBOSE=0 TERSE=0 DEBUG=0 CA_ONLY=0
while [ $# -gt 0 ]; do
	case $1 in
		--)           shift; break ;;
		--ca-only)    CA_ONLY=1; shift ;;
		-n|--dry-run) DRY_RUN=1; shift ;;
		-v|--verbose) VERBOSE=$((VERBOSE + 1)); shift ;;
		-t|--terse)   TERSE=1; shift ;;
		-d|--debug)   DEBUG=1; VERBOSE=$((VERBOSE + 1)); shift ;;
		-h|--help)    usage; exit 0 ;;
		--version)    printf '%s\n' "$VERSION"; exit 0 ;;
		-*)           die_usage "unknown option: $1 (try --help)" ;;
		*)            die_usage "unexpected argument: $1 (try --help)" ;;
	esac
done
if [ "$DEBUG" = 1 ]; then set -x; fi
say() { [ "$TERSE" = 1 ] || printf '%s\n' "$*"; }

# -- locate tools -------------------------------------------------------------

command -v update-ca-trust >/dev/null 2>&1 \
	|| die "update-ca-trust not found -- install the ca-certificates package"

ANCHOR_DIR=/etc/pki/ca-trust/source/anchors
[ -d "$ANCHOR_DIR" ] \
	|| die "trust anchor directory missing: $ANCHOR_DIR"

# Find powershell.exe; check the usual locations.
PS_EXE=
for p in /cygdrive/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
         /cygdrive/c/Windows/SysWOW64/WindowsPowerShell/v1.0/powershell.exe; do
	if [ -x "$p" ]; then PS_EXE=$p; break; fi
done
[ -n "$PS_EXE" ] || die "powershell.exe not found"

# -- import Windows root CAs --------------------------------------------------

say "== importing Windows root CA certificates =="

WIN_PEM=$ANCHOR_DIR/windows-root-ca.pem
PS_SCRIPT=$(mktemp /tmp/export-ca.XXXXXX.ps1)
trap 'rm -f "$PS_SCRIPT"' EXIT

# The PowerShell snippet exports every cert in LocalMachine\Root to PEM.
cat > "$PS_SCRIPT" << 'ENDPS'
$certs = Get-ChildItem -Path Cert:\LocalMachine\Root
$pem = ""
foreach ($cert in $certs) {
    $b64 = [Convert]::ToBase64String($cert.RawData, 'InsertLineBreaks')
    $pem += "# " + $cert.Subject + "`n"
    $pem += "-----BEGIN CERTIFICATE-----`n"
    $pem += $b64 + "`n"
    $pem += "-----END CERTIFICATE-----`n`n"
}
ENDPS
# Append the output path -- it contains the Cygwin root which varies per site,
# so we resolve it here rather than hardcoding it in the PS1.
win_pem_path=$(cygpath -w "$WIN_PEM")
printf '[System.IO.File]::WriteAllText("%s", $pem)\n' "$win_pem_path" >> "$PS_SCRIPT"
printf 'Write-Output ("Exported " + $certs.Count + " certificates")\n' >> "$PS_SCRIPT"

if [ "$DRY_RUN" = 1 ]; then
	say "would export Windows root CAs to $WIN_PEM"
	say "would run: update-ca-trust"
	if [ "$CA_ONLY" = 0 ]; then
		say "would run: python3 -m ensurepip --upgrade"
	fi
	exit 0
fi

ps_script_win=$(cygpath -w "$PS_SCRIPT")
output=$("$PS_EXE" -ExecutionPolicy Bypass -File "$ps_script_win" 2>&1) \
	|| die "PowerShell CA export failed: $output"

[ -s "$WIN_PEM" ] || die "CA export produced an empty file"

if [ "$VERBOSE" -ge 1 ]; then
	say "  $output"
	say "  written to $WIN_PEM"
fi

say "== updating CA trust store =="
update-ca-trust

# Quick sanity check: can Python's ssl reach PyPI?
if python3 -c '
import ssl, socket
ctx = ssl.create_default_context()
s = ctx.wrap_socket(socket.socket(), server_hostname="pypi.org")
s.connect(("pypi.org", 443))
s.close()
' 2>/dev/null; then
	[ "$VERBOSE" -ge 1 ] && say "  verified: TLS to pypi.org OK"
else
	err "warning: TLS to pypi.org still fails after CA update"
	err "pip install will likely fail; check network/proxy settings"
fi

if [ "$CA_ONLY" = 1 ]; then
	say "enable-pip: CA trust updated (--ca-only)."
	exit 0
fi

# -- bootstrap pip -------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

if python3 -m pip --version >/dev/null 2>&1; then
	pip_ver=$(python3 -m pip --version)
	say "pip already installed: $pip_ver"
	exit 0
fi

python3 -c 'import ensurepip' 2>/dev/null \
	|| die "ensurepip module missing -- install the python36 package first"

say "== bootstrapping pip via ensurepip =="
python3 -m ensurepip --upgrade

pip_ver=$(python3 -m pip --version) \
	|| die "ensurepip ran but pip is still not loadable"

if [ "$VERBOSE" -ge 1 ]; then
	say "  $pip_ver"
fi

say "enable-pip: done."
