#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
"""Native ownership/CAS/rollback regression on the isolated synthetic fixture."""
import importlib.util,json,subprocess,sys,time,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
import integration as l
passed=[]
def check(name,ok):
 assert ok,name
 passed.append(name);print('PASS ownership',name,flush=True)
def read(path):return json.loads(l.dex('cat',path).stdout)
def driver(body):
 script="umask 077\nmkdir -p /tmp/podkop-tools/job/uci /tmp/podkop-tools/job/delta /tmp/podkop-tools/job/rulesets\nsed '/^let command = ARGV/,$d' /usr/libexec/podkop-tools/backend.uc > /tmp/ownership.uc\ncat >> /tmp/ownership.uc <<'UC'\n"+body+"\nUC\nucode /tmp/ownership.uc\n"
 r=subprocess.run(['docker','exec','-i',l.MAIN,'sh','-s'],input=script,text=True,capture_output=True)
 l.dex('rm','-rf','/tmp/podkop-tools/job')
 if r.returncode:raise AssertionError(r.stderr)
 return json.loads(r.stdout)
def custom(state,start_exit,endpoint):
 original=read('/etc/podkop-tools/state.json');before=l.fingerprint();pid=l.pid()
 check('URI_fragment_hash_and_query_order',driver("print(sprintf('%J',{equal:canonical(server_uri('vless://id@127.0.0.1:443?type=tcp&security=none#Latvia%20%232'))==canonical(server_uri('vless://id@127.0.0.1:443?security=none&type=tcp#Latvia #2'))}));")['equal'])
 check('native_seed_valid',driver("print(sprintf('%J', {id:actual_selection(load(BASE+'/state.json'))}));")['id']==original['selected_id'])
 l.dex('uci','add_list','podkop.main.user_domains=discord.gg');l.dex('uci','commit','podkop')
 check('adding_domain_fetch_allowed',l.task('fetch').get('ok') is True)
 check('native_owned_semantics',l.public()['count']==3 and l.public()['selected_id']==original['selected_id'])
 l.dex('uci','del_list','podkop.main.user_domains=discord.gg');l.dex('uci','commit','podkop')
 check('deleting_domain_fetch_allowed',l.task('fetch').get('ok') is True and l.pid()==pid)
 l.uci('podkop.settings.log_level','info')
 check('independent_setting_fetch_allowed',l.task('fetch').get('ok') is True)
 # Manual server mutation must still fail, including a nonselected server.
 links=l.dex('uci','get','podkop.main.selector_proxy_links').stdout.strip().split(' ')
 l.dex('uci','delete','podkop.main.selector_proxy_links')
 for i,link in enumerate(links):l.dex('uci','add_list','podkop.main.selector_proxy_links='+ (link.replace(':14503',':14599') if i==2 else link))
 l.dex('uci','commit','podkop')
 check('manual_server_conflict',l.task('fetch',check=False).get('error')=='state_conflict')
 l.dex('uci','delete','podkop.main.selector_proxy_links')
 for link in links:l.dex('uci','add_list','podkop.main.selector_proxy_links='+link)
 l.dex('uci','commit','podkop')
 saved=read('/etc/podkop-tools/state.json');bad=json.loads(json.dumps(saved));bad['nodes'][0]['id']='a'*64;l.write('/etc/podkop-tools/state.json',json.dumps(bad))
 check('stable_id_corruption_blocks',l.task('fetch',check=False).get('error')=='state_conflict');l.write('/etc/podkop-tools/state.json',json.dumps(saved))
 # CAS detects a normal UCI edit between staging and installation, never overwrites it.
 out=driver("""let state=load(BASE+'/state.json'),candidate={nodes:state.nodes};stage(candidate);
let p=run(['/bin/sh','-c',"uci add_list podkop.main.user_domains='concurrent.example'; uci commit podkop"]);
let error=null;try{write_main(JOB+'/uci/podkop',candidate.staged_from);}catch(e){error=e.message;}
print(sprintf('%J',{error,domains:cursor().get('podkop','main','user_domains')}));""")
 check('concurrent_uci_CAS_no_lost_domain',out['error']=='uci_changed' and 'concurrent.example' in out['domains'])
 # Native inode lock makes a UCI writer wait. It then merges its delta over our new servers.
 out=driver("""let fd=fs.open('/etc/config/podkop','r+');fd.lock('x');
let child=fs.popen("exec " + fd.fileno() + ">&-; touch /tmp/queued-start; uci add_list podkop.main.user_domains='queued.example'; uci commit podkop; echo committed",'r');
run(['/bin/sleep','1']);let blocked=fs.stat('/tmp/queued-start') && !length(fs.readfile('/tmp/.uci/podkop')??'');
fd.close();let result=child.read('all');child.close();print(sprintf('%J',{blocked,result}));""")
 check('native_UCI_writer_waits_for_inode_lock',out['blocked'] and 'committed' in out['result'])
 # Full native subscription rotation/apply keeps edits introduced after fetch.
 state['profiles'][0]['outbounds'][0]['settings']['vnext'][0]['port']=14504;start_exit((14501,14502,14503,14504))
 check('subscription_update_fetch',l.task('fetch').get('ok') is True)
 pending=read('/etc/podkop-tools/pending.json')
 corrupt=json.loads(json.dumps(pending));corrupt['nodes'][0]['outbound']['server_port']=14999;l.write('/etc/podkop-tools/pending.json',json.dumps(corrupt))
 check('corrupt_pending_blocks',l.task('health',check=False).get('error')=='state_conflict');l.write('/etc/podkop-tools/pending.json',json.dumps(pending))
 l.dex('uci','add_list','podkop.main.user_domains=after-fetch.example');l.dex('uci','commit','podkop')
 check('apply_preserves_latest_domains',l.task('apply',pending['source_hash']).get('ok') is True and 'after-fetch.example' in l.dex('uci','get','podkop.main.user_domains').stdout)
 check('rotation_keeps_stable_ids', [x['id'] for x in read('/etc/podkop-tools/state.json')['nodes']]==[x['id'] for x in original['nodes']])
 l.dex('uci','add_list','podkop.main.user_domains=after-apply.example');l.dex('uci','commit','podkop')
 check('rollback_preserves_later_user_edit',l.task('rollback').get('ok') is True and 'after-apply.example' in l.dex('uci','get','podkop.main.user_domains').stdout)
 check('rollback_restores_only_servers', ':14501' in l.dex('uci','get','podkop.main.selector_proxy_links').stdout)
 # A UCI edit during endpoint verification aborts before write/reload and preserves it.
 oldpid=l.pid()
 out=driver("""let st=load(BASE+'/state.json'),nodes=json(sprintf('%J',st.nodes));nodes[0].name='Race label';
let candidate=plan(st.nodes,nodes,actual_selection(st),hash,st.selected_id);candidate.before_selected=actual_selection(st);
health=function(node){must(['/bin/sh','-c',"uci add_list podkop.main.user_domains='during-health.example'; uci commit podkop"],'test_failed');return true;};
let error=null;try{apply_candidate(candidate,false);}catch(e){error=e.message;}
print(sprintf('%J',{error,transaction:fs.stat(BASE+'/transaction.json')!=null,domain:cursor().get('podkop','main','user_domains')}));""")
 check('edit_during_apply_aborts_without_reload',out['error']=='uci_changed' and not out['transaction'] and 'during-health.example' in out['domain'] and l.pid()==oldpid)
 # Post-acceptance failure exercises the real durable rollback, including state checksums.
 out=driver("""let st=load(BASE+'/state.json'),nodes=json(sprintf('%J',st.nodes));nodes[0].name='Fail label';
let candidate=plan(st.nodes,nodes,actual_selection(st),hash,st.selected_id);candidate.before_selected=actual_selection(st);
let calls=0;health=function(node){calls++;return calls==1;};
let error=null;try{apply_candidate(candidate,false);}catch(e){error=e.message;}
print(sprintf('%J',{error,transaction:fs.stat(BASE+'/transaction.json')!=null,id:actual_selection(load(BASE+'/state.json'))}));""")
 check('failed_apply_native_rollback',out['error']=='apply_rolled_back' and not out['transaction'] and out['id']==original['selected_id'])
 check('failed_apply_retains_user_domains','during-health.example' in l.dex('uci','get','podkop.main.user_domains').stdout)
 # Unknown transaction marker never triggers blind legacy restore.
 l.write('/etc/podkop-tools/transaction.json','{"started":1}');finger=l.fingerprint();oldpid=l.pid()
 check('unknown_transaction_blocks',l.task('fetch',check=False).get('error')=='recovery_conflict')
 check('unknown_transaction_does_not_reload',l.fingerprint()==finger and l.pid()==oldpid)
 l.dex('rm','/etc/podkop-tools/transaction.json')
 # Use the real preapply anchor to prove a legacy hash transition with independent edits.
 restored=read('/etc/podkop-tools/state.json');legacy=json.loads(json.dumps(restored))
 for k in ('schema_version','managed_hash','state_hash'):legacy.pop(k,None)
 # canonical expected old accepted bytes for the standalone migration fixture
 out=driver("""let s=load(BASE+'/state.json');let c={nodes:s.nodes};stage(c);print(sprintf('%J',{hash:filehash(JOB+'/uci/podkop')}));""")
 legacy['podkop_hash']=out['hash']
 # To produce a valid anchor for this known legacy snapshot, preserve the full current
 # independent settings and let migration perform the identical libuci round trip.
 for name in ('podkop','dhcp','sing-box'):l.dex('cp','/etc/config/'+name,'/etc/podkop-tools/rollback/'+name)
 l.write('/etc/podkop-tools/rollback/state.json',json.dumps(legacy))
 sums=l.dex('sha256sum',*[ '/etc/podkop-tools/rollback/'+x for x in ('podkop','dhcp','sing-box','state.json')]).stdout;l.write('/etc/podkop-tools/rollback/SHA256SUMS',sums)
 l.write('/etc/podkop-tools/state.json',json.dumps(legacy));l.dex('uci','add_list','podkop.main.user_domains=legacy-new.example');l.dex('uci','commit','podkop')
 check('proven_legacy_migration',l.task('migrate').get('ok') is True)
 check('migration_preserves_MAIN_PID_ids',l.pid()==oldpid and 'legacy-new.example' in l.dex('uci','get','podkop.main.user_domains').stdout and [x['id'] for x in read('/etc/podkop-tools/state.json')['nodes']]==[x['id'] for x in legacy['nodes']])
 check('health_after_migration',l.task('health').get('ok') is True)
 check('due_after_migration',l.task('due').get('ok') is True)
 (l.LAB/'ownership-results.json').write_text(json.dumps({'passed':passed,'environment':'isolated OpenWrt + synthetic HTTPS/DNS/VLESS'},indent=2)+'\n')
if __name__=='__main__':
 sys.argv.append('--ownership');l.main()
