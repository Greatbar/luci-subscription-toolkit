#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Focused compatibility matrix in disposable OpenWrt containers; never a router.

Needs the public test resources under .build (see docs/COMPATIBILITY.md).
Uses stock source payloads and official x86_64 binaries with synthetic APK
metadata; this does not certify a device, firmware release, or vendor package.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import shlex
import subprocess
import sys
import time
import types
import urllib.parse

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[2]
PROFILES = {
    'current': ('0.7.22', '1.14.2', 'sing-box-1.14.2-linux-amd64-musl'),
    'legacy': ('0.7.14', '1.12.17', 'sing-box-1.12.17-linux-amd64'),
}
IMAGE = 'subscription-toolkit-openwrt:25.12.5'


def command(*args, check=True, **kwargs):
    return subprocess.run(args, check=check, capture_output=True, text=True, **kwargs)


def context(profile, suite="compat"):
    podkop, sing_box, directory = PROFILES[profile]
    return dict(profile=profile, suite=suite, podkop=podkop, sing_box=sing_box,
                binary=ROOT / '.build' / directory / 'sing-box',
                native=ROOT / '.build' / ('podkop-' + podkop) / 'podkop/files',
                lab=ROOT / ('.build/compat' if suite=='compat' else '.build/integration') / profile,
                main='subscription-toolkit-' + suite + '-' + profile + '-main',
                exit='subscription-toolkit-' + suite + '-' + profile + '-exit',
                driver='subscription-toolkit-' + suite + '-' + profile + '-driver',
                network='subscription-toolkit-' + suite + '-' + profile)


def load_lab(c):
    spec = importlib.util.spec_from_file_location('integration', ROOT / 'tests/podkop-tools/integration.py')
    lab = importlib.util.module_from_spec(spec)
    sys.modules['integration'] = lab
    spec.loader.exec_module(lab)
    lab.MAIN, lab.EXIT, lab.NETWORK, lab.LAB = c['main'], c['exit'], c['network'], c['lab']
    lab.NATIVE = c['native']
    # The borrowed helpers' default container names are bound at import time.
    def cp(source, target, container=None):
        container = container or lab.MAIN
        source = c['binary'] if target == '/usr/bin/sing-box' and container == lab.EXIT else pathlib.Path(source)
        subprocess.run(['docker', 'exec', '-i', container, 'sh', '-c',
                        'cat > "$1" && chmod "$2" "$1"', 'fixture-copy', target,
                        oct(source.stat().st_mode & 0o777)[2:]], input=source.read_bytes(), check=True)
    def write(target, data, container=None):
        path = lab.LAB / 'write.tmp'
        path.write_text(data)
        path.chmod(0o600)
        cp(path, target, container)
        path.unlink()
    lab.cp, lab.write = cp, write
    return lab


