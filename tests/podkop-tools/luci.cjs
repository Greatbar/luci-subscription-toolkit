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
  // Consent keeps the traffic cap; different servers have no fixed cooldown.
  v.tests={speed:true};h.requests.length=0;const speedTimes=[];h.hooks.time=(kind,clock)=>{if(kind==='speed')speedTimes.push(clock);};
  h.state.nodes.forEach(n=>n.test.speed_next_at=0);
  await button(tree,'Запустить проверку').attrs.click();assert.ok(text(h.modal.tree).includes('8 МиБ'));assert.ok(!text(h.modal.tree).includes('Интервал между ними'));
  await button(h.modal.tree,'Запустить').attrs.click();assert.equal(speedTimes.length,2);assert.equal(speedTimes[1]-speedTimes[0],500,'next distinct server starts after receipt, without the global 60-second delay');
  await v.runTests([h.state.nodes[1].id],['speed'],4194304);
  assert.equal(speedTimes.length,3);assert.ok(speedTimes[2]-speedTimes[1]>=60000,'repeat of the same server still waits');
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
  h.state.nodes.forEach(n=>n.test.speed_next_at=3000);h.requests.length=0;let reads=0;v.container.isConnected=true;
  h.hooks.request=(kind)=>{if(kind==='status'&&++reads===2)v.container.isConnected=false;};
  await button(tree,'Запустить проверку').attrs.click();await button(h.modal.tree,'Запустить').attrs.click();
  assert.ok(!h.requests.some(r=>r.method==='speed'),'detached view must abandon speed queue');
  h.hooks.request=null;v.container.isConnected=true;
  h.state.nodes[0].test.speed_stale=true;h.state.nodes[0].test.latency_stale=true;h.state.nodes[0].test.latency_at=1;
  await h.polls[0]();assert.ok(!text(tree).includes('4,5 Мбит/с'));assert.ok(text(tree).includes('Устарела'));
  h.state.busy=true;await h.polls[0]();assert.ok(walk(tree).filter(n=>n.tag==='button'&&text(n)!=='Обновить список').every(n=>n.disabled));
  const ro=env(false), rv=ro.load('dashboard'), rt=rv.render(await rv.load());assert.ok(walk(rt).filter(n=>n.tag==='button'&&text(n)!=='Обновить список').every(n=>n.disabled));
  // A cron task during speed cooldown pauses the queue instead of discarding it.
  const cron=env(), cv=cron.load('dashboard');cv.render(await cv.load());let cronReads=0;
  cron.state.nodes[0].test.speed_next_at=1060;
  cron.hooks.request=kind=>{if(kind==='status')cron.state.busy=++cronReads===2||cronReads===3;if(kind==='speed')assert.equal(cron.state.busy,false);};
  await cv.runTests(cron.state.nodes.map(n=>n.id),['speed'],4194304);
  assert.deepEqual(cron.requests.filter(r=>r.method==='speed').map(r=>r.args[0]),cron.state.nodes.map(n=>n.id),'cron must resume each speed probe exactly once');
  assert.equal(cv.progress.done,2);assert.equal(cv.running,false);assert.ok(!cron.requests.some(r=>['select','apply','fetch','seed'].includes(r.method)));
  // A completed diagnostic remains valid when cron obtains the next lock.
  const after=env(), av=after.load('dashboard');av.render(await av.load());let measured=0,busyReads=0;
  after.hooks.request=kind=>{if(kind==='latency'){assert.equal(after.state.busy,false);measured++;}if(kind==='status')after.state.busy=measured===1&&++busyReads<=100;};
  av.failures[after.state.nodes[0].id]={latency:'previous_failure'};
  await av.runTests(after.state.nodes.map(n=>n.id),['latency','service']);
  assert.equal(measured,2,'a following cron lock must not invalidate a completed receipt');
  assert.deepEqual(after.requests.filter(r=>['latency','service'].includes(r.method)).map(r=>[r.method,r.args[0]]),
    after.state.nodes.flatMap(n=>[['latency',n.id],['service',n.id]]),'resume remaining tests and servers without duplicate probes');
  assert.ok(busyReads>100,'wait for cron even beyond the diagnostic receipt deadline');
  assert.deepEqual(av.failures[after.state.nodes[0].id],{},'retain successful receipt and clear the previous failure');
  assert.equal(av.progress.done,2);assert.equal(av.progress.message,'Проверка завершена');
  assert.ok(!after.requests.some(r=>['select','apply','fetch','seed'].includes(r.method)));
  // Stop still abandons the queue while an unrelated task owns the lock.
  const stop=env(), sv=stop.load('dashboard');sv.render(await sv.load());let stopReads=0;
  stop.state.nodes[0].test.speed_next_at=1060;
  stop.hooks.request=kind=>{if(kind==='status'){
    if(++stopReads===2)stop.state.busy=true;
    if(stopReads===3){assert.equal(sv.progress.message,'Ожидание текущего задания');sv.stopTests();}
  }};
  await sv.runTests(stop.state.nodes.map(n=>n.id),['speed'],4194304);
  assert.ok(!stop.requests.some(r=>r.method==='speed'));assert.equal(sv.running,false);assert.equal(sv.progress.done,0);
  assert.ok(sv.progress.message.startsWith('Проверка остановлена'));
  const settings=h.load('settings');settings.render(await settings.load());
  const url=h.options.find(o=>o.name==='subscription_url');assert.equal(url.password,true);assert.equal(url.cfgvalue(),'');await url.write('main','https://provider.invalid/sub?token=TEST');assert.deepEqual(h.requests.at(-1),{method:'source',args:['https://provider.invalid/sub?token=TEST']});assert.equal(url.validate('', 'https://provider.invalid/sub?token=PRIVATE'),true);assert.notEqual(url.validate('','http://provider.invalid/sub'),true);
  assert.ok(!text(tree).includes('subscription_url'));assert.ok(h.options.some(o=>o.name==='apply_policy'&&o.values.some(v=>v[0]==='manual')));
  console.log('PASS shipped LuCI views: rendering, errors, permissions, polling, apply confirmation, per-node RPC, masked URL; cron wait, receipt preservation, continuation, cancellation, no duplicate probes');
})().catch(e=>{console.error(e);process.exitCode=1;});
