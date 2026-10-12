#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Construct every fixture field from public constants; no input data is read."""
import argparse
import base64
import json
import pathlib

DOMAIN = 'node.example.invalid'
UUID = '00000000-0000-4000-8000-000000000001'
# Nonsecret sequential bytes, never a production key.
PUBLIC_KEY = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('=')
SHORT_ID = '0000000000000001'


def fixture_bytes(legacy_tls=False):
    provider = [{'remarks': 'Synthetic node' if legacy_tls else 'Generated synthetic node', 'outbounds': [{
        'protocol': 'vless', 'settings': {'vnext': [{
            'address': DOMAIN, 'port': 443, 'users': [{'id': UUID, 'encryption': 'none'}]}]},
        'streamSettings': {'network': 'tcp', 'security': 'reality',
                           'realitySettings': {'serverName': DOMAIN, 'publicKey': PUBLIC_KEY,
                                               'shortId': SHORT_ID, 'fingerprint': 'chrome'}}}]}]
    outbounds = {'outbounds': [{'type': 'vless', 'server': DOMAIN, 'server_port': 443,
        'uuid': UUID, 'tls': {'enabled': True, 'server_name': DOMAIN,
                            'utls': {'enabled': True, 'fingerprint': 'chrome'},
                            'reality': {'enabled': True, 'public_key': PUBLIC_KEY, 'short_id': SHORT_ID}}}]}
    # Reconstruct the complete initial-commit fixtures from these same constants.
    # This certifies every historical field, without reading or sanitizing inputs.
    if legacy_tls:
        provider[0]['outbounds'][0]['streamSettings'] = {
            'network': 'tcp', 'security': 'tls', 'tlsSettings': {'serverName': DOMAIN}}
        outbounds['outbounds'][0]['tls'] = {'enabled': True, 'server_name': DOMAIN}
    return {name: (json.dumps(data, indent=2, ensure_ascii=False) + '\n').encode()
            for name, data in [('provider.json', provider), ('outbounds.json', outbounds)]}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--check', action='store_true')
    a = p.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1] / 'tests/fixtures'
    for name, data in fixture_bytes().items():
        path = root / name
        if path.is_symlink():
            raise SystemExit('fixture symlink rejected: ' + name)
        if a.check:
            if path.read_bytes() != data:
                raise SystemExit('synthetic fixture byte mismatch: ' + name)
        else:
            path.write_bytes(data)
    print('PASS deterministic synthetic fixtures' if a.check else 'Generated synthetic fixtures')


if __name__ == '__main__':
    main()
