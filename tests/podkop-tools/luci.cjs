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
  const state={speed_bytes:4194304,speed_next_at:0,count:2,pending:true,pending_version:'c'.repeat(64),nodes:[{id:'a'.repeat(64),name:'Швеция',selected:true,test:{mbps:4.5,bytes:1048576,seconds:2,at:1,latency:45}},
     {id:'b'.repeat(64),name:'<img src=x onerror=alert(1)>',test:{error:'speed_failed',at:1,service:{ok:false,error:'service_content_mismatch',at:2}}}]};
  const rpc={declare:spec=>async (...args)=>{requests.push({method:spec.method,args});if(hooks.time)hooks.time(spec.method,clock);if(hooks.request)hooks.request(spec.method,args);
    if(['latency','service','speed'].includes(spec.method)) {state.measurement={sequence:(state.measurement?.sequence||0)+1,id:args[0],kind:spec.method,ok:args[0]!==state.failId||!!state.failKind&&spec.method!==state.failKind,error:'router_busy'};if(spec.method==='speed')state.speed_next_at=clock/1000+60;}
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
  const speeds=walk(tree).filter(n=>n.tag==='button'&&text(n)==='Скорость');await speeds[1].attrs.click.call(speeds[1]);
  assert.ok(text(h.modal.tree).includes('4 МиБ'));await button(h.modal.tree,'Запустить').attrs.click();
  assert.deepEqual(h.requests.filter(r=>r.method==='speed').at(-1),{method:'speed',args:['b'.repeat(64)]});assert.ok(!h.requests.some(r=>r.method==='select'));
  assert.ok(text(tree).includes('service_content_mismatch'));
  const services=walk(tree).filter(n=>n.tag==='button'&&text(n)==='Доступность сервиса');await services[1].attrs.click.call(services[1]);
  assert.deepEqual(h.requests.filter(r=>r.method==='service').at(-1),{method:'service',args:['b'.repeat(64)]});assert.ok(!h.requests.some(r=>r.method==='select'));
  // One failed measurement must not skip remaining servers or tests.
  h.state.failId='a'.repeat(64);h.state.failKind='latency';h.requests.length=0;
  await button(tree,'Запустить проверку').attrs.click();
  assert.deepEqual(h.requests.filter(r=>['latency','service'].includes(r.method)).map(r=>r.method),['latency','service','latency','service']);
  assert.ok(text(tree).includes('Проверено 2 из 2'));assert.ok(text(tree).includes('router_busy'),'later successful service keeps the latency failure in details');
  assert.ok(!h.requests.some(r=>['select','apply','fetch','seed'].includes(r.method)));
  // Stop after first enqueued job: no second method or server is sent.
  h.requests.length=0;h.hooks.request=(kind)=>{if(kind==='latency')v.stopTests();};
  await button(tree,'Запустить проверку').attrs.click();
  assert.equal(h.requests.filter(r=>['latency','service'].includes(r.method)).length,1);
  assert.ok(text(tree).includes('Проверка остановлена'));h.hooks.request=null;
  // Consent uses the configured cap, and global cooldown is respected for both servers.
  v.tests={speed:true};h.requests.length=0;const speedTimes=[];h.hooks.time=(kind,clock)=>{if(kind==='speed')speedTimes.push(clock);};
  await button(tree,'Запустить проверку').attrs.click();assert.ok(text(h.modal.tree).includes('8 МиБ'));
  await button(h.modal.tree,'Запустить').attrs.click();assert.equal(speedTimes.length,2);assert.ok(speedTimes[1]-speedTimes[0]>=60000);
  assert.ok(!h.requests.some(r=>['select','apply','fetch','seed'].includes(r.method)));
  // The stated maximum must never round down a byte cap that is not a whole MiB.
  h.state.speed_bytes=5000000;await button(tree,'Запустить проверку').attrs.click();
  assert.ok(text(h.modal.tree).includes('До 9,6 МиБ'),'rounded traffic maximum must cover 10000000 bytes');
  await button(h.modal.tree,'Отмена').attrs.click();
  // Changed cap after consent never sends a speed request.
  h.requests.length=0;await button(tree,'Запустить проверку').attrs.click();h.state.speed_bytes=16777216;
  await button(h.modal.tree,'Запустить').attrs.click();assert.ok(!h.requests.some(r=>r.method==='speed'));
  assert.ok(text(tree).includes('Лимит трафика изменился'));
  // Navigating away during cooldown abandons the queue before the next RPC.
  h.state.speed_next_at=3000;h.requests.length=0;let reads=0;v.container.isConnected=true;
  h.hooks.request=(kind)=>{if(kind==='status'&&++reads===2)v.container.isConnected=false;};
  await button(tree,'Запустить проверку').attrs.click();await button(h.modal.tree,'Запустить').attrs.click();
  assert.ok(!h.requests.some(r=>r.method==='speed'),'detached view must abandon speed queue');
  h.hooks.request=null;v.container.isConnected=true;
  h.state.nodes[0].test.speed_stale=true;h.state.nodes[0].test.latency_stale=true;h.state.nodes[0].test.latency_at=1;
  await h.polls[0]();assert.ok(!text(tree).includes('4,5 Мбит/с'));assert.ok(text(tree).includes('Устарела'));
  h.state.busy=true;await h.polls[0]();assert.ok(walk(tree).filter(n=>n.tag==='button'&&text(n)!=='Обновить список').every(n=>n.disabled));
  const ro=env(false), rv=ro.load('dashboard'), rt=rv.render(await rv.load());assert.ok(walk(rt).filter(n=>n.tag==='button'&&text(n)!=='Обновить список').every(n=>n.disabled));
  const settings=h.load('settings');settings.render(await settings.load());
  const url=h.options.find(o=>o.name==='subscription_url');assert.equal(url.password,true);assert.equal(url.cfgvalue(),'');await url.write('main','https://provider.invalid/sub?token=TEST');assert.deepEqual(h.requests.at(-1),{method:'source',args:['https://provider.invalid/sub?token=TEST']});assert.equal(url.validate('', 'https://provider.invalid/sub?token=PRIVATE'),true);assert.notEqual(url.validate('','http://provider.invalid/sub'),true);
  assert.ok(!text(tree).includes('subscription_url'));assert.ok(h.options.some(o=>o.name==='apply_policy'&&o.values.some(v=>v[0]==='manual')));
  console.log('PASS shipped LuCI views: rendering, errors, permissions, polling, apply confirmation, per-node RPC, masked URL');
})().catch(e=>{console.error(e);process.exitCode=1;});
