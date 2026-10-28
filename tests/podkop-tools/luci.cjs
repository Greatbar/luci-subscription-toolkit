// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
// Executes the shipped LuCI views with their actual rpc declarations and DOM calls.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../htdocs/luci-static/resources/view/podkop-tools');
function E(tag, attrs={}, children=[]) {
  return {tag,attrs,children:Array.isArray(children)?children:[children],disabled:!!attrs.disabled};
}
function walk(n) { return !n || typeof n !== 'object' ? [] : [n,...n.children.flatMap(walk)]; }
function text(n) { return n == null ? '' : typeof n !== 'object' ? String(n) : n.children.map(text).join(' '); }
function button(n,label) { return walk(n).find(n=>n.tag==='button' && text(n)===label); }
function env(write=true) {
  const requests=[], polls=[], modal={}, options=[];const hooks={};
  let clock=1000000;
  const state={speed_bytes:4194304,speed_next_at:0,count:2,pending:true,pending_version:'c'.repeat(64),nodes:[{id:'a'.repeat(64),name:'Швеция',selected:true,test:{speed_next_at:0,mbps:4.5,bytes:1048576,seconds:2,at:1,latency:45}},
     {id:'b'.repeat(64),name:'<img src=x onerror=alert(1)>',test:{speed_next_at:0,error:'speed_failed',at:1,service:{ok:false,error:'service_content_mismatch',at:2}}}]};
  const rpc={declare:spec=>async (...args)=>{requests.push({method:spec.method,args});if(hooks.time)hooks.time(spec.method,clock);if(hooks.request)hooks.request(spec.method,args);
    if(['latency','service','speed'].includes(spec.method)) {state.measurement={sequence:(state.measurement?.sequence||0)+1,id:args[0],kind:spec.method,ok:args[0]!==state.failId||!!state.failKind&&spec.method!==state.failKind,error:'router_busy'};if(spec.method==='speed'){state.speed_next_at=clock/1000+60;state.nodes.find(n=>n.id===args[0]).test.speed_next_at=state.speed_next_at;}}
    if(spec.method==='batch') { const [ids,kinds,cap,token]=args; state.batch={token,state:'finished',done:ids.length,total:ids.length,errors:state.failId?{[state.failId]:{latency:'router_busy'}}:{}}; }
    return spec.method==='status'?state:{ok:true,queued:true};}};
  const form={NamedSection:0,Flag:1,Value:2,ListValue:3,DynamicList:4,
    Map:class {section(){return {option(type,name){const o={name,type,values:[],value(k,v){this.values.push([k,v]);},depends(){}};options.push(o);return o;}};} render(){return E('form');}}};
  const args={E,view:{extend:x=>x},dom:{content:(n,c)=>{n.children=[c];}},rpc,poll:{add:f=>polls.push(f)},
    ui:{showModal:(title,children)=>{modal.tree=E('div',{},children);},hideModal:()=>{modal.tree=null;},addNotification(){ }},
    setTimeout:(resolve,ms)=>{clock+=ms;resolve();},Date:class extends Date {static now(){return clock;}},L:{hasViewPermission:()=>write},document:{addEventListener(){}},form};
  function load(name){return new Function(...Object.keys(args),fs.readFileSync(path.join(root,name+'.js'),'utf8'))(...Object.values(args));}
  return {requests,polls,modal,options,state,load,hooks};
}
(async()=>{
  const h=env(), v=h.load('dashboard'), tree=v.render(await v.load());
  assert.ok(text(tree).includes('Серверы и подписка'));
  assert.equal(walk(tree).filter(n=>n.tag==='th').length,7);
  assert.ok(walk(tree).find(n=>n.tag==='input'&&n.attrs.type==='checkbox'&&n.attrs.checked));
  assert.ok(text(tree).includes('4,5 Мбит/с')); assert.ok(text(tree).includes('Швеция'));assert.ok(text(tree).includes('speed_failed'));
  assert.ok(text(tree).includes('<img src=x onerror=alert(1)>'));assert.ok(!JSON.stringify(tree).includes('innerHTML'));
  await button(tree,'Проверить подписку').attrs.click();assert.equal(h.requests.filter(r=>r.method!=='status').at(-1).method,'fetch');
  await button(tree,'Применить изменения').attrs.click();assert.ok(h.modal.tree);assert.ok(!h.requests.some(r=>r.method==='apply'));
  h.state.pending_version='d'.repeat(64);await h.polls[0]();
  await button(h.modal.tree,'Применить').attrs.click();assert.equal(h.requests.filter(r=>r.method!=='status').at(-1).method,'apply');
  assert.deepEqual(h.requests.filter(r=>r.method==='apply').at(-1).args,['c'.repeat(64)],'confirmation stays bound to the version shown before a poll');
  // A whole list uses one backend request and keeps independent metrics.
  h.requests.length=0;h.state.failId='a'.repeat(64);
  await button(tree,'Запустить проверку').attrs.click();
  let batches=h.requests.filter(r=>r.method==='batch');
  assert.equal(batches.length,1,'one batch RPC per list');
  assert.deepEqual(batches[0].args.slice(0,2),[h.state.nodes.map(n=>n.id),['latency','service']]);
  assert.ok(text(tree).includes('Telegram Web'));assert.ok(text(tree).includes('Проверено 2 из 2'));
  assert.ok(text(tree).includes('router_busy'));assert.ok(text(tree).includes('4,5 Мбит/с'));
  assert.ok(!h.requests.some(r=>['select','apply','fetch','seed','latency','service'].includes(r.method)));
  h.state.failId=null;
  // Consent bounds the entire speed batch; no browser queue/cooldown sleeps.
  v.tests={speed:true};h.requests.length=0;
  await button(tree,'Запустить проверку').attrs.click();assert.ok(text(h.modal.tree).includes('8 МиБ'));
  await button(h.modal.tree,'Запустить').attrs.click();
  assert.equal(h.requests.filter(r=>r.method==='batch').length,1);
  assert.equal(h.requests.find(r=>r.method==='batch').args[2],4194304);
  h.state.speed_bytes=5000000;await button(tree,'Запустить проверку').attrs.click();
  assert.ok(text(h.modal.tree).includes('До 9,6 МиБ'));await button(h.modal.tree,'Отмена').attrs.click();
  // Changed traffic cap after consent never starts a batch.
  h.requests.length=0;await button(tree,'Запустить проверку').attrs.click();h.state.speed_bytes=16777216;
  await button(h.modal.tree,'Запустить').attrs.click();assert.ok(!h.requests.some(r=>r.method==='batch'));
  assert.ok(text(tree).includes('Лимит трафика изменился'));
  // Short complete samples remain numeric and are labelled.
  h.state.nodes[0].test.short_sample=true;await h.polls[0]();
  assert.ok(text(tree).includes('4,5 Мбит/с'));assert.ok(text(tree).includes('короткая выборка'));
  h.state.nodes[0].test.speed_stale=true;h.state.nodes[0].test.latency_stale=true;h.state.nodes[0].test.latency_at=1;
  await h.polls[0]();assert.ok(!text(tree).includes('4,5 Мбит/с'));assert.ok(text(tree).includes('Устарела'));
  h.state.busy=true;await h.polls[0]();assert.ok(walk(tree).filter(n=>n.tag==='button'&&text(n)!=='Обновить список').every(n=>n.disabled));
  const ro=env(false),rv=ro.load('dashboard'),rt=rv.render(await rv.load());assert.ok(walk(rt).filter(n=>n.tag==='button'&&text(n)!=='Обновить список').every(n=>n.disabled));
  // Busy failure belongs to this token, and old receipts cannot finish a new job.
  const busy=env(),bv=busy.load('dashboard');bv.render(await bv.load());
  busy.hooks.request=kind=>{if(kind==='status'&&busy.state.batch)busy.state.batch={...busy.state.batch,state:'failed',error:'busy',done:0};};
  await bv.runTests(busy.state.nodes.map(n=>n.id),['latency']);
  assert.ok(bv.progress.message.includes('busy'));assert.equal(bv.running,false);
  const cancel=env(),cv=cancel.load('dashboard');cv.render(await cv.load());let reads=0;
  cancel.hooks.request=kind=>{
    if(kind==='status'&&cancel.state.batch) {
      if(++reads===1) {cancel.state.batch.state='running';cv.stopTests();}
      else cancel.state.batch.state='cancelled';
    }
  };
  await cv.runTests(cancel.state.nodes.map(n=>n.id),['latency','service']);
  assert.equal(cancel.requests.filter(r=>r.method==='cancel').length,1);
  assert.equal(cancel.requests.filter(r=>r.method==='batch').length,1);
  assert.ok(cv.progress.message.includes('остановлена'));
  // Compatibility is per operation: an unknown version or unavailable generator
  // must not disable subscription fetch, Selector switching or measurements.
  const compatibility=env(), compatibilityView=compatibility.load('dashboard');
  compatibility.state.compatible=false;
  compatibility.state.compatibility={versions:{openwrt:'25.12.2',podkop:'0.7.14',sing_box:'1.12.17'},warnings:['untested_versions'],capabilities:{
    fetch:{available:true},monitoring:{available:true},selector:{available:true},switch:{available:true},
    apply:{available:false,reason:'generator_unavailable'},rollback:{available:false,reason:'rollback_unavailable'},
    recovery:{available:false,reason:'generator_unavailable'},measurement:{available:true}}};
  const compatibilityTree=compatibilityView.render(await compatibilityView.load());
  assert.ok(text(compatibilityTree).includes('Эта связка версий не проверена'));
  assert.ok(text(compatibilityTree).includes('0.7.14'));
  assert.ok(text(compatibilityTree).includes('Нет подходящего генератора Podkop'));
  assert.equal(button(compatibilityTree,'Проверить подписку').disabled,false);
  assert.equal(button(compatibilityTree,'Прочитать текущий MAIN').disabled,false);
  assert.equal(button(compatibilityTree,'Применить изменения').disabled,true);
  assert.equal(button(compatibilityTree,'Запустить проверку').disabled,false);
  await button(compatibilityTree,'Проверить подписку').attrs.click();
  assert.ok(compatibility.requests.some(r=>r.method==='fetch'));
  const applyCount=compatibility.requests.filter(r=>r.method==='apply').length;
  await compatibilityView.operation('apply','c'.repeat(64));
  assert.equal(compatibility.requests.filter(r=>r.method==='apply').length,applyCount);
  await compatibilityView.runTests(compatibility.state.nodes.map(n=>n.id),['latency']);
  assert.ok(compatibility.requests.some(r=>r.method==='batch'));
  compatibility.state.compatibility.capabilities.switch={available:false,reason:'api_unavailable'};
  compatibility.state.compatibility.capabilities.measurement={available:false,reason:'sing_box_unavailable'};
  await compatibility.polls[0]();
  assert.ok(walk(compatibilityTree).filter(n=>n.tag==='button'&&text(n)==='Выбрать').every(n=>n.disabled));
  assert.equal(button(compatibilityTree,'Запустить проверку').disabled,true);
  assert.equal(button(compatibilityTree,'Проверить подписку').disabled,false);
  const batchesBefore=compatibility.requests.filter(r=>r.method==='batch').length;
  await compatibilityView.startTests(compatibility.state.nodes.map(n=>n.id),['latency']);
  await compatibilityView.runTests(compatibility.state.nodes.map(n=>n.id),['latency']);
  assert.equal(compatibility.requests.filter(r=>r.method==='batch').length,batchesBefore);
  const selectsBefore=compatibility.requests.filter(r=>r.method==='select').length;
  await compatibilityView.operation('select',compatibility.state.nodes[1].id);
  assert.equal(compatibility.requests.filter(r=>r.method==='select').length,selectsBefore);
  compatibility.state.downloaded_count=3;
  compatibility.state.fetch_path='system';
  const stageReasons={validation_failed:'sing-box отклонил подготовленную конфигурацию',
    generation_failed:'Не удалось подготовить конфигурацию Podkop',
    generated_nodes_mismatch:'Генератор изменил список серверов',routing_changed:'Подготовленная конфигурация меняет защищённые маршруты',
    state_conflict:'Состояние Toolkit расходится с конфигурацией Podkop',operation_failed:'Не удалось выполнить операцию'};
  for (const [reason,label] of Object.entries(stageReasons)) {
    compatibility.state.fetch_stage_error=reason;
    await compatibility.polls[0]();
    assert.ok(text(compatibilityTree).includes('Подписка загружена: 3 серверов'));
    assert.ok(text(compatibilityTree).includes('Подготовка применения: '+label));
    assert.equal(button(compatibilityTree,'Проверить подписку').disabled,false);
  }
  assert.ok(text(compatibilityTree).includes('Путь загрузки: Системное подключение'));
  compatibility.state.fetch_path='direct';
  await compatibility.polls[0]();
  assert.ok(text(compatibilityTree).includes('Путь загрузки: Изолированное прямое подключение'));
  compatibility.state.fetch_path='saved_server';
  await compatibility.polls[0]();
  assert.ok(text(compatibilityTree).includes('Путь загрузки: Сохранённый сервер подписки'));
  compatibility.state.compatibility.versions.podkop='<img src=x onerror=alert(1)>';
  await compatibility.polls[0]();
  assert.ok(text(compatibilityTree).includes('<img src=x onerror=alert(1)>'));
  assert.ok(!JSON.stringify(compatibilityTree).includes('innerHTML'));
  const settings=h.load('settings');settings.render(await settings.load());
  const url=h.options.find(o=>o.name==='subscription_url');assert.equal(url.password,true);assert.equal(url.cfgvalue(),'');await url.write('main','https://provider.invalid/sub?token=TEST');assert.deepEqual(h.requests.at(-1),{method:'source',args:['https://provider.invalid/sub?token=TEST']});assert.equal(url.validate('', 'https://provider.invalid/sub?token=PRIVATE'),true);assert.notEqual(url.validate('','http://provider.invalid/sub'),true);
  assert.ok(!text(tree).includes('subscription_url'));assert.ok(h.options.some(o=>o.name==='apply_policy'&&o.values.some(v=>v[0]==='manual')));
  console.log('PASS LuCI: batch request, independent results, token receipts, cancel, cap consent, short sample, permissions, stale metrics');
})().catch(e=>{console.error(e);process.exitCode=1;});
