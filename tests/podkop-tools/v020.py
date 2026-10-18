#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""v0.2 real API/VLESS/DNS/recovery tests in the exclusively owned OpenWrt fixture."""
import json,time,subprocess
import integration as l
passed=[]
def check(name,value):
 assert value,name
 passed.append(name);print('PASS v020',name,flush=True)
def read(path):return json.loads(l.dex('cat',path).stdout)
def driver(body):
 prefix=(l.ROOT/'root/usr/libexec/podkop-tools/backend.uc').read_text().split('let command = ARGV')[0]
 l.dex('mkdir','-p','/tmp/podkop-tools/job/uci','/tmp/podkop-tools/job/delta','/tmp/podkop-tools/job/rulesets')
 l.write('/tmp/v020-driver.uc',prefix+'\n'+body)
 r=l.dex('ucode','/tmp/v020-driver.uc',check=False)
 l.dex('rm','-rf','/tmp/podkop-tools/job','/tmp/v020-driver.uc')
 if r.returncode:raise AssertionError(r.stdout+r.stderr)
 return json.loads(r.stdout)
def prime(selected):
 # Advance only observation clocks in synthetic tmpfs, never production time.
 driver("let st=state_seed(), id="+json.dumps(selected)+", node=filter(st.nodes,n=>n.id==id)[0], now=time();let key=hash(canonical(node.outbound));save(TMP+'/health-v2.json',{boot:trim(fs.readfile('/proc/sys/kernel/random/boot_id')),at:now-60,cursor:0,records:{[id]:{key,at:now-60,ok:false,failures:2,first_failed:now-121}}});print('{}');")
def continuing_scan():
 result=driver("let clock=monotime(),events=[],st=state_seed(),selected=actual_selection(st),node=filter(st.nodes,n=>n.id==selected)[0];monotime=function(){return clock;};strict_probe=function(node,seconds){push(events,'probe');clock+=14;return false;};fetch=function(){push(events,'fetch');die('subscription_unavailable_or_invalid');};save(TMP+'/recovery-v2.json',{selected_id:selected,signature:hash(canonical(node.outbound)),stage:'reserves',cursor:0,seen:{},fetch_at:time()-301});recover_active(st,selected);let progress=load(TMP+'/recovery-v2.json');fs.unlink(TMP+'/recovery-v2.json');print(sprintf('%J',{events,cursor:progress.cursor,seen:length(keys(progress.seen))}));")
 check('continuing_scan_checks_reserve_before_due_fetch',result['events']==['probe','fetch'] and result['cursor']==1 and result['seen']==1)
