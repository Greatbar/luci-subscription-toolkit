#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
"""Package only an inspected immutable Git tree using the explicit payload policy."""
import sys
sys.dont_write_bytecode = True
import argparse
import hashlib
import pathlib
import subprocess
import tempfile
import os
from security import APK_NAME, EPOCH, SecurityError, Snapshot, stage_payload


def apk_executable(path):
    path = pathlib.Path(path).absolute()
    native = path.with_name('.apk.bin')
    return str(native if native.exists() else path)


def build(snapshot, apk, output):
    output = pathlib.Path(output)
    from security import check_release_directory
    check_release_directory(output)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='toolkit-build-') as tmp:
        payload = pathlib.Path(tmp) / 'payload'
        stage_payload(snapshot, payload)
        args = [apk_executable(apk), 'mkpkg', '--info', 'name:luci-app-subscription-toolkit',
                '--info', 'version:0.1.0-r6', '--info', 'arch:noarch', '--info', 'license:GPL-2.0-only',
                '--info', 'description:Isolated subscription and throughput tools for stock Podkop',
                '--info', 'depends:!luci-app-podkop-tools podkop sing-box luci-base rpcd ucode ucode-mod-fs ucode-mod-uci liblucihttp-ucode curl jq bind-dig coreutils-timeout coreutils-nohup',
                '--files', str(payload), '--output', str(output / APK_NAME)]
        for name in ('post-install', 'pre-deinstall'):
            args += ['--script', name + ':' + str(payload / 'usr/share/podkop-tools' / name)]
        subprocess.run(['fakeroot', '/bin/sh', '-c',
                        'set -e; chown -R 0:0 "$1"; shift; exec "$@"', 'toolkit-build', str(payload), *args],
                       check=True, env={**os.environ, 'SOURCE_DATE_EPOCH': str(EPOCH), 'LC_ALL': 'C', 'TZ': 'UTC'})
        snapshot.verify_unchanged()
        artifact = output / APK_NAME
        metadata = subprocess.run([apk_executable(apk), 'adbdump', str(artifact)], check=True,
                                  capture_output=True, text=True).stdout
        if any(l.strip().startswith(('user:', 'group:')) and l.split(':', 1)[1].strip() != 'root'
               for l in metadata.splitlines()):
            raise SecurityError('non-root APK owner')
        (output / 'SHA256SUMS').write_text(hashlib.sha256(artifact.read_bytes()).hexdigest() + '  ' + APK_NAME + '\n')
        return artifact


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--apk')
    p.add_argument('--output', required=True)
    p.add_argument('--stage-only', action='store_true')
    a = p.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    snapshot = Snapshot(root)
    try:
        if a.stage_only:
            stage_payload(snapshot, a.output)
            snapshot.verify_unchanged()
        else:
            if not a.apk:
                raise SecurityError('--apk is required')
            output = pathlib.Path(a.output).absolute()
            from security import check_release_directory
            if output == root / 'dist':
                check_release_directory(output)
            print(build(snapshot, a.apk, output))
    finally:
        snapshot.close()


if __name__ == '__main__':
    try:
        main()
    except (SecurityError, OSError, ValueError, subprocess.CalledProcessError) as e:
        print('BLOCKED: ' + (str(e) if isinstance(e, SecurityError) else type(e).__name__), file=sys.stderr)
        raise SystemExit(1)
