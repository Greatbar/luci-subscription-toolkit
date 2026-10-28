#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
"""Real OpenWrt userspace/APK/procd + stock sing-box, isolated Docker bridge.

No router access. Fixtures use generated credentials, an ephemeral CA and a
controlled HTTPS endpoint. No production subscription is contacted.
"""
import argparse, concurrent.futures, copy, hashlib, http.server, json, os, pathlib, socket, ssl
import struct, subprocess, sys, tarfile, threading, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAB = ROOT / '.build/lab'
SOURCES = ROOT / '.build'
NETWORK = 'subscription-toolkit-test'
IMAGE = 'subscription-toolkit-openwrt:25.12.5'
NATIVE = SOURCES / 'podkop-0.7.22/podkop/files'
APK = SOURCES / 'openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64/staging_dir/host/bin/.apk.bin'
MAIN, EXIT = 'subscription-toolkit-test-main', 'subscription-toolkit-test-exit'
UUID = '00000000-0000-4000-8000-000000000001'
TOKEN = 'PRIVATE_LAB_SUBSCRIPTION_TOKEN'
results = []

def command(args, check=True, text=True):
    r = subprocess.run(args, capture_output=True, text=text)
    if check and r.returncode:
        raise RuntimeError('command failed: ' + ' '.join(map(str,args[:4])) + '\n' + (r.stdout+r.stderr if text else ''))
    return r
def dex(*args, check=True): return command(['docker','exec',MAIN,*args],check=check)
def cp(source,target,container=MAIN):
    source=pathlib.Path(source)
    subprocess.run(['docker','exec','-i',container,'sh','-c','cat > "$1" && chmod "$2" "$1"','fixture-copy',target,oct(source.stat().st_mode & 0o777)[2:]],input=source.read_bytes(),check=True)
def write(target,data,container=MAIN):
    path=LAB/'write.tmp';path.write_text(data);path.chmod(0o600);cp(path,target,container);path.unlink()
def write_signed_state(state):
    """Test-only clock adjustment: retain r6 checksum validation in all real jobs."""
    dex('mkdir','-p','/tmp/podkop-tools/job','/tmp/podkop-tools/job/read-delta')
    prefix=(ROOT/'root/usr/libexec/podkop-tools/backend.uc').read_text().split('let command = ARGV')[0]
    write('/tmp/fixture-state.json',json.dumps(state))
    write('/tmp/fixture-state.uc',prefix+"\nsave_state(BASE+'/state.json',json(fs.readfile('/tmp/fixture-state.json')));\n")
    dex('ucode','/tmp/fixture-state.uc')
    dex('rm','-rf','/tmp/podkop-tools/job','/tmp/fixture-state.json','/tmp/fixture-state.uc')
def uci(key,value): dex('uci','set',key+'='+str(value));dex('uci','commit')
def task(name,*args,check=True):
    if name=='apply' and not args:args=(public()['pending_version'],)
    r=dex('/usr/libexec/podkop-tools/task',name,*args,check=check)
    assert TOKEN not in r.stdout+r.stderr, 'secret in task output'
    try:return json.loads(r.stdout)
    except ValueError:raise RuntimeError('non-JSON task result: '+r.stdout+r.stderr)
def record(name,condition):
    assert condition,name
    results.append(name);print('PASS',name,flush=True)
def public():return task('status')
def pid():return dex('pgrep','-f',r'^/usr/bin/sing-box run -c /etc/sing-box/config.json').stdout.strip()
def fingerprint():return dex('sha256sum','/etc/config/podkop','/etc/sing-box/config.json').stdout

