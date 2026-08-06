#!/usr/bin/env python3
"""cygroot -- which Cygwin instance is this, and which one is the default.

Three roots live under C:\\- on this machine and they share one Windows
profile, so "which instance am I in" and "which instance should a caller
outside Cygwin use" are different questions with different answers. Both are
answered here, and every line names the instance, because a result that does
not say which instance produced it is how wrong conclusions get filed.

Two decisions worth keeping:

The default is a name in a text file. Not a junction, not a mount point, not a
Windows symlink. Those need rights this account does not reliably have and the
client account does not have at all, and a tool for arranging your own shell
must never be the thing that needs privileges.

"Which instance am I in" never reads that file. cygpath answers it, so the
answer cannot go stale, disagree with reality, or depend on anything having
been set up first.

Usable as a library or as a command:

    from cygroot import known_roots, this_root_name, read_default
    python3 -m cygroot --status
    cygroot rhel

Nothing below the CLI layer exits or prints. Failures raise CygrootError,
which main() renders. Python floor 3.6; runs on the replica's 3.6.9.
"""

import ntpath
import os
import subprocess
import sys

__version__ = '1.0.0'
__all__ = ['CygrootError', 'known_roots', 'this_root_windows',
           'this_root_name', 'resolve', 'read_default', 'write_default',
           'clear_default', 'config_path', 'roots_dir', 'install_to',
           'home_of', 'interpreter_of', 'main']

OK, WARN, GAP = 0, 1, 2


class CygrootError(Exception):
    """Something the caller has to decide about.

    Carries the three things a person needs: what is wrong, why it matters,
    and the command that fixes it. The CLI prints all three; a library caller
    can read them off the exception.
    """

    def __init__(self, what, why=None, run=None):
        Exception.__init__(self, what)
        self.what = what
        self.why = why
        self.run = run


