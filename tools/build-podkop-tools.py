#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
"""Build a noarch OpenWrt APK with native apk-tools. No SDK/router mutations."""
import argparse, hashlib, os, pathlib, shutil, subprocess, tempfile

p = argparse.ArgumentParser()
p.add_argument('--apk', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
source = root
output = pathlib.Path(a.output).resolve(); output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='podkop-tools-build-') as tmp:
    payload = pathlib.Path(tmp) / 'root'
    shutil.copytree(source / 'root', payload)
    shutil.copytree(source / 'htdocs', payload / 'www', dirs_exist_ok=True)
    for script in ['post-install', 'pre-deinstall']:
        target = payload / 'usr/share/podkop-tools' / script
        shutil.copy2(source / 'scripts' / script, target); target.chmod(0o755)
    (payload / 'etc/config/podkop_tools').chmod(0o600)
    (payload / 'etc/config/podkop_tools_subscription').chmod(0o600)
    for name in ['etc/init.d/podkop-tools', 'usr/libexec/rpcd/podkop-tools',
                 'usr/libexec/podkop-tools/task', 'usr/libexec/podkop-tools/generate', 'usr/libexec/podkop-tools/boot']:
        (payload / name).chmod(0o755)
    # Freeze checkout-dependent timestamps and permissions before mkpkg.
    epoch = 1700000000
    for entry in sorted(payload.rglob('*'), reverse=True):
        if entry.is_symlink():
            raise RuntimeError('unexpected payload symlink')
        if entry.is_dir(): entry.chmod(0o755)
        elif str(entry.relative_to(payload)) not in ['etc/config/podkop_tools', 'etc/config/podkop_tools_subscription']:
            entry.chmod(0o755 if entry.stat().st_mode & 0o111 else 0o644)
        os.utime(entry, (epoch, epoch))
    payload.chmod(0o755); os.utime(payload, (epoch, epoch))
    artifact = output / 'luci-app-subscription-toolkit-0.1.0-r6.apk'
    native = pathlib.Path(a.apk).resolve().with_name('.apk.bin')
    builder = str(native) if native.exists() else a.apk
    args = [builder, 'mkpkg', '--info', 'name:luci-app-subscription-toolkit', '--info', 'version:0.1.0-r6',
            '--info', 'arch:noarch', '--info', 'license:GPL-2.0-only', '--info',
            'description:Isolated subscription and throughput tools for stock Podkop', '--info',
            'depends:!luci-app-podkop-tools podkop sing-box luci-base rpcd ucode ucode-mod-fs ucode-mod-uci liblucihttp-ucode curl jq bind-dig coreutils-timeout coreutils-nohup',
            '--files', str(payload), '--output', str(artifact), '--script',
            'post-install:' + str(source / 'scripts/post-install'), '--script',
            'pre-deinstall:' + str(source / 'scripts/pre-deinstall')]
    subprocess.run(['fakeroot', '/bin/sh', '-c', 'set -e; chown -R 0:0 "$1"; shift; exec "$@"', 'podkop-tools-build', str(payload), *args], check=True, env={**os.environ, 'SOURCE_DATE_EPOCH': str(epoch), 'LC_ALL': 'C', 'TZ': 'UTC'})
    metadata = subprocess.run([builder, 'adbdump', str(artifact)], check=True, capture_output=True, text=True).stdout
    if any(line.strip().startswith(('user:', 'group:')) and line.split(':', 1)[1].strip() != 'root' for line in metadata.splitlines()):
        artifact.unlink()
        raise RuntimeError('APK contains non-root file owners')
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    (output / 'SHA256SUMS').write_text(digest + '  ' + artifact.name + '\n')
    print(artifact)
