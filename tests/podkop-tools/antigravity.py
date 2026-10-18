#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Real native generation/API/rollback; provider HTTPS and health are synthetic."""
import json
import v020 as helper

def custom(state,start_exit,endpoint):
    helper.l=l
    check=helper.check;read=helper.read
    native_driver=helper.driver
    def driver(body):
        l.write('/tmp/ag-provider.json',json.dumps(state['profiles']))
        return native_driver("get_through=function(out,url,file,seconds,cap){if(file!='/dev/null')fs.writefile(file,fs.readfile('/tmp/ag-provider.json'));return {code:0,metrics:{http_code:index(url,'/sub')>=0?200:204,time_total:0.005}};};delay_probe=function(state,node){return {ok:true,delay:5};};\n"+body)
    native_task=l.task
    def task(name,*args,check=True):
        expressions={'fetch':'fetch()','check':'fetch()','due':'apply_pending(false)','health':'execution_deadline=monotime()+15;check_active()'}
        if name=='apply':expressions[name]='apply_pending(true,'+json.dumps(args[0] if args else l.public()['pending_version'])+')'
        if name not in expressions:return native_task(name,*args,check=check)
        result=driver("let result={ok:true};try{"+expressions[name]+";}catch(e){result={ok:false,error:e.message};}print(sprintf('%J',result));")
        if check:assert result['ok'],result
        return result
    l.task=task
    nodes=read('/etc/podkop-tools/state.json')['nodes'];main=nodes[0]['id'];ag=nodes[1]['id']
    l.task('select',main)
    before=l.fingerprint();pid=l.pid()
    driver("let s=state_seed();stage({nodes:s.nodes});print('{}');")
    l.task('fetch');l.task('health');l.task('due')
    check('single_MAIN_without_AG_remains_compatible',l.public()['compatible'] and l.public()['preferred_id']==main and l.fingerprint()==before and l.pid()==pid)
    for delta in (-180,180):
        result=driver("let st=load(TMP+'/health-v2.json');st.at=time()-60;st.mono=monotime()+"+str(delta)+";st.records={canary:{ok:false}};save(TMP+'/health-v2.json',st);execution_deadline=monotime()+15;check_active();print(sprintf('%J',{reset:load(TMP+'/health-v2.json').records.canary==null}));")
        check('clock_jump_resets_observations_'+str(delta),result['reset'])
    def set_(key,value):l.dex('uci','set','podkop.'+key+'='+str(value))
    # DNS remains real and fully inside the fixture; no host-network dependency.
    l.dex('dnsmasq','--port=19053','--no-resolv','--no-hosts','--address=/#/203.0.113.10','--pid-file=/tmp/ag-dns.pid')
    set_('settings.dns_server','127.0.0.1:19053')
    set_('antigravity','section');set_('antigravity.connection_type','proxy')
    set_('antigravity.proxy_config_type','outbound');set_('antigravity.subscription_node_id',ag)
    set_('antigravity.outbound_json',json.dumps(nodes[1]['outbound']))
    set_('antigravity.mixed_proxy_enabled',1);set_('antigravity.mixed_proxy_port',2081)
    set_('antigravity.user_domain_list_type','dynamic')
    l.dex('uci','add_list','podkop.antigravity.user_domains=ag.test')
    set_('steam_direct','section');set_('steam_direct.connection_type','exclusion')
    set_('steam_direct.user_domain_list_type','dynamic')
    l.dex('uci','add_list','podkop.steam_direct.user_domains=steam.test')
    l.dex('uci','reorder','podkop.antigravity=1');l.dex('uci','commit','podkop')
    l.dex('/etc/init.d/podkop','reload')
    check('AG_compatible_separate_from_MAIN',l.public()['compatible'])
    l.task('fetch')
    def profile():return next(x for x in read('/etc/sing-box/config.json')['outbounds'] if x['tag']=='antigravity-out')
    rules=read('/etc/sing-box/config.json')['route']['rules']
    check('mixed_ports_and_DIRECT',all(any(r.get('inbound')==inb and r.get('outbound')==out for r in rules) for inb,out in [('main-mixed-in','main-out'),('antigravity-mixed-in','antigravity-out')]) and read('/etc/sing-box/config.json')['route']['final']=='direct-out' and any('steam_direct' in str(r) and r.get('outbound')=='direct-out' for r in rules))
    pid=l.pid();before=l.fingerprint();l.task('health');l.task('due');l.task('statistics',ag,'24h')
    check('health_due_statistics_keep_MAIN_preferred_and_PID',l.public()['preferred_id']==main and l.public()['selected_id']==main and l.pid()==pid and l.fingerprint()==before)
    # Updating only AG's endpoint must update its generated profile in the same apply.
    state['profiles'][1]['outbounds'][0]['settings']['vnext'][0]['port']=14504
    start_exit((14501,14502,14503,14504));l.task('fetch')
    check('fetch_stages_without_writing_live_AG',profile()['server_port']==14502)
    l.task('apply');check('apply_rotates_bound_AG_same_ID',profile()['server_port']==14504 and l.public()['selected_id']==main and l.public()['preferred_id']==main)
    l.dex('uci','add_list','podkop.antigravity.user_domains=after-apply.test');l.dex('uci','commit','podkop')
    l.task('rollback')
    check('rollback_restores_AG_endpoint_preserves_routes_and_user_edits',profile()['server_port']==14502 and 'after-apply.test' in l.dex('uci','get','podkop.antigravity.user_domains').stdout and l.public()['preferred_id']==main)
    # TLS parameters are copied from the bound candidate, never a frozen VLESS snapshot.
    result=driver("let s=state_seed(),c={nodes:json(sprintf('%J',s.nodes))};c.nodes[1].outbound.tls={enabled:true,server_name:'rotated.example'};stage(c);let r=load(JOB+'/generated.json');print(sprintf('%J',filter(r.outbounds,n=>n.tag=='antigravity-out')[0].tls));")
    check('TLS_rotation_staged',result=={'enabled':True,'server_name':'rotated.example'})
    # Missing bindings fail before any write, and a stale own profile is not silently blessed.
    result=driver("let s=state_seed(),before=filehash('/etc/config/podkop'),error;try{stage({nodes:filter(s.nodes,n=>n.id!="+json.dumps(ag)+")});}catch(e){error=e.message;}print(sprintf('%J',{error,unchanged:before==filehash('/etc/config/podkop')}));")
    check('removed_bound_ID_fails_closed',result=={'error':'antigravity_node_missing','unchanged':True})
    result=driver("let c=cursor(),original=c.get('podkop','antigravity','outbound_json'),s=state_seed(),out=json(original);out.server_port=14999;c.set('podkop','antigravity','outbound_json',sprintf('%J',out));c.commit('podkop');let error;try{actual_selection(s);}catch(e){error=e.message;}c.set('podkop','antigravity','outbound_json',original);c.commit('podkop');print(sprintf('%J',{error}));")
    check('stale_AG_profile_rejected',result=={'error':'state_conflict'})
    for kind in ('proxy','vpn','block'):
        set_('unknown','section');set_('unknown.connection_type',kind);l.dex('uci','commit','podkop')
        check('unknown_'+kind+'_rejected',not l.public()['compatible'])
        l.dex('uci','delete','podkop.unknown');l.dex('uci','commit','podkop')
    # Genuine recovery path also stages the bound profile; preferred remains MAIN's.
    l.task('fetch')
    result=driver("let s=state_seed(),selected=actual_selection(s),n=filter(load(BASE+'/pending.json').nodes,n=>n.id=="+json.dumps(ag)+")[0];activate_verified(s,selected,n,'outage');print('{}');")
    check('recovery_rotates_AG_without_overwriting_MAIN_preferred',profile()['server_port']==14504 and l.public()['preferred_id']==main)
    l.task('select',main)
    # Force a post-acceptance failure and use the real durable rollback.
    result=driver("let s=state_seed(),nodes=json(sprintf('%J',s.nodes));nodes[1].outbound.server_port=14502;let c=plan(s.nodes,nodes,actual_selection(s),hash,s.selected_id);c.before_selected=actual_selection(s);let calls=0;health=function(n){calls++;return calls==1;};let error;try{apply_candidate(c,false);}catch(e){error=e.message;}print(sprintf('%J',{error,transaction:fs.stat(BASE+'/transaction.json')!=null}));")
    check('failed_apply_rolls_back_AG_and_MAIN',result=={'error':'apply_rolled_back','transaction':False} and profile()['server_port']==14504 and l.public()['selected_id']==main and l.public()['preferred_id']==main)
    result=driver("let original=write_main,original_profile=cursor().get('podkop','antigravity','outbound_json');write_main=function(source,expected){let c=cursor(),out=json(c.get('podkop','antigravity','outbound_json'));out.server_port=14999;c.set('podkop','antigravity','outbound_json',sprintf('%J',out));c.commit('podkop');die('apply_failed');};let s=state_seed(),nodes=json(sprintf('%J',s.nodes));nodes[1].outbound.server_port=14502;let c=plan(s.nodes,nodes,actual_selection(s),hash,s.selected_id);c.before_selected=actual_selection(s);health=function(n){return true;};let error;try{apply_candidate(c,false);}catch(e){error=e.message;}let kept=json(cursor().get('podkop','antigravity','outbound_json')).server_port==14999;let cfg=cursor();cfg.set('podkop','antigravity','outbound_json',original_profile);cfg.commit('podkop');fs.unlink(BASE+'/transaction.json');print(sprintf('%J',{error,kept}));")
    check('transaction_AG_drift_blocks_rollback_preserves_foreign_edit',result=={'error':'recovery_conflict','kept':True})
    (l.LAB/'antigravity-results.json').write_text(json.dumps({'passed':helper.passed},indent=2)+'\n')
