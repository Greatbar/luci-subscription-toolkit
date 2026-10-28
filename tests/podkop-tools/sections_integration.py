#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""General independent native sections + explicitly owned subscription Selector."""
import copy,json
import v020


def scenarios(lab, c, state, start_exit, endpoint):
    results = {}
    def read(path): return json.loads(lab.dex('cat', path).stdout)
    def check(name, ok):
        assert ok, name
        results[name] = 'passed'
        print('PASS general', c['profile'], name, flush=True)
    def set_(section, fields):
        lab.dex('uci','set','podkop.'+section+'=section')
        for key,value in fields.items():
            lab.dex('uci','set','podkop.'+section+'.'+key+'='+str(value))
    def domain(section, value):
        lab.dex('uci','set','podkop.'+section+'.user_domain_list_type=dynamic')
        lab.dex('uci','add_list','podkop.'+section+'.user_domains='+value)
    def runtime():return read('/etc/sing-box/config.json')
    def snapshot(owned=False):
        # Independent of the product's validation implementation.
        cfg=runtime();out={o['tag']:o for o in cfg['outbounds']};tags={'main-out',*out['main-out']['outbounds']}
        if owned:
            tags.add('antigravity-out');tags.update(out['antigravity-out'].get('outbounds',[]))
        cfg['outbounds']=[o for o in cfg['outbounds'] if o['tag'] not in tags]
        for rs in cfg['route'].get('rule_set',[]):
            if rs.get('type')=='local':rs['path']=json.loads(lab.dex('cat',rs['path']).stdout)
        return cfg
    v020.l=lab
    def driver(body):return v020.driver(body)
    def ag_group():return driver("print(sprintf('%J',api('/proxies/antigravity-out')));")
    def choose_ag(id):
        nodes=read('/etc/podkop-tools/state.json')['nodes'];index=next(i for i,n in enumerate(nodes) if n['id']==id)
        driver("api('/proxies/antigravity-out','PUT',{name:'antigravity-"+str(index+1)+"-out'});print('{}');")
    def ag_id():return lab.public()['antigravity']['selected_id']
    def update(name,port):next(p for p in state['profiles'] if p['remarks']==name)['outbounds'][0]['settings']['vnext'][0]['port']=port
    try:
        nodes=read('/etc/podkop-tools/state.json')['nodes'];main=nodes[0]['id'];ag=nodes[1]['id'];third=nodes[2]['id']
        lab.task('select',main)
        custom=copy.deepcopy(nodes[1]['outbound']);custom['server_port']=15999
        set_('antigravity',{'connection_type':'proxy','proxy_config_type':'outbound','outbound_json':json.dumps(custom)})
        domain('antigravity','unmanaged.example')
        set_('relay_custom',{'connection_type':'vpn','interface':'lo','domain_resolver_enabled':'1','domain_resolver_dns_type':'udp','domain_resolver_dns_server':'127.0.0.1:19053'})
        domain('relay_custom','resolver.example')
        set_('other_proxy',{'connection_type':'proxy','proxy_config_type':'outbound','outbound_json':json.dumps(custom)})
        domain('other_proxy','other.example')
        set_('direct_misc',{'connection_type':'exclusion'});domain('direct_misc','direct.example')
        set_('deny_misc',{'connection_type':'block'});domain('deny_misc','blocked.example')
        lab.dex('uci','commit','podkop')
        # Short exact native precondition before transactional/recovery scenarios.
        lab.dex('/usr/libexec/podkop-tools/generate','--check')
        lab.dex('/etc/init.d/podkop','reload');lab.dex('sing-box','check','-c','/etc/sing-box/config.json')
        check('native_independent_proxy_VPN_exclusion_block',all(any(o['tag']==tag for o in runtime()['outbounds']) for tag in ('relay_custom-out','other_proxy-out','antigravity-out')) and any(r.get('action')=='reject' for r in runtime()['route']['rules']))
        check('unmarked_AG_is_not_owned','antigravity' not in lab.public())
        independent=snapshot();before=lab.fingerprint();pid=lab.pid()
        # Real fetch must accept these types and stage an independent update.
        update(nodes[2]['name'],14504);start_exit((14501,14502,14503,14504,14505,14506,14507))
        lab.task('fetch');check('fetch_preserves_independent_sections',lab.public()['pending'] and independent==snapshot() and before==lab.fingerprint() and pid==lab.pid())
        lab.task('apply');check('apply_preserves_independent_sections',independent==snapshot())
        # Latest independent UCI edits must survive rollback, even before native reload.
        lab.dex('uci','add_list','podkop.relay_custom.user_domains=new-route.example');lab.dex('uci','commit','podkop')
        lab.task('rollback')
        check('rollback_preserves_latest_independent_edits','new-route.example' in lab.dex('uci','get','podkop.relay_custom.user_domains').stdout)
        independent=snapshot()
        selected_name=next(n['name'] for n in nodes if n['id']==main)
        update(selected_name,14506)
        old_port=next(n['outbound']['server_port'] for n in read('/etc/podkop-tools/state.json')['nodes'] if n['id']==main)
        start_exit(tuple(p for p in (14501,14502,14503,14504,14505,14506,14507) if p!=old_port))
        v020.prime(main);lab.task('health')
        check('recovery_preserves_independent_sections',independent==snapshot() and lab.public()['selected_id']==main and next(n['outbound']['server_port'] for n in read('/etc/podkop-tools/state.json')['nodes'] if n['id']==main)==14506)
        start_exit((14501,14502,14503,14504,14505,14506,14507))
        # Explicit user opt-in is the only transition into Toolkit ownership.
        accepted=read('/etc/podkop-tools/state.json')['nodes'];ag_node=next(n for n in accepted if n['id']==ag)
        lab.dex('uci','set','podkop.antigravity.subscription_node_id='+ag)
        lab.dex('uci','set','podkop.antigravity.outbound_json='+json.dumps(ag_node['outbound']))
        lab.dex('uci','set','podkop.antigravity.mixed_proxy_enabled=1');lab.dex('uci','set','podkop.antigravity.mixed_proxy_port=2081');lab.dex('uci','commit','podkop')
        lab.dex('/etc/init.d/podkop','reload')
        independent=snapshot(True);before=lab.fingerprint();pid=lab.pid()
        lab.task('fetch')
        check('legacy_AG_migration_staged_without_writes',lab.public()['pending'] and before==lab.fingerprint() and pid==lab.pid())
        lab.task('apply')
        check('AG_Selector_contains_full_subscription',len(ag_group()['all'])==len(lab.public()['nodes']) and runtime()['outbounds'] and ag_id()==ag and lab.public()['selected_id']==main)
        # Baseline projection before migration excludes a direct owned group too.
        check('AG_migration_preserves_independent_routes',independent==snapshot(True) and lab.dex('uci','get','podkop.antigravity.mixed_proxy_port').stdout.strip()=='2081')
        choose_ag(third);lab.task('restore');independent=snapshot(True)
        before=lab.fingerprint();pid=lab.pid();lab.task('health')
        check('AG_choice_independent_from_MAIN',ag_id()==third and lab.public()['selected_id']==main and before==lab.fingerprint() and pid==lab.pid())
        accepted=read('/etc/podkop-tools/state.json')['nodes'];target=next(n for n in accepted if n['id']==ag)
        update(target['name'],14505);lab.task('fetch');lab.task('apply')
        check('AG_update_keeps_stable_ID_choice',ag_id()==third and independent==snapshot(True))
        lab.task('rollback');check('AG_rollback_restores_choice_and_routes',ag_id()==third and independent==snapshot(True))
        # Model a real cold-cache default without changing host boot or restarting MAIN.
        driver("let s=load(BASE+'/antigravity-selection.json');s.boot='previous-fixture-boot';save(BASE+'/antigravity-selection.json',s);api('/proxies/antigravity-out','PUT',{name:'antigravity-1-out'});print('{}');")
        before=lab.fingerprint();pid=lab.pid();lab.task('restore')
        check('AG_cold_restore_keeps_MAIN',ag_id()==third and lab.public()['selected_id']==main and before==lab.fingerprint() and pid==lab.pid())
        # External MAIN selection is adopted only after the accepted signature validates.
        driver("api('/proxies/main-out','PUT',{name:'main-2-out'});fs.unlink(TMP+'/health-v2.json');print('{}');")
        lab.task('health')
        check('external_MAIN_choice_adopted_without_conflict',read('/etc/podkop-tools/state.json')['selected_id']==ag and lab.public()['selected_id']==ag and ag_id()==third)
        lab.task('select',main)
        state['profiles']=[p for p in state['profiles'] if p['remarks']!=next(n['name'] for n in accepted if n['id']==third)]
        lab.task('fetch');lab.task('apply')
        check('removed_AG_choice_falls_back_with_reason',ag_id()==main and lab.public()['antigravity']['reason']=='node_removed' and independent==snapshot(True))
        # Deliberate native output collision is rejected before live write.
        before=lab.fingerprint();pid=lab.pid()
        error=driver("let s=state_seed(),r=json(sprintf('%J',runtime()));push(r.outbounds,json(sprintf('%J',r.outbounds[0])));let error;try{validate_generated_routes(r,s.nodes);}catch(e){error=e.message;}print(sprintf('%J',{error}));")
        check('duplicate_managed_tag_rejected',error=={'error':'routing_changed'} and before==lab.fingerprint() and pid==lab.pid())
        # A syntactically valid independent route/profile change must be caught
        # between baseline and candidate, before touching live UCI.
        before=lab.fingerprint();pid=lab.pid()
        conflict=driver("let original_run=run,calls=0;run=function(args){let result=original_run(args);if(args[0]=='/usr/libexec/podkop-tools/generate'&&length(args)==1){calls++;if(calls==2){let generated=load(JOB+'/generated.json');filter(generated.outbounds,o=>o.tag=='other_proxy-out')[0].server_port=15998;save(JOB+'/generated.json',generated);}}return result;};let s=state_seed(),error;try{stage({nodes:s.nodes});}catch(e){error=e.message;}print(sprintf('%J',{error,calls}));")
        check('independent_profile_change_blocked_before_write',conflict=={'error':'routing_changed','calls':2} and before==lab.fingerprint() and pid==lab.pid())
        latency=driver("let group=api('/proxies/antigravity-out');let response=api('/proxies/'+group.all[0]+'/delay?timeout=3000&url='+encode(cfg('health_url')),null,null,true);print(sprintf('%J',{ok:type(response.delay)=='int'&&response.delay>=0}));")
        check('AG_native_leaf_latency_API',latency=={'ok':True})
        # A post-write failure must exercise the real durable rollback path.
        before=lab.fingerprint();independent=snapshot(True)
        failed=driver("let s=state_seed(),selected=actual_selection(s),nodes=json(sprintf('%J',s.nodes));filter(nodes,n=>n.id!=selected)[0].outbound.server_port=14507;let c=plan(s.nodes,nodes,selected,hash,s.selected_id);c.before_selected=selected;let calls=0;health=function(n){calls++;return calls==1;};let error;try{apply_candidate(c,false);}catch(e){error=e.message;}print(sprintf('%J',{error,transaction:fs.stat(BASE+'/transaction.json')!=null}));")
        check('failed_apply_rolls_back_AG_and_independent_routes',failed=={'error':'apply_rolled_back','transaction':False} and ag_id()==main and independent==snapshot(True) and before==lab.fingerprint())
        state['profiles']=[p for p in state['profiles'] if p['remarks']!=selected_name]
        lab.task('fetch');lab.task('apply')
        check('removed_MAIN_uses_verified_fallback',lab.public()['selected_id']==ag and ag_id()==ag and independent==snapshot(True))
    finally:
        (c['lab']/'sections-results.json').write_text(json.dumps({'profile':{k:c[k] for k in ('podkop','sing_box')},'checks':results,'environment':'isolated OpenWrt25.12.5 x86_64; native APIs/generation; synthetic VLESS/HTTPS/DNS; no hardware certification'},ensure_ascii=False,indent=2)+'\n')
