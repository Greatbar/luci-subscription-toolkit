#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""The required local gate. No Git mutation, push, tag, upload or release."""
import sys
sys.dont_write_bytecode = True
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import pathlib
import subprocess
import tarfile
import tempfile
import zlib
import os
from security import (APK_NAME, SOURCE_NAME, EPOCH, SecurityError, Snapshot,
                      check_release_directory, verify_payload, git, read_regular)
from audit import audit_snapshot, gitleaks

ROOT = pathlib.Path(__file__).resolve().parents[1]


def verify_tools(snapshot, apk, executable):
    """Check extracted executables against the hash-pinned public archives."""
    locks = json.loads(snapshot.files['tools/sources.lock.json'][0])
    for key in ('gitleaks', 'imagebuilder'):
        archive = ROOT/'.build'/locks[key]['file']
        data, _ = read_regular(ROOT, '.build/'+locks[key]['file'])
        if hashlib.sha256(data).hexdigest() != locks[key]['sha256']:
            raise SecurityError('public tool archive checksum mismatch: '+key)
        if key == 'gitleaks':
            with tarfile.open(fileobj=io.BytesIO(data)) as package:
                expected = package.extractfile('gitleaks').read()
            actual = pathlib.Path(executable)
        else:
            try:
                from compression import zstd
            except ImportError:
                with tempfile.TemporaryFile() as stream:
                    subprocess.run(['zstd','-dc',str(archive)],stdout=stream,check=True)
                    stream.seek(0)
                    with tarfile.open(fileobj=stream) as package:
                        expected = next(package.extractfile(m).read() for m in package
                                        if m.name.endswith('/staging_dir/host/bin/.apk.bin') and m.isfile())
            else:
                with zstd.open(io.BytesIO(data),'rb') as stream, tarfile.open(fileobj=stream,mode='r|') as package:
                    expected = next(package.extractfile(m).read() for m in package
                                    if m.name.endswith('/staging_dir/host/bin/.apk.bin') and m.isfile())
            actual = pathlib.Path(apk).absolute().with_name('.apk.bin')
        # Executable paths are operator-supplied public tools, not publication data.
        if actual.is_symlink() or not actual.is_file() or actual.read_bytes() != expected:
            raise SecurityError('extracted public tool mismatch: '+key)


def source_archive(snapshot, target):
    with target.open('wb') as stream, gzip.GzipFile(filename='', mode='wb', fileobj=stream, mtime=EPOCH) as zipped:
        with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as archive:
            for name, (data, mode) in sorted(snapshot.files.items()):
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                entry.mode = mode
                entry.mtime = EPOCH
                entry.uid = entry.gid = 0
                entry.uname = entry.gname = 'root'
                archive.addfile(entry, io.BytesIO(data))


def verify_archive(snapshot, target):
    with tarfile.open(target) as archive:
        members = archive.getmembers()
        if len(members) != len(snapshot.files) or {m.name for m in members} != set(snapshot.files):
            raise SecurityError('source archive member set mismatch')
        for member in members:
            data, mode = snapshot.files[member.name]
            if not member.isfile() or member.mode != mode or archive.extractfile(member).read() != data:
                raise SecurityError('source archive mismatch: ' + member.name)


