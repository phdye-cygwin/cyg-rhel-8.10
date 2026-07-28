#!/usr/bin/env python3
"""
install-parity-packages.py

Ensures the RHEL 8.10 Cygwin replica carries the same packages as the
primary Cygwin, translated to the 2019 CTM snapshot equivalents.

Runs entirely from the REPLICA's Python (3.6.9). The primary Cygwin's
package list is read as a plain file via the filesystem -- no cross-tree
execution needed. setup-x86_64.exe is a native Windows binary, callable
directly from Cygwin without DLL conflicts.

Usage (from the replica):
    python3 /path/to/install-parity-packages.py [--dry-run] [--skip-verify]

Python 3.6.8 compatible -- no walrus operator, no capture_output.
"""

import argparse
import logging
import os
import re
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Configuration -- adjust for the target machine's layout
# ---------------------------------------------------------------------------

# Windows paths (backslash) -- used by setup-x86_64.exe and cmd.exe
PRIMARY_ROOT_WIN = r'C:\-\cygwin\root'
REPLICA_ROOT_WIN = r'C:\-\rhel810\root'
SETUP_DIR_WIN = r'C:\-\rhel810\setup'

# 2019-08-01 Cygwin Time Machine snapshot
SNAPSHOT_URL = (
    'http://ctm.crouchingtigerhiddenfruitbat.org'
    '/pub/cygwin/circa/64bit/2019/08/01/131636'
)

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