def recovery_scenarios(state,start_exit,endpoint):
    """Real VLESS port failures; only observation timestamps are advanced in tmpfs.

    Each assertion names a wrong production decision, rather than mocking recovery.
    """
    baseline=dex('cat','/etc/config/podkop').stdout
    provider=copy.deepcopy(state['profiles'])
    def read(path):return json.loads(dex('cat',path).stdout)
    def reset(ports=(14501,14502,14503)):
        state.update(profiles=copy.deepcopy(provider),mode='valid',direct=True,service_mode='ok')
        start_exit(ports)
        write('/etc/config/podkop',baseline)
        dex('rm','-rf','/etc/podkop-tools','/tmp/podkop-tools')
        dex('/etc/init.d/podkop','reload');task('seed')
        selected=next(n['id'] for n in public()['nodes'] if n['name']=='Латвия')
        task('select',selected)
        uci('podkop_tools.main.apply_policy','manual')
        return selected
    def change(name,port):
        next(p for p in state['profiles'] if p['remarks']==name)['outbounds'][0]['settings']['vnext'][0]['port']=port
    def age_observation(seconds=901):
        h=read('/tmp/podkop-tools/health.json')
        h['checked_at']=int(time.time())-seconds;h['first_failed_at']=int(time.time())-seconds
        write('/tmp/podkop-tools/health.json',json.dumps(h))
    def fail_once(selected,spacing=901):
        before=fingerprint();old_pid=pid();task('health')
        record('one_failed_control_probe_never_switches',public()['selected_id']==selected and fingerprint()==before and pid()==old_pid)
        task('health')
        record('rapid_retry_cannot_confirm_failure',read('/tmp/podkop-tools/health.json')['failures']==1 and public()['selected_id']==selected and fingerprint()==before)
        age_observation(spacing)
    def window():
        uci('podkop_tools.main.apply_policy','window');uci('podkop_tools.main.apply_hour',int(dex('date','+%H').stdout));uci('podkop_tools.main.defer_hours',1)
    def age_pending(hours=2,verified_age=0):
        p=read('/etc/podkop-tools/pending.json');p['first_seen']=int(time.time())-hours*3600
        p['version_at']=p['first_seen'];p['verified_at']=int(time.time())-verified_age*3600
        write('/etc/podkop-tools/pending.json',json.dumps(p));return p

    if '--rotation' in sys.argv:
        # Keep series age independent from every newly downloaded revision.
        selected=reset((14501,14502,14503,14504,14505));change('Латвия',14504);task('fetch')
        series_start=int(time.time())-12*3600
        write('/etc/podkop-tools/change-series.json',json.dumps({'started_at':series_start}))
        change('Латвия',14505);task('fetch')
        p=read('/etc/podkop-tools/pending.json')
        record('rotating_candidate_preserves_series_age_not_version_age',p.get('series_started_at')==series_start and p['first_seen']>=int(time.time())-10)
        window();uci('podkop_tools.main.defer_hours',6);uci('podkop_tools.main.max_defer_hours',24)
        old_pid=pid();before=fingerprint();task('due')
        record('rotation_under_deadline_does_not_apply_young_version',pid()==old_pid and fingerprint()==before and public()['pending'])
        for age in [25,49]:
            write('/etc/podkop-tools/change-series.json',json.dumps({'started_at':int(time.time())-age*3600}))
            saved=read('/etc/podkop-tools/state.json');saved['last_apply']=int(time.time())-90000;write_signed_state(saved)
            # Provider rotates again in the mandatory pre-apply fetch.
            change('Латвия',14504 if age==25 else 14505)
            old_pid=pid();task('due')
            record('daily_or_frequent_rotation_applies_fresh_revision_at_deadline_'+str(age),not public()['pending'] and public()['selected_id']==selected and pid()!=old_pid)
            change('Латвия',14505 if age==25 else 14504);task('fetch')
        write('/etc/podkop-tools/change-series.json',json.dumps({'started_at':int(time.time())-49*3600}))
        saved=read('/etc/podkop-tools/state.json');saved['last_apply']=int(time.time())-90000;write_signed_state(saved)
        state['mode']='unavailable';before=fingerprint();old_pid=pid();task('due',check=False)
        record('deadline_never_applies_without_fresh_subscription',fingerprint()==before and pid()==old_pid and public()['apply_blocked_reason']=='subscription_unavailable_or_invalid')
        state['mode']='valid';start_exit((14501,14503));task('due',check=False)
        record('deadline_never_activates_unreachable_selected_endpoint',fingerprint()==before and pid()==old_pid and public()['apply_blocked_reason']=='selected_endpoint_unreachable')
        start_exit((14501,14502,14503,14504,14505));task('due')
        record('blocked_deadline_retries_fresh_and_recovers_apply',not public()['pending'] and public()['selected_id']==selected)
        # TTL expiration retains only the series clock, never the old endpoint data.
        change('Латвия',14505);task('fetch');age_pending(30,30)
        write('/etc/podkop-tools/change-series.json',json.dumps({'started_at':int(time.time())-30*3600}))
        saved=read('/etc/podkop-tools/state.json');saved['last_apply']=int(time.time())-90000;write_signed_state(saved)
        change('Латвия',14502);task('due')
        record('stale_pending_is_refetched_at_preserved_deadline',not public()['pending'] and next(n['outbound']['server_port'] for n in read('/etc/podkop-tools/state.json')['nodes'] if n['id']==selected)==14502)
        # A legacy r3 pending has no verification; preserve history, demand fresh data.
        change('Латвия',14504);task('fetch');p=age_pending(30,0);p.pop('verified_at',None);p.pop('series_started_at',None);p.pop('version_at',None)
        write('/etc/podkop-tools/pending.json',json.dumps(p));dex('rm','-f','/etc/podkop-tools/change-series.json')
        state['mode']='unavailable';before=fingerprint();task('fetch',check=False)
        record('legacy_pending_migrates_series_without_unverified_activation',not public()['pending'] and read('/etc/podkop-tools/change-series.json')['started_at']==p['first_seen'] and fingerprint()==before)
        state['mode']='valid'
        if '--rotation' in sys.argv:
            (LAB/'rotation-results.json').write_text(json.dumps({'passed':results},indent=2)+'\n')
            return

    selected=reset();change('Швеция',14504);task('fetch');age_pending()
    change('Швеция',14505);before=fingerprint();task('fetch')
    p=read('/etc/podkop-tools/pending.json')
    record('changed_subscription_resets_candidate_version_age',p['first_seen']>=int(time.time())-10 and fingerprint()==before)

    selected=reset((14502,));state['direct']=False;before=fingerprint();old_pid=pid();task('check')
    record('periodic_fetch_last_path_uses_working_active_without_MAIN_switch',public()['fetch_path']=='saved_server' and public()['selected_id']==selected and fingerprint()==before and pid()==old_pid)

    selected=reset((14501,14503,14504));change('Латвия',14504);change('Швеция',14505);old_pid=pid();fail_once(selected,885);task('health')
    accepted=read('/etc/podkop-tools/state.json')
    record('blocked_old_Latvia_recovers_new_address_same_ID_first',public()['selected_id']==selected and next(n['outbound']['server_port'] for n in accepted['nodes'] if n['id']==selected)==14504 and pid()!=old_pid)
    record('recovery_changes_only_verified_active_profile_keeps_other_updates_pending',public()['pending'] and next(n['outbound']['server_port'] for n in accepted['nodes'] if n['name']=='Швеция')==14501)
    after=fingerprint();after_pid=pid();task('health')
    record('recovery_no_repeat_reload_or_switch',fingerprint()==after and pid()==after_pid and public()['selected_id']==selected)

    selected=reset((14501,14503));change('Латвия',14504);old_pid=pid();before=fingerprint();fail_once(selected);task('health')
    record('blocked_new_address_uses_verified_saved_other_without_reload',public()['selected_id']!=selected and pid()==old_pid and fingerprint()==before)
    recovered=public()['selected_id'];start_exit((14503,));fail_once(recovered);task('health')
    record('confirmed_second_outage_waits_recovery_cooldown',public()['state']=='recovery_cooldown' and public()['selected_id']==recovered and pid()==old_pid and fingerprint()==before)

    selected=reset((14501,14503));change('Латвия',14504)
    write('/tmp/podkop-tools/recovery.json',json.dumps({'selected_id':selected,'cursor':1,'last_attempt':0}))
    fail_once(selected);task('health')
    record('budget_limited_scan_resumes_later_saved_candidate',next(n['name'] for n in public()['nodes'] if n['selected'])=='Германия')
    task('select',selected)
    saved=read('/etc/podkop-tools/state.json');saved['last_recovery']=int(time.time())-1801;write_signed_state(saved)
    progress=read('/tmp/podkop-tools/recovery.json');progress['last_attempt']=int(time.time())-1801;write('/tmp/podkop-tools/recovery.json',json.dumps(progress))
    fail_once(selected);task('health')
    record('subsequent_recovery_scan_advances_instead_of_repeating_same_reserve',next(n['name'] for n in public()['nodes'] if n['selected'])=='Швеция')

    selected=reset((14506,));change('Латвия',14504)
    for i in range(5):
        extra=copy.deepcopy(provider[0]);extra['remarks']='Резерв '+str(i+1)
        extra['outbounds'][0]['settings']['vnext'][0]['port']=14506 if i==4 else 14510+i
        state['profiles'].append(extra)
    fail_once(selected);task('health')
    record('recovery_checks_working_candidate_beyond_first_four',next(n['name'] for n in public()['nodes'] if n['selected'])=='Резерв 5')

    selected=reset(());change('Латвия',14504);before=fingerprint();old_pid=pid();fail_once(selected);task('health',check=False)
    record('all_servers_down_preserves_MAIN_no_DIRECT_fallback',fingerprint()==before and pid()==old_pid and public()['selected_id']==selected)

    selected=reset((14501,14503));state['mode']='unavailable';before=fingerprint();old_pid=pid();fail_once(selected);task('health')
    record('fetch_unavailable_recovers_verified_applied_snapshot',public()['selected_id']!=selected and fingerprint()==before and pid()==old_pid)

    selected=reset((14501,14503,14504));change('Латвия',14504);task('fetch');state['mode']='unavailable'
    old_pid=pid();fail_once(selected);task('health')
    record('fetch_unavailable_recent_pending_same_ID_is_reprobed',public()['selected_id']==selected and next(n['outbound']['server_port'] for n in read('/etc/podkop-tools/state.json')['nodes'] if n['id']==selected)==14504 and pid()!=old_pid)

    selected=reset((14501,14503,14504));change('Латвия',14504);task('fetch');age_pending(20,20);state['mode']='unavailable'
    old_pid=pid();before=fingerprint();fail_once(selected);task('health')
    record('expired_pending_not_used_for_recovery',not public()['pending'] and public()['selected_id']!=selected and fingerprint()==before and pid()==old_pid)

    selected=reset((14501,));fail_once(selected)
    other=next(n['id'] for n in public()['nodes'] if n['name']=='Германия');task('select',other)
    before=fingerprint();old_pid=pid();task('health')
    record('manual_selection_resets_failure_confirmation',public()['selected_id']==other and fingerprint()==before and pid()==old_pid)

    selected=reset((14501,14503,14504));change('Латвия',14504);fail_once(selected)
    prefix=(ROOT/'root/usr/libexec/podkop-tools/backend.uc').read_text().split('let command = ARGV')[0]
    write('/tmp/manual-choice.uc',prefix+"\napi('/proxies/main-out','PUT',{name:'main-3-out'});\n")
    state['on_sub']=lambda:dex('ucode','/tmp/manual-choice.uc','status')
    before=fingerprint();old_pid=pid();out=task('health',check=False)
    other=next(n['id'] for n in public()['nodes'] if n['name']=='Германия')
    record('manual_change_during_recovery_fetch_cancels_switch',not out['ok'] and out['error']=='selection_changed' and public()['selected_id']==other and fingerprint()==before and pid()==old_pid)

    selected=reset();uci('podkop_tools.main.service_url',endpoint+'/service');state['service_mode']='forbidden'
    task('service',selected);before=fingerprint();old_pid=pid();task('health')
    tests=next(n['test'] for n in public()['nodes'] if n['id']==selected)
    record('application_error_separate_from_control_health_no_switch',not tests['service']['ok'] and public()['selected_id']==selected and fingerprint()==before and pid()==old_pid)

    selected=reset();change('Швеция',14504);task('fetch');age_pending();window()
    change('Швеция',14505);before=fingerprint();old_pid=pid();task('due')
    record('ordinary_apply_refetch_new_version_defers_again',public()['pending'] and read('/etc/podkop-tools/pending.json')['first_seen']>=int(time.time())-10 and fingerprint()==before and pid()==old_pid)

    p=age_pending();state['mode']='unavailable';before=fingerprint();task('due',check=False)
    record('ordinary_apply_requires_successful_fresh_fetch',fingerprint()==before and pid()==old_pid and public()['pending'])
    age_pending(20,20);task('due',check=False)
    record('stale_pending_expired_without_MAIN_apply',not public()['pending'] and fingerprint()==before and pid()==old_pid)

    selected=reset();change('Швеция',14504);task('fetch');version=public()['pending_version'];change('Швеция',14505)
    before=fingerprint();old_pid=pid();out=task('apply',version,check=False)
    record('manual_confirmation_bound_to_exact_candidate_version',not out['ok'] and out['error']=='pending_changed' and fingerprint()==before and pid()==old_pid)

    selected=reset((14501,14502,14503,14504));change('Латвия',14504);task('fetch');age_pending();window();old_pid=pid();task('due')
    record('fresh_unchanged_version_applies_verified_Latvia_once',not public()['pending'] and public()['selected_id']==selected and pid()!=old_pid)
    old_pid=pid();before=fingerprint();task('check');task('due')
    record('unchanged_fetch_no_reload_after_recovery_changes',not public()['pending'] and fingerprint()==before and pid()==old_pid)
    (LAB/'recovery-results.json').write_text(json.dumps({'passed':results,'environment':'isolated OpenWrt userspace, real VLESS endpoints and sing-box 1.14.2; no router changes'},ensure_ascii=False,indent=2)+'\n')