def install(c, lab):
    apk = ROOT / '.build/compat-resources/apk'
    def package(name, version, payload, dependencies=None):
        artifact = c['lab'] / (name + '.apk')
        args = ['fakeroot', 'sh', '-c', 'set -e; chown -R 0:0 "$1"; shift; exec "$@"',
                'compat-package', str(payload), str(apk), 'mkpkg', '--info', 'name:' + name,
                '--info', 'version:' + version, '--info', 'arch:noarch']
        if dependencies:
            args += ['--info', 'depends:' + dependencies]
        args += ['--files', str(payload), '--output', str(artifact)]
        subprocess.run(args, check=True, capture_output=True)
        lab.cp(artifact, '/tmp/' + name + '.apk')
        lab.dex('apk', 'add', '--allow-untrusted', '--no-network', '--force-reinstall', '/tmp/' + name + '.apk')
        return artifact
    payload = c['lab'] / 'podkop-payload'
    if payload.exists():
        shutil.rmtree(payload)
    shutil.copytree(c['native'] / 'usr/lib', payload / 'usr/lib/podkop', dirs_exist_ok=True)
    for name in ('usr/bin/podkop', 'etc/init.d/podkop'):
        target = payload / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(c['native'] / name, target)
        target.chmod(0o755)
    const = payload / 'usr/lib/podkop/constants.sh'
    const.write_text(const.read_text().replace('__COMPILED_VERSION_VARIABLE__', c['podkop']))
    package('podkop', c['podkop'] + '-r1', payload)
    payload = c['lab'] / 'sing-box-payload'
    if payload.exists():
        shutil.rmtree(payload)
    for name, source in [('usr/bin/sing-box', c['binary']), ('etc/init.d/sing-box', ROOT / '.build/sing-box.init')]:
        target = payload / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        target.chmod(0o755)
    package('sing-box', c['sing_box'] + '-r1', payload)
    payload = c['lab'] / 'toolkit-payload'
    if payload.exists():
        shutil.rmtree(payload)
    entries = json.loads((ROOT / 'tools/payload.json').read_text())
    for entry in entries:
        target = payload / entry['target']
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / entry['source']).read_bytes())
        target.chmod(entry['mode'])
    # Exercise the actual dependency expression emitted by the public builder,
    # without running the unrelated release/history audit in this WIP worktree.
    import ast
    tree = ast.parse((ROOT / 'tools/build-podkop-tools.py').read_text())
    dependencies = [n.value.removeprefix('depends:') for n in ast.walk(tree)
                    if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value.startswith('depends:')]
    assert len(dependencies) == 1, 'builder dependency contract changed'
    assert not any(x.startswith(('podkop=', 'podkop>', 'podkop<', 'sing-box=', 'sing-box>', 'sing-box<'))
                   for x in dependencies[0].split()), 'unnecessary pinned dependency'
    artifact = package('luci-app-subscription-toolkit', '0.3.0-r0', payload, dependencies[0])
    info = command(str(apk), 'adbdump', str(artifact)).stdout
    assert 'depends:' in info
    # No-network install succeeded with the selected old dependencies retained.
    versions = lab.dex('apk', 'list', '--installed', 'podkop', 'sing-box').stdout
    assert 'podkop-' + c['podkop'] + '-r1' in versions and 'sing-box-' + c['sing_box'] + '-r1' in versions, versions
    (c['lab'] / 'apk-dependencies.txt').write_text(info)
    (c['lab'] / 'source-sha256.json').write_text(json.dumps({entry['source']: hashlib.sha256((ROOT / entry['source']).read_bytes()).hexdigest() for entry in entries}, indent=2) + '\n')