def cygpath(*args):
    """cygpath output, stripped. Its absence is not a Cygwin."""
    try:
        p = subprocess.Popen(['cygpath'] + list(args),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError:
        raise CygrootError(
            'cygpath is not on PATH.',
            'This only means anything inside a Cygwin instance.',
            'run it from a Cygwin shell')
    return p.communicate()[0].decode('utf-8', 'replace').strip()


# ---- finding the instances -----------------------------------------
# The filesystem is the registry. An instance is a directory holding
# bin/cygwin1.dll and bin/bash.exe, and its name is the directory above it:
# C:\-\rhel\root is "rhel". Nothing is listed in a config file, so one built
# today is known today and one deleted is gone without an edit anywhere.
def this_root_windows():
    """Windows path of the instance this process is running in."""
    w = cygpath('-w', '/')
    if not w:
        raise CygrootError(
            'cygpath -w / said nothing.',
            'Without it there is no telling which instance this is.')
    return w.rstrip('\\')


def roots_dir():
    """Where instances live: CYGROOT_DIR, else the parent of this one.

    ntpath, not os.path. Under Cygwin os.path is posixpath, which does not
    treat a backslash as a separator, so dirname('C:\\-\\cygwin\\root')
    answers '' and every instance goes missing with no error anywhere.
    """
    d = os.environ.get('CYGROOT_DIR', '')
    if d:
        return d
    return ntpath.dirname(ntpath.dirname(this_root_windows()))


def is_root(posix_dir):
    return (os.path.isfile(os.path.join(posix_dir, 'bin', 'cygwin1.dll'))
            and os.path.isfile(os.path.join(posix_dir, 'bin', 'bash.exe')))


def known_roots():
    """[(name, windows_path, posix_path)], sorted, real instances only."""
    top = cygpath('-u', roots_dir())
    if not os.path.isdir(top):
        return []
    out = []
    for name in sorted(os.listdir(top)):
        posix = os.path.join(top, name, 'root')
        if is_root(posix):
            out.append((name, cygpath('-w', posix).rstrip('\\'), posix))
    return out


def this_root_name(roots=None):
    """Name of the instance this process is in, or None if it is not one of
    the ones we can see. Compared on the Windows path, case-insensitively,
    because that is the spelling both sides always agree on."""
    mine = this_root_windows().lower()
    for name, win, _posix in (roots if roots is not None else known_roots()):
        if win.lower() == mine:
            return name
    return None


def resolve(name, roots=None):
    """The (name, windows, posix) triple for name. Raises if there is no such
    instance, and says which ones there are."""
    roots = known_roots() if roots is None else roots
    for entry in roots:
        if entry[0].lower() == name.lower():
            return entry
    raise CygrootError(
        'no such instance: %s' % name,
        'Known instances: %s' % (', '.join(r[0] for r in roots) or '(none)'),
        'cygroot --list')


# ---- the default ---------------------------------------------------
def config_path():
    """The file holding the default name.

    CYGROOT_CONFIG wins. Otherwise the Windows profile, which is the one
    directory every instance on this machine shares and every account can
    write. USERPROFILE unset with no override is a hard failure rather than a
    guess: writing a default somewhere nobody reads is worse than refusing.
    """
    p = os.environ.get('CYGROOT_CONFIG', '')
    if p:
        return p
    profile = os.environ.get('USERPROFILE', '')
    if not profile:
        raise CygrootError(
            'USERPROFILE is unset and CYGROOT_CONFIG is not set either.',
            'One of them has to say where the default is recorded.',
            'export CYGROOT_CONFIG=/c/Users/<you>/.cygroot')
    return os.path.join(cygpath('-u', profile), '.cygroot')


def read_default(path=None):
    """The default instance name, or None. Never validates it: a default
    naming an instance that no longer exists is a fact worth reporting, not an
    error to hide."""
    p = config_path() if path is None else path
    if not os.path.isfile(p):
        return None
    try:
        f = open(p)
    except IOError:
        return None
    try:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if line:
                return line
    finally:
        f.close()
    return None


def write_default(name, path=None):
    """Record name as the default. Returns the file written."""
    p = config_path() if path is None else path
    d = os.path.dirname(p)
    if d and not os.path.isdir(d):
        raise CygrootError(
            'nowhere to write the default: %s does not exist' % d,
            'The default is one text file and that is its directory.',
            'export CYGROOT_CONFIG=<a path you can write>')
    try:
        f = open(p, 'w')
    except IOError:
        raise CygrootError(
            'cannot write %s: %s' % (p, sys.exc_info()[1]),
            'Setting the default needs no rights beyond this one file.')
    try:
        f.write('# The default Cygwin instance for callers not already inside\n'
                '# one. Written by cygroot; a name, nothing else.\n'
                '%s\n' % name)
    finally:
        f.close()
    return p


def clear_default(path=None):
    """Forget the default. Returns the file removed, or None if there was
    nothing to remove."""
    p = config_path() if path is None else path
    if not os.path.exists(p):
        return None
    try:
        os.remove(p)
    except OSError:
        raise CygrootError('cannot remove %s: %s' % (p, sys.exc_info()[1]))
    return p


def home_of(posix_root, user=None):
    """That instance's home for a user. Not necessarily one that exists: the
    caller decides whether absence is a problem.

    Each instance keeps its own /home, and under desktop-commander HOME is the
    Windows profile instead, which is how ~/.pbi and the git identity in
    /home/phili/.gitconfig get missed. This is the path that was meant.
    """
    u = (user or os.environ.get('USER') or os.environ.get('USERNAME')
         or os.environ.get('LOGNAME') or '')
    if not u:
        raise CygrootError(
            'cannot tell which user to look for.',
            'USER, USERNAME and LOGNAME are all unset.',
            'cygroot --home <instance> --user <you>')
    return os.path.join(posix_root, 'home', u)


def interpreter_of(posix_root):
    """That instance's python3, as the real executable.

    bin/python3 is a symlink -- to /etc/alternatives/python3 in one instance
    and straight to python3.6m.exe in another -- and a symlink is not
    something a Windows-side caller or a neighbouring instance can run. The
    versioned .exe is, and its name says which interpreter you are getting,
    which is the question that keeps coming up: 3.2m, 3.6m and 3.9 here.
    """
    d = os.path.join(posix_root, 'bin')
    cands = []
    if os.path.isdir(d):
        cands = [n for n in os.listdir(d)
                 if n.startswith('python3') and n.endswith('.exe')]

    def version_key(n):
        core = n[len('python3'):-len('.exe')].rstrip('m').strip('.')
        return [int(p) if p.isdigit() else 0 for p in core.split('.')] or [0]

    if cands:
        cands.sort(key=version_key)
        return os.path.join(d, cands[-1])
    for n in ('python3.exe', 'python3'):
        p = os.path.join(d, n)
        if os.path.exists(p):
            return p
    raise CygrootError(
        'no python3 in %s' % d,
        'That instance has no interpreter to name.',
        'cygroot --list')


def install_to(posix_root, source=None):
    """Copy this module into an instance's /usr/local/bin.

    Returns (module_path, command_path): cygroot.py to import, cygroot to
    run. Both are real copies of the same bytes.

    The second one was a symlink for about ten minutes. Written from the
    primary instance, it arrived in the replica as a 0-byte Unknown+User file
    at mode 0640 and would not execute -- each instance has its own cygwin1.dll
    and its own idea of what a link and a user are, and one instance's link is
    not portable to the next. A duplicate copy is cheap; a command that
    reports Permission denied on the host you actually test from is not.
    """
    src = os.path.abspath(source or __file__)
    if src.endswith('.pyc'):
        src = src[:-1]
    dest_dir = os.path.join(posix_root, 'usr', 'local', 'bin')
    if not os.path.isdir(dest_dir):
        raise CygrootError(
            'no %s to install into' % dest_dir,
            'That instance has no /usr/local/bin.',
            'mkdir -p %s' % dest_dir)
    dest = os.path.join(dest_dir, 'cygroot.py')
    try:
        fin = open(src, 'rb')
        try:
            body = fin.read()
        finally:
            fin.close()
        fout = open(dest, 'wb')
        try:
            fout.write(body)
        finally:
            fout.close()
        os.chmod(dest, 0o755)
    except (IOError, OSError):
        raise CygrootError('cannot install to %s: %s'
                           % (dest, sys.exc_info()[1]))

    cmd = os.path.join(dest_dir, 'cygroot')
    try:
        if os.path.lexists(cmd):
            os.remove(cmd)      # may be a link left by an older install
        fout = open(cmd, 'wb')
        try:
            fout.write(body)
        finally:
            fout.close()
        os.chmod(cmd, 0o755)
    except (IOError, OSError):
        raise CygrootError(
            'installed %s but could not write %s: %s'
            % (dest, cmd, sys.exc_info()[1]),
            'The module is there; only the bare command name is missing.')
    return dest, cmd


# ---- the command ---------------------------------------------------
USAGE = """\
Usage: cygroot [options] [<name>]

  cygroot                 what this shell is, what the default is, what exists
  cygroot --status        the same thing, said explicitly
  cygroot <name>          make <name> the default
  cygroot <name> -n       say what that would change, change nothing

Reporting. None of these read the default except --default:
  --status                the report
  --which                 name of the instance this shell is in
  -l, --list              known names, one per line
  --default               the default name, and nothing else
  --exists [<name>]       say nothing; exit 0 if it is an instance, 1 if not

Paths into an instance:
  -b, --bash [<name>]     its bash.exe
  --python [<name>]       its python3, the real .exe rather than the symlink
  --home [<name>]         its /home/<user>; exit 1 if that does not exist
  --user <who>            whose home, for --home (default: $USER)

Path form, spelled as cygpath spells it and handed to cygpath to apply. Any
of them alone prints the instance's own path; with one of the four above, it
sets the form that one comes out in:
  -u, --unix [<name>]     /c/-/rhel/root      (the default)
  -w, --windows [<name>]  C:\\-\\rhel\\root
  -m, --mixed [<name>]    C:/-/rhel/root

Three, not all of cygpath's. This is not a second cygpath, and cygpath is one
pipe away. Note that -d is --debug here, not cygpath's --dos.

Acting:
  <name>                  set the default
  --clear                 forget the default
  --install [<name> ...]  copy this into each instance's /usr/local/bin
                          (all known instances when none are named)

  -n, --dry-run           say what would change, change nothing
  -v, --verbose           more detail
  -d, --debug             implies --verbose, and says where things resolved
  -h, --help              this
  --version               version and exit

<name> defaults to the instance this shell is in.

Environment:
  CYGROOT_CONFIG  file holding the default name
                  (default: <windows profile>/.cygroot)
  CYGROOT_DIR     directory the instances live under
                  (default: the parent of this instance, normally C:\\-)

Exit: 0 fine, 1 worth reading, 2 a usage error or a refusal.
"""


def _report(out, verbose):
    roots = known_roots()
    here = this_root_name(roots)
    dflt = read_default()
    win = this_root_windows()

    out('this shell:  %-10s %s' % (here or '(unrecognised)', win))
    if dflt is None:
        out('default:     (none set)          %s' % config_path())
    else:
        known = [r[0] for r in roots]
        flag = '' if dflt in known else '   <- names no instance we can see'
        out('default:     %-10s %s%s' % (dflt, config_path(), flag))
    if not roots:
        out('known:       (none found under %s)' % roots_dir())
        return WARN
    label = 'known:'
    for name, w, posix in roots:
        mark = ' *' if name == here else '  '
        out('%-12s%s %-10s %s' % (label, mark, name, w))
        if verbose:
            out('%-12s   %-10s %s' % ('', '', posix))
        label = ''
    sys.stdout.write('\n')
    out('* is this shell. "cygroot <name>" changes the default, not this shell.')
    return OK if here else WARN


def main(argv=None):
    """Returns an exit status. Raises nothing a caller has to catch."""
    argv = list(sys.argv[1:] if argv is None else argv)
    out = lambda m: sys.stdout.write('  %s\n' % m)

    mode = None          # None means --status
    fmt = None           # a cygpath format flag, applied by cygpath itself
    user = None
    names = []
    dry = verbose = debug = False

    flag_modes = {'--status': 'status', '--which': 'which',
                  '-l': 'list', '--list': 'list',
                  '-b': 'bash', '--bash': 'bash',
                  '--python': 'python', '--home': 'home',
                  '--exists': 'exists',
                  '--default': 'default', '--clear': 'clear',
                  '--install': 'install'}
    # cygpath's three useful letters, spelled its way, and nothing else: this
    # is not a second cygpath. The rest of its surface earns nothing here --
    # -a because these paths are already absolute, -s and -d because every
    # component of C:\-\rhel\root is already 8.3, -p because in cygpath it
    # means "NAME is a PATH list" and would be a different job under the same
    # letter. cygpath itself is one pipe away when you want them.
    type_flags = {'-u': '-u', '--unix': '-u',
                  '-w': '-w', '--windows': '-w',
                  '-m': '-m', '--mixed': '-m'}

    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ('-h', '--help'):
            sys.stdout.write(USAGE)
            return OK
        if a == '--version':
            sys.stdout.write('cygroot %s\n' % __version__)
            return OK
        if a in ('-n', '--dry-run'):
            dry = True
        elif a in ('-v', '--verbose'):
            verbose = True
        elif a in ('-d', '--debug'):
            debug = True
            verbose = True
        elif a in type_flags:
            if fmt is not None and fmt != type_flags[a]:
                sys.stderr.write('cygroot: %s asks for a different path form '
                                 'than the one already given; pick one\n' % a)
                return GAP
            fmt = type_flags[a]
        elif a == '--user':
            if i + 1 >= len(argv):
                sys.stderr.write('cygroot: --user wants a name\n')
                sys.stderr.write('   RUN: cygroot --help\n')
                return GAP
            i += 1
            user = argv[i]
        elif a in flag_modes:
            if mode is not None and mode != flag_modes[a]:
                sys.stderr.write('cygroot: %s and --%s ask for different '
                                 'things; pick one\n' % (a, mode))
                return GAP
            mode = flag_modes[a]
        elif a.startswith('-'):
            sys.stderr.write('cygroot: unknown option: %s\n' % a)
            sys.stderr.write('   RUN: cygroot --help\n')
            return GAP
        else:
            names.append(a)
        i += 1

    if debug:
        out('dbg:  argv       %r' % (argv,))
        out('dbg:  CYGROOT_DIR    %s' % (os.environ.get('CYGROOT_DIR') or
                                         '(unset)'))
        out('dbg:  CYGROOT_CONFIG %s' % (os.environ.get('CYGROOT_CONFIG') or
                                         '(unset)'))

    try:
        return _dispatch(mode, fmt, names, out, dry, verbose, user)
    except CygrootError:
        e = sys.exc_info()[1]
        sys.stderr.write('cygroot: %s\n' % e.what)
        if e.why:
            sys.stderr.write('        %s\n' % e.why)
        if e.run:
            sys.stderr.write('   RUN: %s\n' % e.run)
        return GAP


def _one(names, roots):
    """The instance a reporting flag is about: the one named, or this one."""
    if len(names) > 1:
        raise CygrootError('one instance at a time: %s' % ' '.join(names),
                           None, 'cygroot --list')
    if names:
        return resolve(names[0], roots)
    here = this_root_name(roots)
    if here is None:
        raise CygrootError(
            'this shell is not in any instance under %s' % roots_dir(),
            'Name one, or point CYGROOT_DIR at where they live.',
            'cygroot --list')
    return resolve(here, roots)


def _dispatch(mode, fmt, names, out, dry, verbose, user=None):
    if mode == 'exists':
        # A predicate, so it answers in the exit status and says nothing.
        # Never raises for the case it exists to test.
        try:
            roots = known_roots()
        except CygrootError:
            return WARN
        if names:
            known = [r[0].lower() for r in roots]
            hit = all(n.lower() in known for n in names)
        else:
            hit = this_root_name(roots) is not None
        if verbose:
            out('%s' % ('yes' if hit else 'no'))
        return OK if hit else WARN

    if mode is None and fmt is not None:
        mode = 'path'                   # a format flag alone asks for a path
    if mode in (None, 'status'):
        if names:                       # a bare name means: set the default
            return _set(names, out, dry, verbose)
        return _report(out, verbose)

    if mode == 'install':
        return _install(names, out, dry)

    if mode == 'clear':
        p = config_path()
        if read_default() is None:
            out('no default set; nothing to clear (%s)' % p)
            return OK
        if dry:
            out('would clear the default in %s' % p)
            return OK
        clear_default(p)
        out('default cleared (%s)' % p)
        return OK

    if mode == 'which':
        roots = known_roots()
        here = this_root_name(roots)
        if here is None:
            raise CygrootError(
                'this shell is not in any instance under %s' % roots_dir(),
                'It is %s, which is not one of them.' % this_root_windows(),
                'cygroot --list')
        sys.stdout.write('%s\n' % here)
        return OK

    if mode == 'list':
        for name, _w, _p in known_roots():
            sys.stdout.write('%s\n' % name)
        return OK

    if mode == 'default':
        d = read_default()
        if d is None:
            return WARN
        sys.stdout.write('%s\n' % d)
        return OK

    # Paths. cygpath does the conversion; this only decides what to convert,
    # so -m and --dos behave exactly as they do everywhere else on the box.
    roots = known_roots()
    _name, _win, posix = _one(names, roots)
    rc = OK
    if mode == 'bash':
        target = os.path.join(posix, 'bin', 'bash.exe')
        fmt = fmt or '-w'   # what a Windows-side caller is asking for
    elif mode == 'python':
        target = interpreter_of(posix)
        fmt = fmt or '-w'
    elif mode == 'home':
        target = home_of(posix, user)
        # Printed either way. Where it went is the useful half of the answer
        # even when it is not there, and the status carries the rest.
        if not os.path.isdir(target):
            rc = WARN
            if verbose:
                sys.stderr.write('cygroot: no such directory: %s\n' % target)
    else:
        target = posix
    sys.stdout.write('%s\n' % cygpath(fmt or '-u', target))
    return rc


def _set(names, out, dry, verbose):
    if len(names) > 1:
        raise CygrootError('one instance at a time: %s' % ' '.join(names),
                           None, 'cygroot --list')
    roots = known_roots()
    name, win, _posix = resolve(names[0], roots)
    was = read_default()
    p = config_path()
    if was == name:
        out('default is already %s (%s)' % (name, p))
        return OK
    if dry:
        out('would set the default to %-10s %s' % (name, win))
        out('would write %s (currently %s)' % (p, was or 'unset'))
        return OK
    write_default(name, p)
    out('default: %-10s %s' % (name, win))
    if was:
        out('was:     %s' % was)
    if verbose:
        out('written: %s' % p)
    out('This changes what other callers pick. It does not move this shell.')
    return OK


def _install(names, out, dry):
    roots = known_roots()
    if names:
        targets = [resolve(n, roots) for n in names]
    else:
        targets = roots
    if not targets:
        raise CygrootError('no instances to install into.',
                           'None were found under %s.' % roots_dir(),
                           'cygroot --list')
    rc = OK
    for name, _win, posix in targets:
        dest = os.path.join(posix, 'usr', 'local', 'bin', 'cygroot.py')
        if dry:
            out('would install %-10s %s' % (name, dest))
            continue
        try:
            mod, cmd = install_to(posix)
            out('installed %-10s %s' % (name, mod))
            out('          %-10s %s' % ('', cmd))
        except CygrootError:
            e = sys.exc_info()[1]
            # One instance missing /usr/local/bin must not stop the others.
            out('skipped   %-10s %s' % (name, e.what))
            rc = WARN
    return rc


if __name__ == '__main__':
    sys.exit(main())