def check_apk(snapshot, apk, artifact, directory, executable):
    spec = importlib.util.spec_from_file_location('toolkit_builder', ROOT/'tools/build-podkop-tools.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    native = builder.apk_executable(apk)
    raw = artifact.read_bytes()
    if raw[:4] != b'ADBd':
        raise SecurityError('unexpected APK format')
    decompressor = zlib.decompressobj(-15)
    decompressor.decompress(raw[4:])
    decompressor.flush()
    if not decompressor.eof or decompressor.unused_data or decompressor.unconsumed_tail:
        raise SecurityError('APK trailing or incomplete data')
    metadata = subprocess.run([native, 'adbdump', str(artifact)], check=True, capture_output=True, text=True).stdout
    if 'license: GPL-2.0-only' not in metadata or "'!luci-app-podkop-tools'" not in metadata:
        raise SecurityError('APK license/conflict mismatch')
    # Embedded scripts must equal the approved bytes, including the terminal newline.
    for name in ('post-install', 'pre-deinstall'):
        expected = snapshot.files['scripts/'+name][0].decode()
        block = '  '+name+': |\n'+''.join('    '+line+'\n' for line in expected.splitlines())
        if block not in metadata:
            raise SecurityError('APK install script mismatch: '+name)
    directory.mkdir()
    subprocess.run([native, 'extract', '--allow-untrusted', '--no-chown', '--destination', str(directory), str(artifact)],
                   check=True, capture_output=True)
    verify_payload(snapshot, directory)
    gitleaks(executable, 'dir', directory, directory.parent/'payload-gitleaks.json')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--apk', default=str(ROOT/'.build/openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64/staging_dir/host/bin/apk'))
    p.add_argument('--gitleaks', default=str(ROOT/'.build/gitleaks'))
    p.add_argument('--output', default=str(ROOT/'dist'))
    p.add_argument('--require-head', action='store_true', help='push gate: candidate must equal HEAD tree')
    a = p.parse_args()
    output = pathlib.Path(a.output).absolute()
    check_release_directory(output)
    snapshot = Snapshot(ROOT)
    try:
        if a.require_head and git(ROOT, 'rev-parse', 'HEAD^{tree}').decode().strip() != snapshot.tree:
            raise SecurityError('candidate differs from HEAD; an authorized commit and rerun are required')
        verify_tools(snapshot, a.apk, a.gitleaks)
        with tempfile.TemporaryDirectory(prefix='toolkit-prepublish-') as tmp:
            tmp = pathlib.Path(tmp)
            export = tmp/'source'
            snapshot.export(export)
            subprocess.run([sys.executable, '-B', str(export/'tools/generate-fixtures.py'), '--check'], check=True)
            version = subprocess.run([a.gitleaks, 'version'], check=True, capture_output=True, text=True).stdout.strip()
            if version != json.loads(snapshot.files['tools/sources.lock.json'][0])['gitleaks']['version']:
                raise SecurityError('unreviewed Gitleaks version')
            report = audit_snapshot(snapshot, a.gitleaks, history=True)
            spec = importlib.util.spec_from_file_location('toolkit_builder', ROOT/'tools/build-podkop-tools.py')
            builder = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(builder)
            release = tmp/'release'
            artifact = builder.build(snapshot, a.apk, release)
            check_apk(snapshot, a.apk, artifact, tmp/'payload', a.gitleaks)
            source_archive(snapshot, release/SOURCE_NAME)
            verify_archive(snapshot, release/SOURCE_NAME)
            sums = ''.join(hashlib.sha256((release/name).read_bytes()).hexdigest()+'  '+name+'\n'
                           for name in sorted((APK_NAME, SOURCE_NAME)))
            (release/'SHA256SUMS').write_text(sums)
            check_release_directory(release, complete=True)
            snapshot.verify_unchanged()
            check_release_directory(output)
            output.mkdir(parents=True, exist_ok=True)
            for name in (APK_NAME, SOURCE_NAME, 'SHA256SUMS'):
                # Atomic replacement never follows an output symlink or hardlink.
                with tempfile.NamedTemporaryFile(dir=output, prefix='.prepublish-', delete=False) as stream:
                    temporary = pathlib.Path(stream.name)
                    stream.write((release/name).read_bytes())
                    stream.flush()
                    os.fsync(stream.fileno())
                temporary.chmod(0o644)
                os.replace(temporary, output/name)
            check_release_directory(output, complete=True)
            verify_archive(snapshot, output/SOURCE_NAME)
            if (output/'SHA256SUMS').read_text() != sums:
                raise SecurityError('release checksums mismatch')
            for name in (APK_NAME, SOURCE_NAME):
                if (output/name).read_bytes() != (release/name).read_bytes():
                    raise SecurityError('release bytes mismatch: '+name)
            report.update(apk_sha256=hashlib.sha256(artifact.read_bytes()).hexdigest(),
                          release_files=sorted((APK_NAME, SOURCE_NAME, 'SHA256SUMS')), payload_files=19)
            receipt = ROOT/'.build/prepublish.json'
            receipt.parent.mkdir(exist_ok=True)
            receipt.write_text(json.dumps(report, indent=2)+'\n')
            print(json.dumps({k:v for k,v in report.items() if k!='pattern_findings'}, indent=2))
    finally:
        snapshot.close()


if __name__ == '__main__':
    try:
        main()
    except (SecurityError, OSError, ValueError, subprocess.CalledProcessError) as e:
        print('BLOCKED: '+(str(e) if isinstance(e, SecurityError) else type(e).__name__), file=sys.stderr)
        raise SystemExit(1)