def scenarios(lab, c, state, start_exit, endpoint):
    results = {}
    def check(name, condition):
        assert condition, name
        results[name] = 'passed'
        print('PASS compatibility', c['profile'], name, flush=True)
    def read(path):
        return json.loads(lab.dex('cat', path).stdout)
    def normalized_uci(export):
        lines = []
        for line in export.splitlines():
            fields = shlex.split(line)
            if len(fields) == 3 and fields[:2] == ['list', 'selector_proxy_links']:
                uri = urllib.parse.urlsplit(fields[2])
                lines.append(('selector_link', uri.scheme, uri.netloc, uri.path,
                              sorted(urllib.parse.parse_qsl(uri.query, keep_blank_values=True)),
                              urllib.parse.unquote(uri.fragment)))
            else:
                lines.append(line)
        return lines
    def update(name, port):
        next(p for p in state['profiles'] if p['remarks'] == name)['outbounds'][0]['settings']['vnext'][0]['port'] = port
    try:
        status = lab.public()
        check('selector', status['count'] == 3 and len(read('/etc/sing-box/config.json')['outbounds']) >= 4)
        selected = status['selected_id']
        before, pid = lab.fingerprint(), lab.pid()
        lab.task('fetch')
        check('fetch', lab.public()['last_success'] > 0 and before == lab.fingerprint() and pid == lab.pid())
        lab.task('health')
        check('monitoring', lab.public().get('control', {}).get('ok') is True and before == lab.fingerprint() and pid == lab.pid())
        other = next(n['id'] for n in lab.public()['nodes'] if n['id'] != selected)
        lab.task('select', other)
        check('switch', lab.public()['selected_id'] == other and before == lab.fingerprint() and pid == lab.pid())
        selected = other
        saved_state = lab.dex('cat', '/etc/podkop-tools/state.json').stdout
        tampered = json.loads(saved_state)
        tampered['state_hash'] = '0' * 64
        lab.write('/etc/podkop-tools/state.json', json.dumps(tampered))
        stable, running = lab.fingerprint(), lab.pid()
        try:
            blocked = lab.task('select', selected, check=False)
            check('state_checksum_conflict_preserves_runtime', not blocked['ok'] and blocked['error'] == 'state_conflict' and stable == lab.fingerprint() and running == lab.pid())
        finally:
            lab.write('/etc/podkop-tools/state.json', saved_state)
        selected_name = next(n['name'] for n in lab.public()['nodes'] if n['id'] == selected)
        nonactive = next(n['name'] for n in lab.public()['nodes'] if n['id'] != selected)
        original_nodes = read('/etc/podkop-tools/state.json')['nodes']
        original_runtime = read('/etc/sing-box/config.json')
        original_export = lab.dex('uci', 'export', 'podkop').stdout
        update(nonactive, 14504)
        start_exit((14501, 14502, 14503, 14504, 14505))
        lab.task('fetch')
        lab.task('apply')
        check('apply', not lab.public()['pending'] and before != lab.fingerprint() and pid != lab.pid() and lab.public()['selected_id'] == selected)
        applied = lab.fingerprint()
        lab.task('rollback')
        restored_export = lab.dex('uci', 'export', 'podkop').stdout
        rollback_proof = {
            'nodes_restored': read('/etc/podkop-tools/state.json')['nodes'] == original_nodes,
            'runtime_restored': read('/etc/sing-box/config.json') == original_runtime,
            'uci_contract_restored': normalized_uci(restored_export) == normalized_uci(original_export),
            'selected_ID_restored': lab.public()['selected_id'] == selected,
            'applied_configuration_reverted': applied != lab.fingerprint(),
            'raw_bytes_identical': before == lab.fingerprint(),
        }
        print('ROLLBACK PROOF', json.dumps(rollback_proof), flush=True)
        check('rollback', all(rollback_proof[key] for key in rollback_proof if key != 'raw_bytes_identical'))
        # Downloads bootstrap from a running MAIN even before Toolkit has saved state.
        lab.dex('mv', '/etc/podkop-tools/state.json', '/etc/podkop-tools/state.json.saved')
        state['direct'] = False
        stable, running = lab.fingerprint(), lab.pid()
        try:
            fetched = lab.task('fetch', check=False)
            check('fetch_without_state_via_MAIN', fetched['ok'] and lab.public()['fetch_path'] == 'saved_server' and stable == lab.fingerprint() and running == lab.pid())
        finally:
            state['direct'] = True
            lab.dex('mv', '/etc/podkop-tools/state.json.saved', '/etc/podkop-tools/state.json')
        # A missing binary must not prevent curl from downloading via system routing.
        update(nonactive, 14505)
        lab.dex('mv', '/usr/bin/sing-box', '/usr/bin/sing-box.saved')
        stable, running = lab.fingerprint(), lab.pid()
        try:
            fetched = lab.task('fetch', check=False)
            check('fetch_without_sing_box_via_system', fetched['ok'] and lab.public()['fetch_path'] == 'system' and stable == lab.fingerprint() and running == lab.pid())
        finally:
            lab.dex('mv', '/usr/bin/sing-box.saved', '/usr/bin/sing-box')
            update(nonactive, 14504)
        # Change only the on-disk endpoint; the actual running API is untouched.
        native_runtime = lab.dex('cat', '/etc/sing-box/config.json').stdout
        unavailable = json.loads(native_runtime)
        unavailable['experimental']['clash_api']['external_controller'] = '127.0.0.1:1'
        lab.write('/etc/sing-box/config.json', json.dumps(unavailable))
        stable, running = lab.fingerprint(), lab.pid()
        try:
            fetched = lab.task('fetch', check=False)
            check('fetch_without_API', fetched['ok'] and lab.public()['fetch_stage_error'] == 'api_unavailable' and stable == lab.fingerprint() and running == lab.pid())
        finally:
            lab.write('/etc/sing-box/config.json', native_runtime)
        lab.write('/etc/podkop-tools/transaction.json', json.dumps({'schema_version': 2}))
        stable, running = lab.fingerprint(), lab.pid()
        try:
            fetched = lab.task('fetch', check=False)
            marker_kept = lab.dex('test', '-f', '/etc/podkop-tools/transaction.json', check=False).returncode == 0
            check('fetch_preserves_pending_transaction', fetched['ok'] and lab.public()['fetch_stage_error'] == 'recovery_required' and marker_kept and stable == lab.fingerprint() and running == lab.pid())
        finally:
            lab.dex('rm', '/etc/podkop-tools/transaction.json')
        # Change only non-executable metadata and comments: neither identifies an incompatibility.
        lab.dex('sh', '-c', 'printf "\\n# compatibility test: harmless source edit\\n" >> /usr/bin/podkop')
        constants = lab.dex('cat', '/usr/lib/podkop/constants.sh').stdout
        lab.write('/usr/lib/podkop/constants.sh', constants.replace('PODKOP_VERSION="' + c['podkop'] + '"', 'PODKOP_VERSION="99.0.0-test"'))
        lab.task('fetch')
        unknown = lab.public()['compatibility']
        check('unknown_version_warning', 'untested_versions' in unknown['warnings'])
        lab.task('apply')
        lab.task('health')
        check('changed_hash_and_unknown_version_do_not_gate', lab.public()['selected_id'] == selected and lab.public().get('control', {}).get('ok') is True)
        lab.write('/usr/lib/podkop/constants.sh', constants)
        # A generation failure blocks apply only; downloads and monitoring still work.
        update(nonactive, 14505)
        lab.task('fetch')
        version = lab.public()['pending_version']
        generator = lab.dex('cat', '/usr/libexec/podkop-tools/generate').stdout
        lab.dex('mv', '/usr/libexec/podkop-tools/generate', '/usr/libexec/podkop-tools/generate.saved')
        stable = lab.fingerprint()
        try:
            fetched = lab.task('fetch', check=False)
            check('fetch_without_generator', fetched['ok'] and lab.public()['fetch_stage_error'] == 'generator_unavailable' and stable == lab.fingerprint())
            blocked = lab.task('apply', version, check=False)
            check('apply_without_generator_blocked', not blocked['ok'] and blocked['error'] == 'generator_unavailable' and stable == lab.fingerprint())
            lab.task('health')
            check('monitoring_without_generator', lab.public().get('control', {}).get('ok') is True and stable == lab.fingerprint())
        finally:
            lab.dex('mv', '/usr/libexec/podkop-tools/generate.saved', '/usr/libexec/podkop-tools/generate')
        lab.task('fetch')
        # Deliberately invalid generated file must fail before writing native UCI.
        lab.write('/usr/libexec/podkop-tools/generate', '#!/bin/sh\n[ "${1:-}" = --check ] && exit 0\nprintf \'{"outbounds":[],"route":{"final":"missing"}}\\n\' > /tmp/podkop-tools/job/generated.json\n')
        lab.dex('chmod', '755', '/usr/libexec/podkop-tools/generate')
        stable = lab.fingerprint()
        try:
            blocked = lab.task('apply', check=False)
            check('invalid_staging_preserves_config', not blocked['ok'] and stable == lab.fingerprint())
            blocked = lab.task('rollback', check=False)
            check('invalid_rollback_staging_preserves_config', not blocked['ok'] and stable == lab.fingerprint())
        finally:
            lab.write('/usr/libexec/podkop-tools/generate', generator)
            lab.dex('chmod', '755', '/usr/libexec/podkop-tools/generate')
        # Confirmed failure recovers the same stable ID using its freshly downloaded address.
        accepted = read('/etc/podkop-tools/state.json')
        update(selected_name, 14504)
        print('RECOVERY FIXTURE IDENTITY', json.dumps({
            'accepted': [{'name': n['name'], 'id': n['id'], 'port': n['outbound']['server_port']} for n in accepted['nodes']],
            'incoming': [{'name': p['remarks'], 'port': p['outbounds'][0]['settings']['vnext'][0]['port']} for p in state['profiles']],
        }, ensure_ascii=False), flush=True)
        # A rotated node must not accidentally duplicate another accepted node's
        # connection: reconcile correctly gives an unchanged connection its ID.
        replacement_port = 14506
        assert replacement_port not in [n['outbound']['server_port'] for n in accepted['nodes']]
        update(selected_name, replacement_port)
        current_port = next(n['outbound']['server_port'] for n in accepted['nodes'] if n['id'] == selected)
        start_exit(tuple(p for p in (14501, 14502, 14503, 14504, 14505, replacement_port) if p != current_port))
        import v020
        v020.l = lab
        v020.prime(selected)
        lab.task('health')
        recovered = read('/etc/podkop-tools/state.json')
        check('recovery', lab.public()['selected_id'] == selected and next(n['outbound']['server_port'] for n in recovered['nodes'] if n['id'] == selected) == replacement_port)
        check('apk_dependencies_keep_installed_versions', True)  # asserted by no-network installation in install()
    finally:
        (c['lab'] / 'results.json').write_text(json.dumps({'profile': {k: c[k] for k in ('podkop', 'sing_box')}, 'environment': 'OpenWrt 25.12.5 x86_64 userspace; host kernel; synthetic package metadata; not device certification', 'operations': results}, ensure_ascii=False, indent=2) + '\n')


