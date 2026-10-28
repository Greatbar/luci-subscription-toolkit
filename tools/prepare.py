#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
"""Fetch hash-pinned public inputs. No router access or private inputs."""
import argparse, hashlib, json, pathlib, shutil, subprocess, tarfile, tempfile
from urllib.request import urlopen
ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build'
def run(*args): subprocess.run(args, check=True)
def fetch(item):
    target = BUILD / item['file']; target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        partial = target.with_name(target.name + '.partial')
        try:
            with urlopen(item['url'], timeout=60) as source, partial.open('wb') as output:
                shutil.copyfileobj(source, output)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != item['sha256']:
                raise RuntimeError('download checksum mismatch: ' + item['file'])
            partial.replace(target)
        finally:
            partial.unlink(missing_ok=True)
    if hashlib.sha256(target.read_bytes()).hexdigest() != item['sha256']:
        raise RuntimeError('cached checksum mismatch: ' + item['file'])
    return target
def archive_filter(member, destination):
    # ImageBuilder includes host-tool links; none are needed for native apk.
    try: return tarfile.data_filter(member, destination)
    except (tarfile.AbsoluteLinkError, tarfile.LinkOutsideDestinationError): return None
def extract(path):
    if path.suffix == '.zst':
        try:
            from compression import zstd
        except ImportError:
            with tempfile.TemporaryFile() as output:
                subprocess.run(['zstd', '-dc', str(path)], stdout=output, check=True); output.seek(0)
                with tarfile.open(fileobj=output, mode='r|') as archive:
                    archive.extractall(BUILD, filter=archive_filter)
        else:
            with zstd.open(path, 'rb') as stream, tarfile.open(fileobj=stream, mode='r|') as archive:
                archive.extractall(BUILD, filter=archive_filter)
    else:
        with tarfile.open(path) as archive: archive.extractall(BUILD, filter='data')
def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--lab', action='store_true'); parser.add_argument('--audit', action='store_true'); parser.add_argument('--compat', action='store_true'); args=parser.parse_args()
    lock=json.loads((ROOT/'tools/sources.lock.json').read_text()); BUILD.mkdir(exist_ok=True)
    for key in ('imagebuilder','podkop','sing-box'):
        item=lock[key]; archive=fetch(item)
        directory=BUILD / {'imagebuilder':'openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64','podkop':'podkop-0.7.22','sing-box':'sing-box-1.14.2-linux-amd64-musl'}[key]
        # A checksum stamp is written only after complete extraction.
        stamp=directory / '.toolkit-extracted'
        if not stamp.exists() or stamp.read_text()!=item['sha256']:
            if directory.exists(): shutil.rmtree(directory)
            extract(archive); stamp.write_text(item['sha256'])
        print('Verified public input:',key,flush=True)
    fetch(lock['sing-box-init'])
    if args.compat:
        for key, item in lock['compatibility_inputs'].items():
            archive = fetch(item); directory = BUILD / item['directory']
            stamp = directory / '.toolkit-extracted'
            if not stamp.exists() or stamp.read_text() != item['sha256']:
                if directory.exists(): shutil.rmtree(directory)
                extract(archive); stamp.write_text(item['sha256'])
            print('Verified compatibility input:', key, flush=True)
        host = BUILD / 'openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64/staging_dir/host/bin'
        native_apk = host / '.apk.bin'
        if not native_apk.exists(): native_apk = host / 'apk'
        destination = BUILD / 'compat-resources/apk'
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(native_apk, destination)
    if args.audit: extract(fetch(lock['gitleaks']))
    if args.lab:
        run('docker','pull',lock['python_fixture']['image'])
        run('docker','pull',lock['browser_fixture']['image'])
        fetch(lock['rootfs'])
        for item in lock['lab_dependencies']['packages']: fetch(item)
        context=BUILD/'lab-context';context.mkdir(exist_ok=True)
        shutil.copy2(BUILD/'rootfs.tar.gz',context/'rootfs.tar.gz')
        deps=context/'deps';deps.mkdir(exist_ok=True)
        for item in lock['lab_dependencies']['packages']:shutil.copy2(BUILD/item['file'],deps/pathlib.Path(item['file']).name)
        shutil.copy2(ROOT/'tests/lab/Dockerfile',context/'Dockerfile')
        run('docker','build','--network=none','-t','subscription-toolkit-openwrt:25.12.5',str(context))
if __name__=='__main__': main()