def setup_packages():
    payload=LAB/'stock-payload'
    import shutil
    if payload.exists(): shutil.rmtree(payload)
    payload.mkdir()
    for relative in ['usr/bin/podkop','usr/lib/podkop']:
        source=NATIVE/('usr/lib' if relative=='usr/lib/podkop' else relative);dest=payload/relative;dest.parent.mkdir(parents=True,exist_ok=True)
        import shutil
        if source.is_dir():shutil.copytree(source,dest,dirs_exist_ok=True)
        else:shutil.copy2(source,dest);dest.chmod(0o755)
    for relative, source in [('etc/init.d/podkop', NATIVE/'etc/init.d/podkop')]:
        path=payload/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(source.read_bytes());path.chmod(0o755)
    constants=payload/'usr/lib/podkop/constants.sh'
    constants.write_text(constants.read_text().replace('__COMPILED_VERSION_VARIABLE__','0.7.22'))
    package=LAB/'stock-podkop-0.7.22.apk'
    command(['fakeroot','sh','-c','set -e; chown -R 0:0 "$1"; shift; exec "$@"','fixture-build',str(payload),str(APK),'mkpkg','--info','name:podkop','--info','version:0.7.22-r1','--info','arch:noarch','--files',str(payload),'--output',str(package)])
    cp(package,'/tmp/podkop.apk');dex('apk','add','--allow-untrusted','--no-network','--force-reinstall','/tmp/podkop.apk')
    # Existing official binary payload, local package metadata for dependency solving.
    sb=LAB/'sb-payload'
    if sb.exists(): shutil.rmtree(sb)
    (sb/'usr/bin').mkdir(parents=True,exist_ok=True)
    (sb/'etc/init.d').mkdir(parents=True)
    shutil.copy2(SOURCES/'sing-box.init',sb/'etc/init.d/sing-box');(sb/'etc/init.d/sing-box').chmod(0o755)
    import shutil
    shutil.copy2(SOURCES/'sing-box-1.14.2-linux-amd64-musl/sing-box',sb/'usr/bin/sing-box')
    package=LAB/'stock-sing-box-1.14.2.apk'
    command(['fakeroot','sh','-c','set -e; chown -R 0:0 "$1"; shift; exec "$@"','fixture-build',str(sb),str(APK),'mkpkg','--info','name:sing-box','--info','version:1.14.2-r1','--info','arch:x86_64','--files',str(sb),'--output',str(package)])
    cp(package,'/tmp/sing-box.apk');dex('apk','add','--allow-untrusted','--no-network','--force-reinstall','/tmp/sing-box.apk')
    command(['python3',str(ROOT/'tools/build-podkop-tools.py'),'--apk',str(APK),'--output',str(LAB/'dist')])
    package=max((LAB/'dist').glob('luci-app-subscription-toolkit-*.apk'),key=lambda p:p.stat().st_mtime);cp(package,'/tmp/tools.apk')
    dex('apk','add','--allow-untrusted','--no-network','--force-reinstall','/tmp/tools.apk')