def driver(c):
    lab = load_lab(c)
    lab.setup_packages = lambda: None
    if c['suite']=='integration':
        import sections_integration
        run_scenarios=sections_integration.scenarios
    else:run_scenarios=scenarios
    sys.modules['ownership'] = types.SimpleNamespace(custom=lambda state, start_exit, endpoint: run_scenarios(lab, c, state, start_exit, endpoint))
    sys.argv = [__file__, '--ownership']
    os.environ['TOOLKIT_SHARED_NAMESPACE'] = '1'
    lab.main()


def outer(c, preflight):
    c['lab'].mkdir(parents=True, exist_ok=True)
    owned = []
    for kind, name in [('container', c['main']), ('container', c['exit']), ('container', c['driver']), ('network', c['network'])]:
        assert command('docker', kind, 'inspect', name, check=False).returncode != 0, 'resource already exists: ' + name
    try:
        command('docker', 'network', 'create', '--internal', c['network'])
        owned.append(('network', c['network']))
        command('docker', 'run', '--name', c['main'], '-d', '--network', c['network'], '--cap-add=NET_ADMIN', '--cap-add=NET_RAW', '--tmpfs', '/tmp', '--tmpfs', '/run', IMAGE, '/sbin/init')
        owned.append(('container', c['main']))
        for _ in range(30):
            ready = command('docker', 'exec', c['main'], 'sh', '-c', 'test -S /var/run/ubus/ubus.sock && test -f /tmp/toolkit-boot-ready', check=False)
            if not ready.returncode:
                break
            time.sleep(1)
        else:
            raise RuntimeError('isolated OpenWrt boot failed')
        lab = load_lab(c)
        lab.cp(c['binary'], '/usr/bin/compat-test-sing-box')
        version = lab.dex('/usr/bin/compat-test-sing-box', 'version').stdout
        assert version.startswith('sing-box version ' + c['sing_box'] + '\n'), version
        assert 'with_clash_api' in version and 'with_utls' in version, version
        python_image = json.loads((ROOT / 'tools/sources.lock.json').read_text())['python_fixture']['image']
        shared_args = ['docker', 'run', '--rm', '--name', c['driver'], '--network', 'container:' + c['main'],
                       '--user', str(os.getuid()) + ':' + str(os.getgid()), '--group-add', str(os.stat('/var/run/docker.sock').st_gid),
                       '-e', 'PYTHONDONTWRITEBYTECODE=1', '-e', 'PYTHONUNBUFFERED=1', '-v', str(ROOT) + ':/work:ro',
                       '-v', str(c['lab']) + ':/work/' + c['lab'].relative_to(ROOT).as_posix(), '-v', '/usr/bin/docker:/usr/bin/docker:ro',
                       '-v', '/var/run/docker.sock:/var/run/docker.sock', python_image, 'python3', '-B']
        if preflight:
            # Validate the exact image, namespace, Docker access, CA path and curl command used by the real fixture.
            script = """import http.server,pathlib,socket,ssl,subprocess,threading
base=pathlib.Path('/work/LABREL')
cert,key=base/'fixture.crt',base/'fixture.key'
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=compat-preflight','-addext','subjectAltName=IP:127.0.0.1'],check=True,capture_output=True)
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self): self.send_response(204);self.end_headers()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key);server.socket=context.wrap_socket(server.socket,server_side=True)
threading.Thread(target=server.serve_forever,daemon=True).start()
subprocess.run(['docker','exec','-i','MAIN','sh','-c','cat > /tmp/fixture.crt'],input=cert.read_bytes(),check=True)
subprocess.run(['docker','exec','MAIN','/usr/bin/curl','--disable','--proto','=https','--noproxy','*','--cacert','/tmp/fixture.crt','--silent','--show-error','--fail','--max-time','3','https://127.0.0.1:'+str(server.server_address[1])],check=True)
server.shutdown();print('PASS exact namespace HTTPS preflight')
""".replace('LABREL', c['lab'].relative_to(ROOT).as_posix()).replace('MAIN', c['main'])
            result = command(*shared_args, '-c', script)
            print(version, end='')
            print(result.stdout, end='')
            return
        install(c, lab)
        # Existing integration fixture expects this CA before shared-namespace entry.
        command('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(c['lab'] / 'fixture.key'), '-out', str(c['lab'] / 'fixture.crt'), '-days', '1', '-subj', '/CN=compat-fixture', '-addext', 'subjectAltName=IP:127.0.0.1')
        subprocess.run([*shared_args, '/work/tests/podkop-tools/compat-integration.py', '--driver', '--profile', c['profile'], '--suite', c['suite']], check=True)
    except subprocess.CalledProcessError:
        # Synthetic fixture only: reveal the exact backend exception before the
        # normal cleanup removes its namespace. Never enable raw errors in RPC.
        lab = load_lab(c)
        lab.dex('mkdir', '-p', '/tmp/podkop-tools/job/uci', '/tmp/podkop-tools/job/delta', '/tmp/podkop-tools/job/read-delta')
        prefix = (ROOT / 'root/usr/libexec/podkop-tools/backend.uc').read_text().split('let command = ARGV')[0]
        lab.write('/tmp/compat-diagnostic.uc', prefix + "\ntry { require_operation('seed'); state_seed(); print('seed diagnostic succeeded\\n'); } catch(e) { print(sprintf('%J\\n',{message:e.message,stack:e.stacktrace})); }\n")
        print('SYNTHETIC SEED DIAGNOSTIC', lab.dex('ucode', '/tmp/compat-diagnostic.uc', 'seed', check=False).stdout, flush=True)
        print('SYNTHETIC SELECTOR SHAPE', lab.dex('jq', '{selector:[.outbounds[]|select(.tag=="main-out")|{type,tag,outbounds}],route_final:.route.final}', '/etc/sing-box/config.json', check=False).stdout, flush=True)
        print('SYNTHETIC GROUP SHAPE', lab.dex('curl', '-fsS', '--max-time', '2', 'http://127.0.0.1:9090/proxies/main-out', check=False).stdout, flush=True)
        raise
    finally:
        # Only resources created by this invocation are eligible for removal.
        if ('container', c['main']) in owned:
            if command('docker', 'container', 'inspect', c['exit'], check=False).returncode == 0:
                command('docker', 'rm', '-f', c['exit'])
        for kind, name in reversed(owned):
            command('docker', 'rm', '-f', name) if kind == 'container' else command('docker', 'network', 'rm', name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--suite', choices=['compat','integration'], default='compat')
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--driver', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    c = context(args.profile,args.suite)
    driver(c) if args.driver else outer(c, args.preflight)


if __name__ == '__main__':
    main()
