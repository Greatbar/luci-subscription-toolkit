#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
"""Run tests in an exclusively owned, disposable OpenWrt namespace."""
import argparse, importlib.util, json, os, pathlib, shutil, subprocess, sys, time
sys.dont_write_bytecode=True
os.environ['PYTHONDONTWRITEBYTECODE']='1'
ROOT=pathlib.Path(__file__).resolve().parents[1]
MAIN='subscription-toolkit-test-main';EXIT='subscription-toolkit-test-exit';NETWORK='subscription-toolkit-test'
def run(*args,**kw): return subprocess.run(args,check=True,**kw)
def docker(*args,**kw):return run('docker',*args,**kw)
def exec_(*args):return docker('exec',MAIN,*args)
def main():
    p=argparse.ArgumentParser();p.add_argument('suite',choices=['unit','antigravity','integration','recovery','rotation','ownership','readiness','browser','all']);a=p.parse_args()
    run('node',str(ROOT/'tests/podkop-tools/luci.cjs'))
    run('node',str(ROOT/'tests/podkop-tools/policy-ui.cjs'))
    run('python3','-B',str(ROOT/'tests/podkop-tools/generator.py'))
    run('python3',str(ROOT/'tests/test_audit.py'))
    run('python3','-B',str(ROOT/'tests/test_security.py'))
    run('python3','-B',str(ROOT/'tests/podkop-tools/scheduler.py'))
    run('python3','-B',str(ROOT/'tools/generate-fixtures.py'),'--check')
    # Never adopt or remove an existing container or network.
    for kind,name in [('container',MAIN),('container',EXIT),('container','subscription-toolkit-test-driver'),('network',NETWORK)]:
        result=subprocess.run(['docker',kind,'inspect',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if result.returncode==0:raise RuntimeError('test resource already exists: '+name)
    network=False;container=False
    try:
        docker('network','create','--internal',NETWORK,stdout=subprocess.DEVNULL);network=True
        docker('run','--name',MAIN,'-d','--network',NETWORK,'--cap-add=NET_ADMIN','--cap-add=NET_RAW','--tmpfs','/tmp','--tmpfs','/run','subscription-toolkit-openwrt:25.12.5','/sbin/init',stdout=subprocess.DEVNULL);container=True
        for _ in range(30):
            if subprocess.run(['docker','exec',MAIN,'sh','-c','test -S /var/run/ubus/ubus.sock && test -f /tmp/toolkit-boot-ready'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
            time.sleep(1)
        else:raise RuntimeError('OpenWrt procd/ubus did not start')
        spec=importlib.util.spec_from_file_location('integration',ROOT/'tests/podkop-tools/integration.py');lab=importlib.util.module_from_spec(spec);sys.modules['integration']=lab;spec.loader.exec_module(lab)
        lab.LAB.mkdir(parents=True,exist_ok=True);lab.setup_packages()
        for name in ('model','service','policy','statistics','compatibility','sections'):
            lab.cp(ROOT/f'tests/podkop-tools/{name}.uc','/tmp/'+name+'.uc');exec_('ucode','/tmp/'+name+'.uc')
        prefix=(ROOT/'root/usr/libexec/podkop-tools/backend.uc').read_text().split('let command = ARGV')[0]
        lab.write('/tmp/ag-contract.uc',prefix+(ROOT/'tests/podkop-tools/ag_contract.uc').read_text())
        exec_('ucode','/tmp/ag-contract.uc')
        for name in ('provider.json','outbounds.json'):
            lab.cp(ROOT/'tests/fixtures'/name,'/tmp/'+name)
        lab.cp(ROOT/'tests/podkop-tools/provider.uc','/tmp/provider.uc')
        exec_('ucode','/tmp/provider.uc','/tmp/provider.json','/tmp/outbounds.json','/tmp/provider-check.json')
        exec_('sing-box','check','-c','/tmp/provider-check.json')
        suites=['integration','recovery','rotation','ownership','antigravity','readiness','baseline','browser'] if a.suite=='all' else ([] if a.suite=='unit' else ['baseline',a.suite] if a.suite in ('browser','readiness') else [a.suite])
        for suite in suites:
            if suite == 'antigravity':
                # Host orchestration: the optional-route fixture never needs a
                # Docker socket or Docker CLI mounted into a test container.
                sys.path.insert(0,str(ROOT/'tests/podkop-tools'))
                original_args,original_setup=sys.argv,lab.setup_packages
                try:
                    sys.argv=['integration.py','--antigravity']
                    lab.setup_packages=lambda:None
                    lab.main()
                finally:
                    sys.argv=original_args;lab.setup_packages=original_setup
            elif suite in ('integration','recovery','rotation','ownership','baseline'):
                cert=lab.LAB/'fixture.crt';key=lab.LAB/'fixture.key'
                run('openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=subscription-toolkit-fixture','-addext','subjectAltName=IP:127.0.0.1',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);key.chmod(0o600)
                image=json.loads((ROOT/'tools/sources.lock.json').read_text())['python_fixture']['image']
                args=['docker','run','--rm','--name','subscription-toolkit-test-driver','--user',str(os.getuid())+':'+str(os.getgid()),'--group-add',str(os.stat('/var/run/docker.sock').st_gid),'--network','container:'+MAIN,'-e','TOOLKIT_SHARED_NAMESPACE=1','-e','PYTHONUNBUFFERED=1','-e','PYTHONDONTWRITEBYTECODE=1','-v',str(ROOT)+':/work','-v','/usr/bin/docker:/usr/bin/docker:ro','-v','/var/run/docker.sock:/var/run/docker.sock',image,'python3','-B','/work/tests/podkop-tools/integration.py']
                if suite!='integration':args+=['--'+suite]
                run(*args)
            elif suite=='readiness':run('python3',str(ROOT/'tests/podkop-tools/readiness.py'))
            else:
                # Resume-search regression uses real backend I/O and deterministic probe time.
                spec=importlib.util.spec_from_file_location('v020',ROOT/'tests/podkop-tools/v020.py')
                policy_test=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy_test)
                policy_test.l=lab;policy_test.continuing_scan()
                # The fixture password has no access outside this disposable namespace.
                exec_('sh','-c',"printf 'PodkopLabOnly123\\nPodkopLabOnly123\\n' | passwd root")
                exec_('/etc/init.d/uhttpd','restart')
                image=json.loads((ROOT/'tools/sources.lock.json').read_text())['browser_fixture']['image']
                before=lab.fingerprint();old_pid=lab.pid();selection=lab.public()['selected_id']
                docker('run','--rm','--network','container:'+MAIN,'-e','TOOLKIT_LAB_URL=http://127.0.0.1:80','-v',str(ROOT)+':/work','-w','/work',image,'node','tests/podkop-tools/browser.cjs')
                assert lab.fingerprint()==before and lab.pid()==old_pid and lab.public()['selected_id']==selection, 'browser tests changed MAIN/PID/Selector'
                assert not lab.public()['busy'], 'unfinished browser diagnostic job'
                exec_('sh','-c',"test ! -e /tmp/podkop-tools/job/probe.pid && ! pgrep -f '^/usr/bin/sing-box run -c /tmp/podkop-tools/job/probe.json'")
                print('PASS browser preserves MAIN/configuration/PID/Selector; no temporary probes',flush=True)
    finally:
        if container:
            subprocess.run(['docker','rm','-f',MAIN],check=True,stdout=subprocess.DEVNULL)
            # EXIT can only have been created by the lab after the initial absence check.
            result=subprocess.run(['docker','container','inspect',EXIT],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if result.returncode==0:docker('rm','-f',EXIT,stdout=subprocess.DEVNULL)
        if network:docker('network','rm',NETWORK,stdout=subprocess.DEVNULL)
if __name__=='__main__':main()