def main():
    LAB.mkdir(parents=True,exist_ok=True)
    shared=os.environ.get('TOOLKIT_SHARED_NAMESPACE')=='1'
    gateway='127.0.0.1' if shared else command(['docker','network','inspect',NETWORK,'--format','{{(index .IPAM.Config 0).Gateway}}']).stdout.strip()
    client_ip='127.0.0.1' if shared else command(['docker','inspect',MAIN,'--format','{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}']).stdout.strip()
    command(['docker','run','--name',EXIT,'-d','--network',('container:'+MAIN if shared else NETWORK),IMAGE,'sleep','86400'])
    exit_ip='127.0.0.1' if shared else command(['docker','inspect',EXIT,'--format','{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}']).stdout.strip()
    binary=SOURCES/'sing-box-1.14.2-linux-amd64-musl/sing-box'
    cp(binary,'/usr/bin/sing-box',EXIT)
    def start_exit(ports):
        command(['docker','exec',EXIT,'killall','sing-box'],check=False)
        config={'log':{'disabled':True},'inbounds':[{'type':'vless','tag':'vless-'+str(p),'listen':'0.0.0.0','listen_port':p,'users':[{'uuid':UUID}]} for p in ports],
                'outbounds':[{'type':'direct','tag':'direct',**({'inet4_bind_address':'127.0.0.2'} if shared else {})}], 'route':{'final':'direct'}}
        write('/tmp/exit.json',json.dumps(config),EXIT)
        command(['docker','exec',EXIT,'/usr/bin/sing-box','check','-c','/tmp/exit.json'])
        command(['docker','exec','-d',EXIT,'/usr/bin/sing-box','run','-c','/tmp/exit.json']);time.sleep(.3)
    start_exit([14501,14502,14503])
    def profiles():
        return [{'remarks':name,'outbounds':[{'tag':'proxy','protocol':'vless','settings':{'vnext':[{'address':exit_ip,'port':port,'users':[{'id':UUID}]}]},'streamSettings':{'network':'tcp','security':'none'}}]} for name,port in [('Швеция',14501),('Латвия',14502),('Германия',14503)]]
    state={'profiles':profiles(),'mode':'valid','direct':True,'counts':{},'service_mode':'ok'}
    cert,key=LAB/'fixture.crt',LAB/'fixture.key'
    if not shared: command(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1',
             '-subj','/CN=podkop-tools-test','-addext','subjectAltName=IP:'+gateway])
    key.chmod(0o600)
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_HEAD(self):
            if self.path.startswith('/hang'):time.sleep(20)
            try:self.send_response(204);self.end_headers()
            except (BrokenPipeError,ConnectionResetError,ssl.SSLError):pass
        def do_GET(self):
            state['counts'][self.client_address[0]]=state['counts'].get(self.client_address[0],0)+1
            if self.path.startswith('/sub'):
                callback=state.pop('on_sub',None)
                if callback:callback()
                if state['mode']=='hang':
                    time.sleep(20)
                    try:self.send_response(503);self.end_headers()
                    except (BrokenPipeError,ConnectionResetError,ssl.SSLError):pass
                    return
                if state['mode'] in ('unavailable','hang') or (not state['direct'] and self.client_address[0]==client_ip):
                    self.send_response(503);self.end_headers();return
                body=b'[]' if state['mode']=='empty' else b'{broken' if state['mode']=='broken' else json.dumps(state['profiles'],ensure_ascii=False).encode()
                self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
            if self.path.startswith('/health'):
                self.send_response(204);self.end_headers();return
            if self.path.startswith('/service'):
                mode=state['service_mode'];body=b'<html><title>Telegram Web</title><meta content="https://web.telegram.org/k/"><script type="module"></script></html>'
                status=302 if mode=='redirect' else 403 if mode=='forbidden' else 200
                if mode=='generic':body=b'<html>Generic homepage</html>'
                if mode=='blocked':body+=b'Access denied'
                self.send_response(status);self.send_header('Content-Type','text/html')
                if mode=='redirect':self.send_header('Location',endpoint+'/service')
                self.send_header('Content-Length',str(524289 if mode=='oversized' else len(body)));self.end_headers()
                try:self.wfile.write(body)
                except (BrokenPipeError,ConnectionResetError,ssl.SSLError):pass
                return
            size=int(self.path.split('bytes=')[-1]);self.send_response(200);self.send_header('Content-Length',str(size));self.end_headers()
            try:
                # Deliberately slow enough to hit the TIME cap with a valid sample.
                for _ in range(size//16384):
                    time.sleep(.03125);self.wfile.write(os.urandom(16384));self.wfile.flush()
            except (BrokenPipeError,ConnectionResetError,ssl.SSLError):pass
    httpd=http.server.ThreadingHTTPServer((gateway,0),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key);httpd.socket=context.wrap_socket(httpd.socket,server_side=True)
    threading.Thread(target=httpd.serve_forever,daemon=True).start();endpoint=f'https://{gateway}:{httpd.server_address[1]}'
    dns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);dns.bind((gateway,0));dns_port=dns.getsockname()[1]
    def dns_loop():
        while True:
            try:
                data,addr=dns.recvfrom(2048);i=12
                while data[i]:i+=data[i]+1
                end=i+5;question=data[12:end];kind=struct.unpack('!H',data[i+1:i+3])[0]
                answer=b'\xc0\x0c'+struct.pack('!HHIH',1,1,60,4)+socket.inet_aton('203.0.113.10') if kind==1 else b''
                dns.sendto(data[:2]+struct.pack('!HHHHH',0x8180,1,bool(answer),0,0)+question+answer,addr)
            except (OSError,IndexError):return
    threading.Thread(target=dns_loop,daemon=True).start()
    try:
        if not shared: setup_packages()
        dex('mv','/bin/sleep','/bin/sleep-integer-test-original')
        write('/bin/sleep', '#!/bin/sh\ncase "$*" in *.*) touch /tmp/rejected-fractional-sleep; exit 1;; esac\nexec /bin/busybox sleep "$@"\n')
        dex('chmod','755','/bin/sleep')
        dex('sh','-c',"if pgrep -f '^/usr/bin/sing-box run -c /etc/sing-box/config.json' >/dev/null; then /etc/init.d/podkop stop >/dev/null 2>&1; fi; rm -rf /etc/podkop-tools /tmp/podkop-tools; rm -f /tmp/sing-box/cache.db*")
        cp(cert,'/tmp/fixture.crt');dex('sh','-c','cat /tmp/fixture.crt >> /etc/ssl/cert.pem')
        command(['docker','exec',EXIT,'sh','-c','mkdir -p /etc/ssl']);cp(cert,'/etc/ssl/cert.pem',EXIT)
        dex('mkdir','-p','/etc/config','/etc/iproute2','/etc/sing-box','/tmp/sing-box')
        write('/etc/iproute2/rt_tables','255 local\n254 main\n253 default\n105 podkop\n')
        # NTP/sysclock is not part of these tests and must not touch the host clock.
        dex('rm','-f','/usr/sbin/ntpd');write('/usr/sbin/ntpd','#!/bin/sh\nexit 0\n');dex('chmod','755','/usr/sbin/ntpd')
        pairs=[('Швеция',14501),('Латвия',14502),('Германия',14503)]
        if '--baseline' in sys.argv:
            pairs += [(name,14510+i) for i,name in enumerate(['Нидерланды','Финляндия','Франция','США','Великобритания','Польша','Эстония','Литва'])]
        links=[f'vless://{UUID}@{exit_ip}:{port}?encryption=none&type=tcp&security=none#{name}' for name,port in pairs]
        podkop="config settings 'settings'\n"
        for key,value in {'dns_type':'udp','dns_server':gateway+':'+str(dns_port),'bootstrap_dns_server':gateway,'service_listen_address':'127.0.0.1','dont_touch_dhcp':'1','config_path':'/etc/sing-box/config.json','cache_path':'/tmp/sing-box/cache.db','enable_yacd':'0','update_interval':'1d','log_level':'warn'}.items():podkop+=f" option {key} '{value}'\n"
        podkop+="config section 'main'\n option connection_type 'proxy'\n option proxy_config_type 'selector'\n option mixed_proxy_enabled '1'\n option mixed_proxy_port '2080'\n option user_domain_list_type 'dynamic'\n list user_domains 'chatgpt.com'\n"
        for link in links:podkop+=" list selector_proxy_links '"+link+"'\n"
        write('/etc/config/podkop',podkop)
        write('/etc/config/dhcp',"config dnsmasq\n list server '127.0.0.42'\n option noresolv '1'\n")
        write('/etc/config/sing-box',"config sing-box 'main'\n option enabled '1'\n option user 'root'\n option conffile '/etc/sing-box/config.json'\n option workdir '/tmp/sing-box'\n")
        dex('sh','-c','/usr/bin/podkop start >/tmp/toolkit-native-start.log 2>&1');time.sleep(.5)
        assert pid(),'native baseline failed'
        uci('podkop_tools.main.enabled',1)
        uci('podkop_tools_subscription.main.url',endpoint+'/sub?token='+TOKEN)
        uci('podkop_tools.main.health_url',endpoint+'/health')
        uci('podkop_tools.main.speed_url',endpoint+'/download?bytes={bytes}')
        uci('podkop_tools.main.bootstrap_dns',gateway);uci('podkop_tools.main.bootstrap_port',dns_port)
        task('seed');initial_pid=pid();initial_hash=fingerprint()
        record('native_stock_MAIN_seeded',public()['count']==len(pairs))
        if '--antigravity' in sys.argv:
            import antigravity
            antigravity.l = sys.modules[__name__]
            antigravity.custom(state,start_exit,endpoint)
            return
        if '--baseline' in sys.argv:
            task('select',next(n['id'] for n in public()['nodes'] if n['name']=='Латвия'))
            return
        if '--ownership' in sys.argv:
            import ownership
            ownership.l = sys.modules[__name__]
            ownership.custom(state,start_exit,endpoint)
            return
        if '--recovery' in sys.argv:
            import v020
            v020.l = sys.modules[__name__]
            v020.custom(state,start_exit,endpoint)
            return
        if '--rotation' in sys.argv:
            recovery_scenarios(state,start_exit,endpoint)
            return
        def set_source(url):
            r=subprocess.run(['docker','exec','-i',MAIN,'/usr/libexec/rpcd/podkop-tools','call','source'],input=json.dumps({'url':url}),capture_output=True,text=True)
            assert url not in r.stdout+r.stderr
            return json.loads(r.stdout)
        before=fingerprint();assert set_source('https://subscription.invalid/sub?token=GENERATED_SOURCE_TEST')['ok']
        assert public()['subscription_configured']
        secret_hash=dex('sha256sum','/etc/config/podkop_tools_subscription').stdout
        invalid=set_source('http://subscription.invalid/sub')
        record('private_source_RPC_and_invalid_URL_preserve_MAIN',not invalid['ok'] and fingerprint()==before and dex('sha256sum','/etc/config/podkop_tools_subscription').stdout==secret_hash and 'subscription_url' not in dex('cat','/etc/config/podkop_tools').stdout)
        assert set_source(endpoint+'/sub?token='+TOKEN)['ok']
        task('fetch');record('DIRECT_fetch_no_reload',public()['fetch_path']=='direct' and pid()==initial_pid)
        # Initial English URI labels differ from provider names: labels only, no reload.
        initial_hash=fingerprint()
        state['profiles'].reverse();task('fetch');record('unchanged_reordered_subscription_no_write_no_reload',fingerprint()==initial_hash and pid()==initial_pid)
        chosen=public()['selected_id'];state['direct']=False;start_exit([14502,14503])
        task('fetch');record('blocked_active_fetch_via_saved_server_MAIN_unchanged',public()['fetch_path']=='saved_server' and public()['selected_id']==chosen and pid()==initial_pid)
        # Invalid/unavailable bodies must preserve both accepted config and pending state.
        for mode in ['unavailable','empty','broken']:
            state['mode']=mode;before=fingerprint();out=task('fetch',check=False)
            record(mode+'_keeps_working_configuration',out['ok'] is False and fingerprint()==before and pid()==initial_pid)
        state['mode']='unavailable';out=task('check',check=False)
        record('periodic_fetch_never_switches_on_failure',not out['ok'] and public()['selected_id']==chosen and pid()==initial_pid)
        task('health');record('first_health_failure_preserves_manual_choice',public()['selected_id']==chosen and pid()==initial_pid)
        import v020
        v020.l=sys.modules[__name__];v020.prime(chosen)
        task('health');record('unavailable_subscription_recovers_from_saved_snapshot',public()['selected_id']!=chosen and pid()==initial_pid)
        state['mode']='valid';task('check');record('priority_recovery_without_reload',public()['selected_id']!=chosen and pid()==initial_pid)
        state['direct']=True
        # Change a nonactive server and retain selected identity.
        selected=public()['selected_id'];selected_name=next(n['name'] for n in public()['nodes'] if n['id']==selected)
        changed_profile=next(p for p in state['profiles'] if p['remarks']!=selected_name)
        changed_profile['outbounds'][0]['settings']['vnext'][0]['port']=14504
        task('fetch');before=fingerprint();record('nonactive_change_deferred',public()['pending'] and pid()==initial_pid)
        task('due');record('manual_policy_prevents_scheduled_apply',fingerprint()==before and pid()==initial_pid)
        # The actual cron entrypoints, not a manual apply, must complete deferred updates.
        uci('podkop_tools.main.apply_policy','window');uci('podkop_tools.main.defer_hours',1)
        hour=int(dex('date','+%H').stdout.strip());uci('podkop_tools.main.apply_hour',hour)
        task('due');record('scheduled_apply_waits_for_defer_age',fingerprint()==before and pid()==initial_pid)
        pending=json.loads(dex('cat','/etc/podkop-tools/pending.json').stdout)
        pending['first_seen']=int(time.time())-7200;pending['version_at']=pending['first_seen'];write('/etc/podkop-tools/pending.json',json.dumps(pending))
        uci('podkop_tools.main.apply_hour',(hour+1)%24)
        task('due');record('scheduled_apply_waits_for_window',fingerprint()==before and pid()==initial_pid)
        uci('podkop_tools.main.apply_hour',hour)
        task('check');task('due')
        record('automatic_fetch_deferred_apply_updates_MAIN',not public()['pending'] and fingerprint()!=before and pid()!=initial_pid and public()['selected_id']==selected)
        scheduled_pid=pid();scheduled_hash=fingerprint();task('check');task('due')
        record('scheduled_unchanged_poll_no_write_no_reload',pid()==scheduled_pid and fingerprint()==scheduled_hash)
        # Names alone cannot bypass the apply gate and do not require a restart.
        renamed=next(p for p in state['profiles'] if p['remarks']!=selected_name)
        renamed['remarks']+=' renamed'
        task('fetch');record('labels_only_fetch_deferred_without_MAIN_write',public()['pending'] and fingerprint()==scheduled_hash and pid()==scheduled_pid)
        pending=json.loads(dex('cat','/etc/podkop-tools/pending.json').stdout)
        pending['first_seen']=int(time.time())-7200;pending['version_at']=pending['first_seen'];write('/etc/podkop-tools/pending.json',json.dumps(pending))
        task('due');record('scheduled_apply_daily_cooldown',public()['pending'] and fingerprint()==scheduled_hash and pid()==scheduled_pid)
        accepted=json.loads(dex('cat','/etc/podkop-tools/state.json').stdout)
        accepted['last_apply']=int(time.time())-90000;write_signed_state(accepted)
        task('due');record('scheduled_labels_apply_no_reload',not public()['pending'] and fingerprint()!=scheduled_hash and pid()==scheduled_pid and public()['selected_id']==selected)
        # Retain the independent explicit runtime-apply test after scheduled apply.
        renamed['outbounds'][0]['settings']['vnext'][0]['port']=14505
        task('fetch');uci('podkop_tools.main.apply_policy','manual')
        task('apply');record('explicit_apply_preserves_selected_ID',public()['selected_id']==selected and pid()!=initial_pid)
        task('latency',selected);record('native_latency_retained',any(n['test'].get('latency') is not None for n in public()['nodes'] if n['id']==selected))
        start_exit([14501,14502,14503,14504,14505])
        service_before=fingerprint();service_pid=pid()
        uci('podkop_tools.main.service_url',endpoint+'/service')
        service_id=next(n['id'] for n in public()['nodes'] if n['id']!=selected)
        def service_result():
            task('service',service_id)
            return next(n['test']['service'] for n in public()['nodes'] if n['id']==service_id)
        exit_source='127.0.0.2' if shared else exit_ip
        exit_count=state['counts'].get(exit_source,0);direct_count=state['counts'].get(client_ip,0)
        record('service_specific_VLESS_TLS_status_content',service_result()['ok'] and state['counts'].get(exit_source,0)==exit_count+1 and state['counts'].get(client_ip,0)==direct_count)
        for mode,error in [('redirect','service_unexpected_http_status'),('forbidden','service_unexpected_http_status'),('generic','service_content_mismatch'),('blocked','service_block_page'),('oversized','service_response_too_large')]:
            state['service_mode']=mode;r=service_result();record('service_rejects_'+mode,not r['ok'] and r['error']==error)
        state['service_mode']='ok'
        # Removing trust must reject TLS even though status/content would otherwise match.
        certs=dex('cat','/etc/ssl/cert.pem').stdout
        write('/etc/ssl/cert.pem',certs.replace(cert.read_text(),''))
        try:r=service_result();record('service_rejects_untrusted_TLS',not r['ok'] and r['error']=='service_tls_failed')
        finally:write('/etc/ssl/cert.pem',certs)
        accepted=json.loads(dex('cat','/etc/podkop-tools/state.json').stdout)
        tested=next(n for n in accepted['nodes'] if n['id']==service_id)
        tested_port=tested['outbound']['server_port'];start_exit([p for p in [14501,14502,14503,14504,14505] if p!=tested_port])
        count=sum(state['counts'].values());r=service_result()
        record('service_blocked_VLESS_no_DIRECT_or_MAIN_fallback',not r['ok'] and sum(state['counts'].values())==count)
        start_exit([14501,14502,14503,14504,14505])
        record('service_preserves_MAIN_PID_selection',fingerprint()==service_before and pid()==service_pid and public()['selected_id']==selected)
        before_pid=pid();uci('podkop_tools.main.speed_seconds',2)
        pool=concurrent.futures.ThreadPoolExecutor(max_workers=1)
        ongoing=pool.submit(dex,'curl','-fsS','--max-time','25','--proxy','http://127.0.0.1:2080','--noproxy','','--output','/dev/null','--write-out','%{size_download}',endpoint+'/download?bytes=8388608')
        time.sleep(.3);task('speed',selected)
        test=next(n['test'] for n in public()['nodes'] if n['id']==selected)
        record('time_limited_partial_throughput',test.get('mbps',0)>0 and test['bytes']<4194304 and test['limit']=='time')
        record('speed_preserves_MAIN_and_process',public()['selected_id']==selected and pid()==before_pid)
        record('speed_preserves_ongoing_client_transfer',float(ongoing.result().stdout)==8388608 and pid()==before_pid);pool.shutdown()
        samples=json.loads(dex('cat','/tmp/podkop-tools/tests.json').stdout)
        samples[selected]['speed_started_at']=int(time.time())-61
        write('/tmp/podkop-tools/tests.json',json.dumps(samples))
        uci('podkop_tools.main.speed_bytes',1048576);uci('podkop_tools.main.speed_seconds',6)
        task('speed',selected);test=next(n['test'] for n in public()['nodes'] if n['id']==selected)
        record('byte_limit_independent_of_time_limit',test.get('mbps',0)>0 and test['bytes']==1048576 and test['seconds']<6 and test['limit']=='bytes')
        speed_before=fingerprint();speed_pid=pid();started=time.monotonic()
        for node in public()['nodes']:
            if node['id']==selected:continue
            outcome=task('speed',node['id'],check=False)
            measured=next(n['test'] for n in public()['nodes'] if n['id']==node['id'])
            record('distinct_speed_without_global_cooldown_'+node['name'],outcome['ok'] and measured.get('mbps',0)>0 and measured['bytes']==1048576)
            record('speed_cleanup_before_next_'+node['name'],dex('sh','-c',"test ! -e /tmp/podkop-tools/job && test ! -e /tmp/podkop-tools/lock && ! pgrep -f '^/usr/bin/sing-box run -c /tmp/podkop-tools/job/probe.json'").returncode==0)
        current=public()
        record('sequential_speed_queue_under_60_seconds',time.monotonic()-started<60)
        record('independent_speed_retry_deadlines',current['speed_next_at']==0 and all(n['test'].get('speed_next_at',0)>time.time() for n in current['nodes']))
        record('speed_queue_preserves_MAIN_PID_Selector',fingerprint()==speed_before and pid()==speed_pid and current['selected_id']==selected)
        samples=json.loads(dex('cat','/tmp/podkop-tools/tests.json').stdout)
        samples[selected]['speed_started_at']=int(time.time())-61
        write('/tmp/podkop-tools/tests.json',json.dumps(samples))
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            running=pool.submit(task,'speed',selected)
            deadline=time.monotonic()+10
            while dex('test','-f','/tmp/podkop-tools/job/probe.pid',check=False).returncode and time.monotonic()<deadline:time.sleep(.1)
            assert time.monotonic()<deadline,'speed probe did not start'
            record('single_speed_probe_process',len(dex('pgrep','-f',r'^/usr/bin/sing-box run -c /tmp/podkop-tools/job/probe.json').stdout.splitlines())==1)
            rejected=task('speed',service_id,check=False)
            record('mutex_rejects_concurrent_speed',not rejected['ok'] and rejected['error']=='busy')
            record('mutex_rejects_concurrent_cron_health',task('health',check=False).get('error')=='busy')
            record('speed_worker_completes_and_cleans',running.result()['ok'] and dex('test','!','-e','/tmp/podkop-tools/job').returncode==0)
        # Diagnostics bind each metric to the accepted profile, despite stable ID reuse.
        task('latency',selected);task('service',selected)
        current=public();record('diagnostic_receipt_and_configured_budget',current['measurement']['kind']=='service' and current['measurement']['id']==selected and current['speed_bytes']==1048576 and next(n['test']['speed_next_at'] for n in current['nodes'] if n['id']==selected)>time.time())
        original=json.loads(dex('cat','/etc/podkop-tools/state.json').stdout);mutated=copy.deepcopy(original)
        next(n for n in mutated['nodes'] if n['id']==selected)['outbound']['server_port']=14999
        before=fingerprint();old_pid=pid();write_signed_state(mutated)
        measured=next(n['test'] for n in public()['nodes'] if n['id']==selected)
        record('same_ID_changed_profile_marks_all_metrics_stale',measured['latency_stale'] and measured['speed_stale'] and measured['service']['stale'])
        write_signed_state(original)
        measured=next(n['test'] for n in public()['nodes'] if n['id']==selected)
        record('unchanged_profile_metrics_current_without_reload',not measured['latency_stale'] and not measured['speed_stale'] and not measured['service']['stale'] and fingerprint()==before and pid()==old_pid)
        seq=public()['measurement']['sequence'];out=task('speed',selected,check=False)
        receipt=public()['measurement'];record('cooldown_failure_has_completion_receipt',not out['ok'] and receipt['sequence']==seq+1 and receipt['error']=='speed_cooldown')
        task('restore');record('boot_restore_keeps_selected_ID',public()['selected_id']==selected)
        record('public_status_no_subscription_credentials',TOKEN not in json.dumps(public()) and UUID not in json.dumps(public()) and 'profile_signature' not in json.dumps(public()) and 'subscription_url' not in public())
        # Durable transaction recovery uses the actual previous snapshot/native reload.
        task('rollback');record('explicit_rollback_restores_previous_MAIN',public()['selected_id']==selected and public()['count']==3)
        # Inject one native reload failure after commit; subsequent rollback is real.
        baseline_uci=dex('sha256sum','/etc/config/podkop').stdout
        baseline_out=json.loads(dex('cat','/etc/sing-box/config.json').stdout)['outbounds']
        changed_profile['outbounds'][0]['settings']['vnext'][0]['port']=14505
        task('fetch');assert public()['pending']
        dex('mv','/usr/bin/timeout','/usr/bin/timeout-podkop-test-original')
        write('/usr/bin/timeout', '#!/bin/sh\nif [ "$*" = "-s TERM 120 /etc/init.d/podkop reload" ] && [ ! -e /tmp/injected-reload-failure ]; then touch /tmp/injected-reload-failure; exit 1; fi\nexec /usr/bin/timeout-podkop-test-original "$@"\n')
        dex('chmod','755','/usr/bin/timeout')
        try:
            out=task('apply',check=False)
            record('failed_apply_automatically_rolls_back',not out['ok'] and out['error']=='apply_rolled_back' and dex('sha256sum','/etc/config/podkop').stdout==baseline_uci and public()['selected_id']==selected and json.loads(dex('cat','/etc/sing-box/config.json').stdout)['outbounds']==baseline_out)
        finally:
            dex('rm','/usr/bin/timeout');dex('mv','/usr/bin/timeout-podkop-test-original','/usr/bin/timeout');dex('rm','-f','/tmp/injected-reload-failure')
        # r6 refuses an unproven legacy marker; it never restores MAIN blindly.
        write('/etc/podkop-tools/transaction.json','{"started":1}')
        marker_pid=pid();marker_hash=fingerprint();metric=task('service',selected,check=False)
        record('service_never_recovers_or_reloads_MAIN',not metric['ok'] and metric['error']=='recovery_required' and pid()==marker_pid and fingerprint()==marker_hash and dex('test','-f','/etc/podkop-tools/transaction.json',check=False).returncode==0)
        out=task('restore',check=False)
        record('unproven_interrupted_marker_fails_closed',not out['ok'] and out['error']=='recovery_conflict' and fingerprint()==marker_hash and pid()==marker_pid)
        dex('rm','/etc/podkop-tools/transaction.json')
        # Own cron lines are idempotent and unrelated crontab entries survive.
        dex('sh','-c',"echo '1 1 * * * echo preserved # external' | crontab -")
        dex('/etc/init.d/podkop-tools','reload');dex('/etc/init.d/podkop-tools','reload')
        cron=dex('crontab','-l').stdout
        record('cron_idempotent_preserves_other_jobs',cron.count('# podkop-tools')==4 and '# external' in cron and 'task health' in cron)
        uci('podkop_tools.main.enabled',0);dex('/etc/init.d/podkop-tools','reload')
        record('disabled_cron_and_stale_job_are_inert','# podkop-tools' not in dex('crontab','-l').stdout and task('check').get('disabled'))
        command(['docker','cp',MAIN+':/usr/share/podkop-tools/compat.sha256',str(LAB/'compat.original')])
        write('/usr/share/podkop-tools/compat.sha256','0'*64+'  /usr/bin/podkop\n')
        before=fingerprint();old_pid=pid();out=task('fetch',check=False);record('implementation_hash_does_not_gate_operations',out['ok'] and fingerprint()==before and pid()==old_pid and public()['compatibility']['capabilities']['fetch']['available'])
        cp(LAB/'compat.original','/usr/share/podkop-tools/compat.sha256')
        # Active removal requires a verified fallback; current choice stays until apply.
        state['profiles']=[p for p in state['profiles'] if p['remarks']!=selected_name]
        # The nonactive fixture changed earlier must be reachable for this scenario.
        start_exit([14501,14502,14503,14504,14505])
        old_selected=public()['selected_id'];task('fetch')
        record('removed_selected_deferred_until_verified_apply',public()['selected_id']==old_selected and public()['pending'])
        task('apply');record('removed_selected_uses_verified_fallback',public()['count']==2 and public()['selected_id']!=old_selected)
        # Legacy schema migrations are covered by ownership.py with synthetic state.
        # Historical private APKs are deliberately not a public test dependency.
        # Reinstallation cannot rewrite native files, restart MAIN or lose private settings.
        package_before=fingerprint();package_pid=pid();private_config=dex('sha256sum','/etc/config/podkop_tools','/etc/config/podkop_tools_subscription').stdout
        native_files=dex('sha256sum','-c','/usr/share/podkop-tools/compat.sha256').stdout
        dex('apk','add','--allow-untrusted','--no-network','--force-reinstall','/tmp/tools.apk')
        record('APK_reinstall_preserves_config_and_dataplane',fingerprint()==package_before and pid()==package_pid and dex('sha256sum','/etc/config/podkop_tools','/etc/config/podkop_tools_subscription').stdout==private_config and dex('sha256sum','-c','/usr/share/podkop-tools/compat.sha256').stdout==native_files)
        owners=dex('ls','-ln','/usr/libexec/podkop-tools/task').stdout.split()
        record('APK_executable_owned_by_root',owners[2:4]==['0','0'])
        record('real_ubus_status_registered',json.loads(dex('ubus','call','podkop-tools','status').stdout)['count']==2)
        # Real BusyBox cannot wait with flock -w. The addon must still serialize removal.
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            holding=pool.submit(dex,'sh','-c','exec 9>/tmp/podkop-tools/job.lock; flock -n 9; touch /tmp/held-addon-lock; sleep 3; rm /tmp/held-addon-lock')
            deadline=time.monotonic()+5
            while dex('test','-e','/tmp/held-addon-lock',check=False).returncode and time.monotonic()<deadline:time.sleep(.1)
            assert time.monotonic()<deadline,'lock holder did not start'
            started=time.monotonic();dex('/usr/share/podkop-tools/pre-deinstall')
            record('BusyBox_safe_deinstall_waits_for_running_task',time.monotonic()-started>=1 and holding.result().returncode==0 and fingerprint()==package_before and pid()==package_pid)
        state_before=dex('sha256sum','/etc/podkop-tools/state.json').stdout
        dex('apk','del','luci-app-subscription-toolkit')
        record('APK_removal_preserves_native_dataplane_and_backups',fingerprint()==package_before and pid()==package_pid and dex('sha256sum','/etc/podkop-tools/state.json').stdout==state_before and dex('sha256sum','/etc/config/podkop_tools','/etc/config/podkop_tools_subscription').stdout==private_config)
        dex('apk','add','--allow-untrusted','--no-network','/tmp/tools.apk')
        record('all_jobs_use_integer_only_BusyBox_sleep',dex('test','!','-e','/tmp/rejected-fractional-sleep',check=False).returncode==0)
        (LAB/'integration-results.json').write_text(json.dumps({'passed':results,'environment':'OpenWrt 25.12.5 x86_64 Docker userspace; stock 0.7.22 source payload and official sing-box1.14.2; host kernel; not router validation'},ensure_ascii=False,indent=2)+'\n')
    finally:
        if dex('test','-e','/bin/sleep-integer-test-original',check=False).returncode==0:
            dex('rm','/bin/sleep');dex('mv','/bin/sleep-integer-test-original','/bin/sleep')
        httpd.shutdown();dns.close();command(['docker','rm','-f',EXIT],check=False)

if __name__=='__main__':main()