def win_to_posix(win_path):
    """Convert a Windows path to the Cygwin POSIX equivalent.

    Uses cygpath(1) so the result respects the local cygdrive prefix,
    which may be / or /cygdrive/ depending on the installation.
    Falls back to a manual conversion if cygpath is unavailable.
    """
    try:
        proc = subprocess.run(
            ['cygpath', '-u', win_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5
        )
        if proc.returncode == 0:
            return proc.stdout.decode('utf-8', errors='replace').strip()
    except (FileNotFoundError, OSError):
        pass

    # Fallback: manual conversion assuming /cygdrive/ prefix
    if len(win_path) >= 2 and win_path[1] == ':':
        drive = win_path[0].lower()
        rest = win_path[2:].replace('\\', '/')
        return '/cygdrive/{}{}'.format(drive, rest)
    raise ValueError("expected a drive-letter path: {}".format(win_path))


def posix_to_win(posix_path):
    """Convert a Cygwin POSIX path back to Windows.

    Uses cygpath(1) when available, falls back to manual conversion.
    """
    try:
        proc = subprocess.run(
            ['cygpath', '-w', posix_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5
        )
        if proc.returncode == 0:
            return proc.stdout.decode('utf-8', errors='replace').strip()
    except (FileNotFoundError, OSError):
        pass

    # Fallback: manual conversion assuming /cygdrive/ prefix
    m = re.match(r'^/(?:cygdrive/)?([a-zA-Z])(/.*)?$', posix_path)
    if not m:
        raise ValueError("not a cygdrive path: {}".format(posix_path))
    drive = m.group(1).upper()
    rest = (m.group(2) or '').replace('/', '\\')
    return '{}:{}'.format(drive, rest)

# ---------------------------------------------------------------------------
# Package list extraction
# ---------------------------------------------------------------------------

def read_installed_db(root_win):
    """Parse installed.db from a Cygwin root. Returns a set of package names.

    installed.db is a plain text file:
        INSTALLED.DB 3
        pkg_name  tarball_name  0
        ...

    Reading via the filesystem -- no cross-tree execution needed.
    """
    db_path = '{}/etc/setup/installed.db'.format(win_to_posix(root_win))
    packages = set()
    with open(db_path, 'r') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('INSTALLED.DB'):
                continue
            parts = line.split()
            if parts:
                packages.add(parts[0])
    return packages


def read_setup_ini_packages(setup_dir_win):
    """Parse setup.ini for the set of available package names.

    Package stanzas start with '@ package-name'.
    """
    ini_path = '{}/setup.ini'.format(win_to_posix(setup_dir_win))
    packages = set()
    with open(ini_path, 'r') as fh:
        for line in fh:
            if line.startswith('@ '):
                packages.add(line[2:].strip())
    return packages

# ---------------------------------------------------------------------------
# Package name mapping: primary (modern Cygwin) -> 2019 snapshot
# ---------------------------------------------------------------------------

# Explicit renames: primary_name -> snapshot_name
# None means "skip, no equivalent"
EXPLICIT_MAP = {
    # Python 3.9 -> 3.6
    'python39':                              'python36',
    'python39-babel':                        'python36-babel',
    'python39-chardet':                      'python36-chardet',
    'python39-docutils':                     'python36-docutils',
    'python39-idna':                         'python36-idna',
    'python39-imagesize':                    'python36-imagesize',
    'python39-imaging':                      'python36-imaging',
    'python39-jinja2':                       'python36-jinja2',
    'python39-markupsafe':                   'python36-markupsafe',
    'python39-olefile':                      'python36-olefile',
    'python39-packaging':                    'python36-packaging',
    'python39-pip':                          'python36-pip',
    'python39-pygments':                     'python36-pygments',
    'python39-requests':                     'python36-requests',
    'python39-setuptools':                   'python36-setuptools',
    'python39-snowballstemmer':              'python36-snowballstemmer',
    'python39-sphinx':                       'python36-sphinx',
    'python39-urllib3':                      'python36-urllib3',
    'python39-wheel':                        'python36-wheel',

    # Python packages with no python36 equivalent -- skip
    'python39-filelock':                     None,
    'python39-importlib-metadata':           None,
    'python39-iniconfig':                    None,
    'python39-platformdirs':                 None,
    'python39-pluggy':                       None,
    'python39-pytest':                       None,
    'python39-sphinxcontrib-serializinghtml': None,
    'python39-toml':                         None,
    'python39-typing_extension':             None,
    'python39-zipp':                         None,

    # Library version splits -- older soname in the snapshot
    'libffi8':           None,  # libffi6 covers it
    'libguile3.0_1':     'libguile2.0_22',
    'libhogweed7':       'libhogweed4',
    'libisl23':          'libisl15',
    'libmailutils7':     'libmailutils5',
    'libnettle9':        'libnettle6',
    'libopenldap2':      None,  # libopenldap2_4_2 is the snapshot name
    'libpkgconf7':       'libpkgconf3',
    'libproc2_1':        None,  # libprocps7 is the era equivalent
    'libreadline8':      None,  # libreadline7 covers it
    'libssl3':           None,  # libssl1.1 covers it
    'libtiff7':          'libtiff6',
    'libunistring5':     None,  # libunistring2 covers it

    # Packages that did not exist in the 2019 snapshot
    'libdeflate0':       None,
    'libfido2':          None,
    'liblastlog2':       None,
    'libtree-sitter0':   None,
    'libxxhash0':        None,

    # Newer Cygwin package splits -- the parent package covers them
    'emacs-basic':           None,  # emacs package covers it
    'gettext-locale-alias':  None,  # gettext covers it
}


def map_packages(primary_pkgs, snapshot_pkgs):
    """Translate primary package names to snapshot equivalents.

    Returns (install_set, skipped_list) where skipped_list contains
    (primary_name, reason) tuples.
    """
    install = set()
    skipped = []

    for pkg in sorted(primary_pkgs):
        # Check explicit mapping first
        if pkg in EXPLICIT_MAP:
            mapped = EXPLICIT_MAP[pkg]
            if mapped is None:
                skipped.append((pkg, 'no snapshot equivalent (see EXPLICIT_MAP)'))
            elif mapped in snapshot_pkgs:
                install.add(mapped)
            else:
                skipped.append((pkg, 'mapped to {} but not in snapshot'.format(mapped)))
            continue

        # Direct match
        if pkg in snapshot_pkgs:
            install.add(pkg)
            continue

        # No match
        skipped.append((pkg, 'not in 2019 snapshot'))

    return install, skipped

# ---------------------------------------------------------------------------
# setup-x86_64.exe invocation
# ---------------------------------------------------------------------------

def build_setup_command(packages):
    """Build the setup-x86_64.exe command line.

    setup-x86_64.exe is a native Windows PE binary -- Cygwin can launch
    it directly without DLL conflicts. The -R, -s, -l arguments are
    Windows paths because setup.exe is a native binary.
    """
    setup_exe_win = '{}\\setup-x86_64.exe'.format(SETUP_DIR_WIN)
    setup_exe = win_to_posix(setup_exe_win)
    pkg_csv = ','.join(sorted(packages))

    return [
        setup_exe,
        '-q',               # unattended
        '-X',               # unsigned setup.ini (CTM archive)
        '-n',               # no shortcuts
        '-d',               # no desktop icon
        '-N',               # no start menu
        '--no-admin',        # unelevated install
        '-R', REPLICA_ROOT_WIN,
        '-s', SNAPSHOT_URL,
        '-l', SETUP_DIR_WIN,
        '-P', pkg_csv,
    ]


def run_setup(packages, dry_run=False):
    """Invoke setup-x86_64.exe to install packages.

    setup detaches on its own, so we launch it and return. Progress is
    tracked via the setup log at <replica>/var/log/setup.log.full.
    """
    cmd = build_setup_command(packages)

    if dry_run:
        log.info("DRY RUN -- would execute:")
        log.info("  %s", ' '.join(cmd))
        return None

    log.info("launching setup-x86_64.exe with %d packages ...", len(packages))
    log.info("  setup detaches; watch:")
    log.info("  %s\\var\\log\\setup.log.full", REPLICA_ROOT_WIN)

    proc = subprocess.Popen(cmd)
    log.info("  setup launched (PID %d)", proc.pid)
    return proc

# ---------------------------------------------------------------------------
# Post-install verification
# ---------------------------------------------------------------------------

def verify_installation(expected_pkgs):
    """Check the replica's installed.db against the expected set.

    Runs after setup-x86_64.exe finishes. Since we are in the replica,
    this is a direct file read -- no cross-tree execution.
    """
    try:
        actual = read_installed_db(REPLICA_ROOT_WIN)
    except FileNotFoundError:
        log.error("replica installed.db not found -- setup may not have run")
        return [], list(expected_pkgs)

    installed = sorted(expected_pkgs & actual)
    missing = sorted(expected_pkgs - actual)
    return installed, missing

# ---------------------------------------------------------------------------
# Setup log polling
# ---------------------------------------------------------------------------

def wait_for_setup(timeout_seconds=600, poll_interval=5):
    """Poll the replica's setup.log.full until setup finishes or times out.

    setup-x86_64.exe writes to this log as it works. We watch for the
    final 'ending cygwin install' or similar marker, or for the file to
    stop growing.
    """
    log_path = '{}/var/log/setup.log.full'.format(win_to_posix(REPLICA_ROOT_WIN))

    if not os.path.exists(log_path):
        log.info("waiting for setup log to appear ...")

    start = time.time()
    last_size = -1
    stable_count = 0

    while time.time() - start < timeout_seconds:
        time.sleep(poll_interval)

        if not os.path.exists(log_path):
            continue

        size = os.path.getsize(log_path)
        if size == last_size:
            stable_count += 1
            if stable_count >= 3:
                # Log hasn't grown in 3 polls -- setup likely finished
                log.info("setup log stable at %d bytes, assuming complete", size)
                return True
        else:
            stable_count = 0
            last_size = size
            elapsed = int(time.time() - start)
            log.info("  setup running ... log at %d bytes (%ds elapsed)", size, elapsed)

    log.warning("timed out after %ds waiting for setup to finish", timeout_seconds)
    return False

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log = logging.getLogger('install-parity')


def main():
    global PRIMARY_ROOT_WIN, REPLICA_ROOT_WIN, SETUP_DIR_WIN

    parser = argparse.ArgumentParser(
        description='Install primary-Cygwin packages into the RHEL 8.10 replica.'
    )
    parser.add_argument(
        '--dry-run', action='store_true',
        help='Print the setup command without executing it.'
    )
    parser.add_argument(
        '--skip-verify', action='store_true',
        help='Skip post-install verification.'
    )
    parser.add_argument(
        '--no-wait', action='store_true',
        help='Do not wait for setup-x86_64.exe to finish.'
    )
    parser.add_argument(
        '--primary-root', default=PRIMARY_ROOT_WIN,
        help='Windows path to the primary Cygwin root '
             '(default: %(default)s).'
    )
    parser.add_argument(
        '--replica-root', default=REPLICA_ROOT_WIN,
        help='Windows path to the RHEL replica root '
             '(default: %(default)s).'
    )
    parser.add_argument(
        '--setup-dir', default=SETUP_DIR_WIN,
        help='Windows path to the replica setup/cache dir '
             '(default: %(default)s).'
    )
    parser.add_argument(
        '-v', '--verbose', action='store_true',
        help='Enable debug logging.'
    )
    args = parser.parse_args()

    # Apply CLI overrides
    PRIMARY_ROOT_WIN = args.primary_root
    REPLICA_ROOT_WIN = args.replica_root
    SETUP_DIR_WIN = args.setup_dir

    # Logging
    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format='%(asctime)s %(levelname)-5s %(message)s',
        datefmt='%H:%M:%S'
    )

    # ------------------------------------------------------------------
    # Step 1: read the primary Cygwin's installed packages
    # ------------------------------------------------------------------
    log.info("=== RHEL 8.10 replica parity install ===")
    log.info("")
    log.info("primary root : %s", PRIMARY_ROOT_WIN)
    log.info("replica root : %s", REPLICA_ROOT_WIN)
    log.info("setup dir    : %s", SETUP_DIR_WIN)
    log.info("snapshot     : %s", SNAPSHOT_URL)
    log.info("")

    log.info("reading primary installed.db ...")
    try:
        primary_pkgs = read_installed_db(PRIMARY_ROOT_WIN)
    except FileNotFoundError:
        log.error(
            "cannot read %s/etc/setup/installed.db",
            win_to_posix(PRIMARY_ROOT_WIN)
        )
        log.error(
            "is the primary Cygwin root correct? (--primary-root)"
        )
        return 1
    log.info("  %d packages in the primary", len(primary_pkgs))

    # ------------------------------------------------------------------
    # Step 2: read the snapshot's available packages
    # ------------------------------------------------------------------
    log.info("reading snapshot setup.ini ...")
    try:
        snapshot_pkgs = read_setup_ini_packages(SETUP_DIR_WIN)
    except FileNotFoundError:
        log.error(
            "cannot read %s/setup.ini",
            win_to_posix(SETUP_DIR_WIN)
        )
        log.error(
            "is the setup dir correct? (--setup-dir)"
        )
        return 1
    log.info("  %d packages in the snapshot", len(snapshot_pkgs))

    # ------------------------------------------------------------------
    # Step 3: map primary packages to snapshot equivalents
    # ------------------------------------------------------------------
    log.info("mapping packages ...")
    install_pkgs, skipped = map_packages(primary_pkgs, snapshot_pkgs)

    # Also include packages already in the replica but not in the primary
    # (leave them alone -- we only add, never remove)
    try:
        replica_pkgs = read_installed_db(REPLICA_ROOT_WIN)
    except FileNotFoundError:
        replica_pkgs = set()

    already = install_pkgs & replica_pkgs
    new_pkgs = install_pkgs - replica_pkgs

    log.info("  %d packages to request from setup", len(install_pkgs))
    log.info("  %d already installed in the replica", len(already))
    log.info("  %d new packages to install", len(new_pkgs))
    log.info("  %d skipped (no snapshot equivalent)", len(skipped))
    log.info("")

    if skipped:
        log.info("--- skipped packages ---")
        for pkg, reason in skipped:
            log.info("  %-45s %s", pkg, reason)
        log.info("")

    if not new_pkgs and not args.dry_run:
        log.info("nothing new to install -- replica is already at parity")
        return 0

    # ------------------------------------------------------------------
    # Step 4: run setup-x86_64.exe
    # ------------------------------------------------------------------
    # Pass the full install set, not just new_pkgs. setup -P is additive
    # and idempotent for already-installed packages; passing the full set
    # ensures setup resolves dependencies correctly.
    proc = run_setup(install_pkgs, dry_run=args.dry_run)

    if args.dry_run:
        return 0

    # ------------------------------------------------------------------
    # Step 5: wait for setup to finish
    # ------------------------------------------------------------------
    if not args.no_wait:
        log.info("")
        finished = wait_for_setup()
        if not finished:
            log.warning("setup may still be running; skipping verification")
            return 2
    else:
        log.info("--no-wait: not waiting for setup to finish")

    # ------------------------------------------------------------------
    # Step 6: verify
    # ------------------------------------------------------------------
    if args.skip_verify:
        log.info("--skip-verify: skipping post-install verification")
        return 0

    log.info("")
    log.info("verifying installation ...")
    installed, missing = verify_installation(install_pkgs)

    if missing:
        log.warning("%d packages requested but not found in replica:", len(missing))
        for pkg in missing:
            log.warning("  %s", pkg)
        return 1
    else:
        log.info("  all %d packages verified in replica", len(installed))

    # ------------------------------------------------------------------
    # Step 7: spot-check a few key binaries via the replica's own shell
    # ------------------------------------------------------------------
    log.info("")
    log.info("spot-checking key tool versions in the replica ...")
    checks = [
        ('bash --version | head -1',    'bash'),
        ('python3 --version',           'python3'),
        ('gcc --version | head -1',     'gcc'),
        ('make --version | head -1',    'make'),
        ('git --version',               'git'),
        ('openssl version',             'openssl'),
    ]
    for cmd_str, label in checks:
        # We are in the replica, so run directly
        try:
            result = subprocess.run(
                ['bash', '-lc', cmd_str],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10
            )
            version = result.stdout.decode('utf-8', errors='replace').strip()
            if version:
                log.info("  %-10s %s", label, version)
            else:
                log.info("  %-10s (no output)", label)
        except Exception as exc:
            log.info("  %-10s check failed: %s", label, exc)

    log.info("")
    log.info("done.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
