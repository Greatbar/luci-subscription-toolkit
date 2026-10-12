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
  const requests=[], polls=[], modal={}, options=[];
  const state={count:2,pending:true,pending_version:'c'.repeat(64),nodes:[{id:'a'.repeat(64),name:'Швеция',selected:true,test:{mbps:4.5,bytes:1048576,seconds:2,at:1,latency:45}},
     {id:'b'.repeat(64),name:'<img src=x onerror=alert(1)>',test:{error:'speed_failed',at:1,service:{ok:false,error:'service_content_mismatch',at:2}}}]};
  const rpc={declare:spec=>async (...args)=>{requests.push({method:spec.method,args});return spec.method==='status'?state:{ok:true,queued:true};}};
  const form={NamedSection:0,Flag:1,Value:2,ListValue:3,DynamicList:4,
    Map:class {section(){return {option(type,name){const o={name,type,values:[],value(k,v){this.values.push([k,v]);},depends(){}};options.push(o);return o;}};} render(){return E('form');}}};
  const args={E,view:{extend:x=>x},dom:{content:(n,c)=>{n.children=[c];}},rpc,poll:{add:f=>polls.push(f)},
    ui:{showModal:(title,children)=>{modal.tree=E('div',{},children);},hideModal:()=>{modal.tree=null;},addNotification(){ }},
    L:{hasViewPermission:()=>write},document:{addEventListener(){}},form};
  function load(name){return new Function(...Object.keys(args),fs.readFileSync(path.join(root,name+'.js'),'utf8'))(...Object.values(args));}
  return {requests,polls,modal,options,state,load};
}
(async()=>{
  const h=env(), v=h.load('dashboard'), tree=v.render(await v.load());
  assert.ok(walk(tree).filter(n=>n.tag==='button'&&!n.disabled).every(n=>n.attrs.disabled==null));
  assert.ok(text(tree).includes('4.50 Мбит/с')); assert.ok(text(tree).includes('Швеция'));assert.ok(text(tree).includes('speed_failed'));
  assert.ok(text(tree).includes('<img src=x onerror=alert(1)>'));assert.ok(!JSON.stringify(tree).includes('innerHTML'));
  await button(tree,'Проверить подписку').attrs.click();assert.equal(h.requests.at(-1).method,'fetch');
  await button(tree,'Применить изменения').attrs.click();assert.ok(h.modal.tree);assert.ok(!h.requests.some(r=>r.method==='apply'));
  h.state.pending_version='d'.repeat(64);await h.polls[0]();
  await button(h.modal.tree,'Применить').attrs.click();assert.equal(h.requests.at(-1).method,'apply');
  assert.deepEqual(h.requests.at(-1).args,['c'.repeat(64)],'confirmation stays bound to the version shown before a poll');
  const speeds=walk(tree).filter(n=>n.tag==='button'&&text(n)==='Скорость');await speeds[1].attrs.click.call(speeds[1]);
  assert.deepEqual(h.requests.at(-1),{method:'speed',args:['b'.repeat(64)]});assert.ok(!h.requests.some(r=>r.method==='select'));
  assert.ok(text(tree).includes('service_content_mismatch'));
  const services=walk(tree).filter(n=>n.tag==='button'&&text(n)==='Сервис');await services[1].attrs.click.call(services[1]);
  assert.deepEqual(h.requests.at(-1),{method:'service',args:['b'.repeat(64)]});assert.ok(!h.requests.some(r=>r.method==='select'));
  h.state.busy=true;await h.polls[0]();assert.ok(walk(tree).filter(n=>n.tag==='button').every(n=>n.disabled));
  const ro=env(false), rv=ro.load('dashboard'), rt=rv.render(await rv.load());assert.ok(walk(rt).filter(n=>n.tag==='button').every(n=>n.disabled));
  const settings=h.load('settings');settings.render(await settings.load());
  const url=h.options.find(o=>o.name==='subscription_url');assert.equal(url.password,true);assert.equal(url.cfgvalue(),'');await url.write('main','https://provider.invalid/sub?token=TEST');assert.deepEqual(h.requests.at(-1),{method:'source',args:['https://provider.invalid/sub?token=TEST']});assert.equal(url.validate('', 'https://provider.invalid/sub?token=PRIVATE'),true);assert.notEqual(url.validate('','http://provider.invalid/sub'),true);
  assert.ok(!text(tree).includes('subscription_url'));assert.ok(h.options.some(o=>o.name==='apply_policy'&&o.values.some(v=>v[0]==='manual')));
  console.log('PASS shipped LuCI views: rendering, errors, permissions, polling, apply confirmation, per-node RPC, masked URL');
})().catch(e=>{console.error(e);process.exitCode=1;});
