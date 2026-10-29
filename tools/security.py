# SPDX-License-Identifier: GPL-2.0-only
"""Shared fail-closed source, immutable Git-tree and payload policy."""
import hashlib
import json
import os
import pathlib
import stat
import subprocess
import tempfile

EPOCH = 1700000000
APK_NAME = 'luci-app-subscription-toolkit-0.3.0-r1.apk'
SOURCE_NAME = 'luci-subscription-toolkit-0.3.0-r1-source.tar.gz'
RELEASE_FILES = {APK_NAME, SOURCE_NAME, 'SHA256SUMS'}
# Exact repository-relative directories, never matching a name at another depth.
LOCAL_DIRECTORIES = {'.git', '.build', 'dist', 'node_modules', 'test-results', 'playwright-report'}
# Managed workspace read-only mount placeholders; only empty directories qualify.
EMPTY_LOCAL_DIRECTORIES = {'.agents', '.codex', '.aws'}


class SecurityError(RuntimeError):
    pass


def safe_path(name):
    p = pathlib.PurePosixPath(name)
    if not isinstance(name, str) or not name or p.is_absolute() or str(p) != name or any(x in ('', '.', '..') for x in name.split('/')):
        raise SecurityError('invalid manifest path')
    return name


def inspect_tree(root, allowed, exclusions=LOCAL_DIRECTORIES):
    """lstat every publication object before any reads; never follow links."""
    root = pathlib.Path(root)
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise SecurityError('source root is not a real directory')
    allowed = {safe_path(x) for x in allowed}
    directories = {str(p) for name in allowed for p in pathlib.PurePosixPath(name).parents if str(p) != '.'}
    found = set()

    def walk(directory, prefix=''):
        for entry in sorted(os.scandir(directory), key=lambda x: x.name):
            name = prefix + entry.name
            st = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                raise SecurityError('symlink rejected: ' + name)
            if name in EMPTY_LOCAL_DIRECTORIES:
                if not stat.S_ISDIR(st.st_mode):
                    raise SecurityError('nonempty managed placeholder: ' + name)
                with os.scandir(entry.path) as contents:
                    if next(contents, None) is not None:
                        raise SecurityError('nonempty managed placeholder: ' + name)
                continue
            if name in exclusions:
                if not stat.S_ISDIR(st.st_mode):
                    raise SecurityError('local exclusion is not a directory: ' + name)
                continue
            if stat.S_ISDIR(st.st_mode):
                if name not in directories:
                    raise SecurityError('unexpected directory: ' + name)
                walk(entry.path, name + '/')
            elif stat.S_ISREG(st.st_mode):
                if name not in allowed:
                    raise SecurityError('unexpected file: ' + name)
                if st.st_nlink != 1:
                    raise SecurityError('hardlinked source rejected: ' + name)
                found.add(name)
            else:
                raise SecurityError('special object rejected: ' + name)
    walk(root)
    if found != allowed:
        raise SecurityError('missing publication files: ' + ', '.join(sorted(allowed - found)))