def custom(state,start_exit,endpoint):
 nodes=l.public()['nodes'];main=nodes[1]['id'];other=nodes[0]['id']
 check('local_probe_error_is_unknown',driver("get_through=function(out,url,path,seconds,cap){die('probe_start_failed');};print(sprintf('%J',{ok:strict_probe({outbound:{type:'direct'}},5)}));")['ok'] is None)
 result=driver("let probes=0;strict_probe=function(node,seconds){probes++;return false;};fetch=function(){die('subscription_unavailable_or_invalid');};let st=state_seed(),selected=actual_selection(st);recover_active(st,selected);let first=probes;recover_active(st,selected);fs.unlink(TMP+'/recovery-v2.json');print(sprintf('%J',{first,probes}));")
 check('emergency_attempts_rate_limited_not_server_choices',result['first']>0 and result['first']==result['probes'])
 continuing_scan()
 l.task('select',main);before=l.fingerprint();pid=l.pid();t=time.monotonic();l.task('health')
 check('ordinary_two_probes_no_reload',l.fingerprint()==before and l.pid()==pid and time.monotonic()-t<15)
 check('ordinary_records_two_samples',sum(len(read('/tmp/podkop-tools/history/'+f)) for f in l.dex('ls','/tmp/podkop-tools/history').stdout.split() if f.endswith('.json'))>=2)
 # A repeat with saved monotonic state must keep evidence, even when probes are skipped.
 previous_health=read('/tmp/podkop-tools/health-v2.json');l.task('health')
 check('repeated_health_keeps_monotonic_state',read('/tmp/podkop-tools/health-v2.json')==previous_health and l.pid()==pid)
 # Two API delay requests hang in the controlled HTTPS endpoint until their deadlines.
 l.uci('podkop_tools.main.health_url',endpoint+'/hang');l.dex('rm','-f','/tmp/podkop-tools/health-v2.json')
 t=time.monotonic();out=l.task('health',check=False);elapsed=time.monotonic()-t
 hung_elapsed=elapsed
 check('two_hung_probes_total_under15',elapsed<=15.5 and l.pid()==pid and l.public()['selected_id']==main)
 check('single_failed_tick_not_outage',not l.public().get('recovery',{}).get('stage'))
 l.uci('podkop_tools.main.health_url',endpoint+'/health')
 # The unavailable subscription must not consume the entire pass or prevent reserve use.
 state['mode']='hang';start_exit((14501,14503));prime(main)
 t=time.monotonic();l.task('health');elapsed=time.monotonic()-t
 check('unavailable_subscription_reaches_saved_reserve',l.public()['selected_id']!=main and elapsed<46 and l.pid()==pid)
 check('failover_preserves_preferred',l.public()['preferred_id']==main)
 # External Podkop selection is adopted; restore must not put the old choice back.
 selected=l.public()['selected_id'];target=next(n for n in nodes if n['id']!=selected)
 driver("api('/proxies/main-out','PUT',{name:'main-"+str(nodes.index(target)+1)+"-out'});print('{}');")
 l.task('restore');check('boot_adopts_unobserved_external_choice',l.public()['preferred_id']==target['id'] and l.public()['selected_id']==target['id'])
 # Own unacknowledged intent must never turn a reserve into preferred.
 driver("let m=load(BASE+'/selection.json');m.preferred_id="+json.dumps(main)+";m.selected_id="+json.dumps(main)+";m.intent={from:m.selected_id,to:"+json.dumps(target['id'])+",reason:'outage'};save(BASE+'/selection.json',m);print('{}');")
 l.task('restore');check('boot_completes_own_intent_without_new_preference',l.public()['preferred_id']==main)
 # Even after three recent non-emergency transitions, hard failure may use another reserve.
 state['mode']='valid';start_exit((14501,14503));l.task('select',main)
 driver("let m=load(BASE+'/selection.json');m.transitions=[time()-3,time()-2,time()-1];m.last_switch=time();save(BASE+'/selection.json',m);print('{}');")
 prime(main);l.task('health');check('emergency_not_blocked_by_nonemergency_limit',l.public()['selected_id']!=main and l.public()['preferred_id']==main)
 # Provider rotates the preferred/current ID: update same ID before reserve.
 start_exit((14501,14503,14504));l.task('select',main)
 next(p for p in state['profiles'] if p['remarks']=='Латвия')['outbounds'][0]['settings']['vnext'][0]['port']=14504
 prime(main);l.task('health');accepted=read('/etc/podkop-tools/state.json')
 check('fresh_subscription_updates_same_ID_first',l.public()['selected_id']==main and next(n for n in accepted['nodes'] if n['id']==main)['outbound']['server_port']==14504)
 # Updated preferred profile while on reserve: sparse recovery samples survive 5m gaps.
 driver("let st=state_seed();select_node(st,"+json.dumps(other)+",'outage');print('{}');")
 next(p for p in state['profiles'] if p['remarks']=='Латвия')['outbounds'][0]['settings']['vnext'][0]['port']=14505
 start_exit((14501,14503,14505));l.task('fetch')
 driver("let now=time(),p=load(BASE+'/pending.json'),n=filter(p.nodes,n=>n.id=="+json.dumps(main)+")[0],id=n.id,key=hash(canonical(n.outbound)),m=load(BASE+'/selection.json');m.last_switch=now-601;m.transitions=[];save(BASE+'/selection.json',m);save(TMP+'/health-v2.json',{boot:trim(fs.readfile('/proc/sys/kernel/random/boot_id')),at:now-60,preferred_at:now-301,cursor:0,records:{[id]:{key,at:now-300,ok:true,successes:2,success_since:now-601,failures:0}}});print('{}');")
 l.task('health')
 check('rotated_preferred_recovers_after_stable_samples',l.public()['selected_id']==main and l.public()['preferred_id']==main and l.public()['last_switch_reason']=='failback')
 # Real generation must preserve DNS and DIRECT precedence, not just UCI text.
 l.dex('uci','set','podkop.steam_direct=section');l.dex('uci','set','podkop.steam_direct.connection_type=exclusion')
 l.dex('uci','set','podkop.steam_direct.user_domain_list_type=dynamic');l.dex('uci','add_list','podkop.steam_direct.user_domains=steam.test')
 l.dex('uci','add_list','podkop.main.user_domains=steam.test');l.dex('uci','add_list','podkop.main.user_domains=discord.test');l.dex('uci','commit','podkop')
 l.dex('/etc/init.d/podkop','reload');l.task('fetch')
 runtime=read('/etc/sing-box/config.json');rules=runtime['route']['rules']
 direct=next(i for i,r in enumerate(rules) if r.get('outbound')=='direct-out')
 proxy=next(i for i,r in enumerate(rules) if r.get('outbound')=='main-out' and 'rule_set' in r)
 check('exclusion_DIRECT_precedes_proxy',direct<proxy and 'steam_direct-user-domains-ruleset' in str(rules[direct]))
 dns=runtime['dns'];check('exclusion_DNS_generated',any('steam_direct-user-domains-ruleset' in str(r) for r in dns['rules']))
 check('proxy_domain_semantics_preserved','discord.test' in l.dex('cat','/tmp/sing-box/rulesets/main-user-domains-ruleset.json').stdout)
 # A second provider update exercises staging/apply and native rollback with exclusions.
 next(p for p in state['profiles'] if p['remarks']=='Швеция')['outbounds'][0]['settings']['vnext'][0]['port']=14503
 l.task('fetch');l.task('apply');l.task('rollback')
 rules=read('/etc/sing-box/config.json')['route']['rules'];check('apply_rollback_preserve_effective_exclusion',any(r.get('outbound')=='direct-out' and 'steam_direct' in str(r) for r in rules))
 # Back-to-back restores do not reload or change the adopted choice.
 before=l.fingerprint();pid=l.pid();l.task('restore');l.task('restore');check('boot_restore_never_reloads_healthy_runtime',before==l.fingerprint() and pid==l.pid())
 (l.LAB/'v020-results.json').write_text(json.dumps({'passed':passed,'hung_probe_seconds':hung_elapsed,'unavailable_subscription_recovery_seconds':elapsed},indent=2)+'\n')