def read_regular(root, name):
    """openat/O_NOFOLLOW on every component closes the check/copy link race."""
    safe_path(name)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parts = name.split('/')
        for part in parts[:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(file_fd, 'rb') as stream:
            st = os.fstat(stream.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise SecurityError('non-regular source: ' + name)
            data = stream.read()
            after = os.fstat(stream.fileno())
            if (st.st_size, st.st_mtime_ns, st.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise SecurityError('source changed while reading: ' + name)
            return data, 0o755 if st.st_mode & 0o111 else 0o644
    finally:
        os.close(fd)


def git_env(root, **extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_NO_REPLACE_OBJECTS='1')
    env.update(extra)
    return env


def git(root, *args, env=None, data=None):
    result = subprocess.run(['git', '--git-dir=' + str(root / '.git'), '--work-tree=' + str(root), *args],
                            input=data, capture_output=True, env=env or git_env(root))
    if result.returncode:
        raise SecurityError('Git operation failed: ' + args[0])
    return result.stdout


class Snapshot:
    """Candidate tree objects live only in a disposable object store, no commit."""
    def __init__(self, root):
        self.root = pathlib.Path(root).absolute()
        raw, _ = read_regular(self.root, 'tools/publication-files.json')
        self.names = json.loads(raw)
        if not isinstance(self.names, list) or len(set(self.names)) != len(self.names):
            raise SecurityError('invalid publication manifest')
        inspect_tree(self.root, self.names)
        check_release_directory(self.root / 'dist')
        if not stat.S_ISDIR((self.root / '.git').lstat().st_mode):
            raise SecurityError('controlled Git checkout required')
        for directory, dirs, files in os.walk(self.root / '.git', followlinks=False):
            for name in dirs + files:
                mode = (pathlib.Path(directory) / name).lstat().st_mode
                if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                    raise SecurityError('nonregular object in Git directory')
        for name in ('objects/info/alternates', 'info/grafts', 'shallow', 'refs/replace'):
            if (self.root / '.git' / name).exists():
                raise SecurityError('unsupported Git indirection: ' + name)
        tracked = {line.split(b'\t', 1)[1].decode() for line in git(self.root, 'ls-tree', '-rz', 'HEAD').split(b'\0') if line}
        if not tracked <= set(self.names):
            raise SecurityError('Git tracks files outside the publication manifest')
        self.files = {name: read_regular(self.root, name) for name in self.names}
        inspect_tree(self.root, self.names)
        from audit import key, validate_findings
        accepted = {key(f) for f in json.loads(self.files['tools/audit-allowlist.json'][0])}
        for name, (data, mode) in self.files.items():
            validate_findings(data, name, accepted)
        payload_entries(self)
        self.tmp = tempfile.TemporaryDirectory(prefix='toolkit-snapshot-')
        base = pathlib.Path(self.tmp.name)
        (base / 'objects').mkdir()
        self.env = git_env(self.root, GIT_INDEX_FILE=str(base / 'index'), GIT_OBJECT_DIRECTORY=str(base / 'objects'),
                           GIT_ALTERNATE_OBJECT_DIRECTORIES=str(self.root / '.git/objects'))
        git(self.root, 'read-tree', '--empty', env=self.env)
        index = []
        for name, (data, mode) in sorted(self.files.items()):
            oid = git(self.root, 'hash-object', '-w', '--stdin', '--no-filters', env=self.env, data=data).strip().decode()
            index.append(f'{100755 if mode == 0o755 else 100644} {oid}\t{name}\n')
        git(self.root, 'update-index', '--index-info', env=self.env, data=''.join(index).encode())
        self.tree = git(self.root, 'write-tree', env=self.env).strip().decode()
        # Read the immutable objects back; packaging never reads live source files.
        for line in git(self.root, 'ls-tree', '-rz', self.tree, env=self.env).split(b'\0'):
            if not line:
                continue
            header, name = line.split(b'\t', 1)
            mode, kind, oid = header.split()
            data = git(self.root, 'cat-file', 'blob', oid.decode(), env=self.env)
            self.files[name.decode()] = (data, int(mode, 8) & 0o777)

    def close(self):
        self.tmp.cleanup()

    def verify_unchanged(self):
        inspect_tree(self.root, self.names)
        for name, value in self.files.items():
            if read_regular(self.root, name) != value:
                raise SecurityError('source changed after snapshot: ' + name)

    def export(self, destination):
        destination = pathlib.Path(destination)
        destination.mkdir()
        for name, (data, mode) in self.files.items():
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(mode)


def payload_entries(snapshot):
    entries = json.loads(snapshot.files['tools/payload.json'][0])
    sources, targets = set(), set()
    for e in entries:
        source, target = safe_path(e['source']), safe_path(e['target'])
        if source not in snapshot.files or source in sources or target in targets or e['mode'] not in (0o600, 0o644, 0o755):
            raise SecurityError('invalid payload manifest')
        sources.add(source)
        targets.add(target)
        if hashlib.sha256(snapshot.files[source][0]).hexdigest() != e['sha256']:
            raise SecurityError('unreviewed payload source bytes: ' + source)
    expected = {n for n in snapshot.names if n.startswith(('root/', 'htdocs/', 'scripts/'))}
    if sources != expected:
        raise SecurityError('payload manifest does not cover exactly root/htdocs/scripts')
    return entries


def stage_payload(snapshot, destination):
    destination = pathlib.Path(destination)
    if destination.exists() or destination.is_symlink():
        if not stat.S_ISDIR(destination.lstat().st_mode):
            raise SecurityError('payload destination is not a real directory')
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise SecurityError('payload destination must be empty')
    for e in payload_entries(snapshot):
        target = destination / e['target']
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(snapshot.files[e['source']][0])
        target.chmod(e['mode'])
    for entry in sorted(destination.rglob('*'), reverse=True):
        if entry.is_dir():
            entry.chmod(0o755)
        os.utime(entry, (EPOCH, EPOCH))
    destination.chmod(0o755)
    os.utime(destination, (EPOCH, EPOCH))


def check_release_directory(directory, complete=False):
    directory = pathlib.Path(directory)
    if not directory.exists() and not directory.is_symlink():
        if complete:
            raise SecurityError('missing release directory')
        return
    if not stat.S_ISDIR(directory.lstat().st_mode):
        raise SecurityError('release directory must not be a link')
    names = set()
    for entry in directory.iterdir():
        if not stat.S_ISREG(entry.lstat().st_mode) or entry.lstat().st_nlink != 1 or entry.name not in RELEASE_FILES:
            raise SecurityError('unexpected release object: ' + entry.name)
        names.add(entry.name)
    if complete and names != RELEASE_FILES:
        raise SecurityError('release file set mismatch')


def verify_payload(snapshot, directory):
    entries = payload_entries(snapshot)
    inspect_tree(directory, {e['target'] for e in entries}, exclusions=set())
    for e in entries:
        data, _ = read_regular(directory, e['target'])
        if data != snapshot.files[e['source']][0] or (directory / e['target']).lstat().st_mode & 0o777 != e['mode']:
            raise SecurityError('APK payload mismatch: ' + e['target'])
