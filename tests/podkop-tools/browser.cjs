// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
// Stock Bootstrap in disposable OpenWrt. Real RPC first, controlled edge cases after.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try {
 const page=await browser.newPage({ignoreHTTPSErrors:true,viewport:{width:1440,height:1000}});
 const methods=[],batchTokens=[],errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{
   if(!r.url().includes('/ubus'))return;
   try {
     const data=r.postDataJSON();
     for(const item of (Array.isArray(data)?data:[data])) {
       if(item.params?.[1]!=='podkop-tools')continue;
       methods.push(item.params[2]);
       if(item.params[2]==='batch')batchTokens.push(item.params[3].token);
     }
   } catch(_) {}
 });
 const base=process.env.TOOLKIT_LAB_URL;
 assert.ok(/^http:\/\/127\.0\.0\.1:\d+$/.test(base),'isolated Docker fixture only');
 await page.goto(base+'/cgi-bin/luci/admin/services/podkop_tools/dashboard');
 await page.locator('[name=luci_username]').fill('root');
 await page.locator('[name=luci_password]').fill('PodkopLabOnly123');
 await page.locator('button.cbi-button-positive').click();
 await page.getByRole('heading',{name:'Серверы и подписка',exact:true}).waitFor();
 errors.length=0;
 const read=(token='')=>page.evaluate(async token=>{const rpc=await L.require('rpc');return rpc.declare({object:'podkop-tools',method:'status',params:['token'],expect:{}})(token);},token);
 const baseline=await read();assert.equal(baseline.nodes.length,11);assert.equal(baseline.nodes.find(n=>n.selected).name,'Латвия');
 const cards=page.locator('.stk-server'), firstCard=cards.first();
 assert.equal(await cards.count(),11);
 assert.equal(await page.locator('.stk-server-active').count(),1);
 assert.equal(await page.locator('.stk-server-active > h4').innerText(),baseline.nodes.find(n=>n.selected).name);
 assert.equal(await cards.nth(1).evaluate(el=>el.offsetTop),await firstCard.evaluate(el=>el.offsetTop),'desktop shows several cards per row');
 await page.getByText('Параметры проверки',{exact:true}).click();
 assert.equal(await page.getByRole('checkbox',{name:'Задержка',exact:true}).isChecked(),true);
 assert.equal(await page.getByRole('checkbox',{name:'Telegram Web',exact:true}).isChecked(),true);
 assert.equal(await page.getByRole('checkbox',{name:'Скорость',exact:true}).isChecked(),false);
 assert.equal(await page.getByRole('button',{name:'Применить изменения',exact:true}).count(),0);
 assert.ok(!(await page.locator('body').innerText()).includes('MTProto'));
 assert.ok(!(await page.locator('body').innerText()).includes('PRIVATE_LAB_SUBSCRIPTION_TOKEN'));
 const dir='test-results';fs.mkdirSync(dir,{recursive:true});
 await page.getByText('Параметры проверки',{exact:true}).click();
 await page.screenshot({path:dir+'/servers-desktop.png',fullPage:true});
 await page.evaluate(()=>document.documentElement.setAttribute('data-darkmode','true'));
 await page.screenshot({path:dir+'/servers-dark.png',fullPage:true});
 await page.evaluate(()=>document.documentElement.removeAttribute('data-darkmode'));
 await page.setViewportSize({width:390,height:844});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,'controls must fit mobile width');
 assert.ok(await cards.nth(1).evaluate(el=>el.offsetTop)>await firstCard.evaluate(el=>el.offsetTop),'mobile stacks cards');
 assert.equal(await firstCard.locator('dt').filter({hasText:'Telegram Web'}).isVisible(),true);
 await page.screenshot({path:dir+'/servers-mobile.png',fullPage:true});
 await page.getByText('Подписка и маршрутизация',{exact:true}).click();
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,'page details fit mobile width');
 await page.getByText('Подписка и маршрутизация',{exact:true}).click();
 await firstCard.scrollIntoViewIfNeeded();
 await page.screenshot({path:dir+'/servers-mobile-actions.png',fullPage:true});
 assert.equal(await firstCard.evaluate(el=>{
   const [first,second]=Array.from(el.querySelectorAll('.stk-server-actions .cbi-button'),button=>button.getBoundingClientRect());
   return first.right<=second.left || first.bottom<=second.top;
 }),true,'mobile actions overlap');
 await page.setViewportSize({width:1440,height:1000});
 // Real single-server probes: no fixture endpoint survives baseline setup.
 await firstCard.getByRole('button',{name:'Проверить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверка завершена'}).waitFor({timeout:60000});
 assert.ok(methods.includes('batch'));
 let actual=await read();assert.equal(actual.selected_id,baseline.selected_id);
 assert.ok(actual.nodes[0].test.latency_at);assert.ok(actual.nodes[0].test.service.at);
 assert.equal(actual.nodes[0].test.latency_stale,false);assert.equal(actual.nodes[0].test.service.stale,false);
 assert.ok(!methods.some(m=>['select','apply','seed'].includes(m)));
 console.log('PASS real RPC: latency/service, cleanup, unchanged Selector');
 const start=Date.now(), quick=page.getByRole('button',{name:'Проверить задержку всех серверов',exact:true});
 await quick.click();
 await page.getByRole('status').filter({hasText:'Проверено 11 из 11. Проверка завершена'}).waitFor({timeout:60000});
 assert.equal(batchTokens.length,2);
 actual=await read(batchTokens.at(-1));
 assert.equal(actual.selected_id,baseline.selected_id);
 assert.deepEqual(Object.keys(actual.batch.latency).sort(),baseline.nodes.map(n=>n.id).sort());
 // The baseline driver has shut down its HTTPS endpoint and VLESS listeners.
 assert.ok(Object.values(actual.batch.latency).every(value=>value===null));
 assert.equal(await page.locator('.stk-server > .stk-metrics').getByText('Замер не удался',{exact:true}).count(),11);
 assert.equal(await page.locator('.stk-progress progress').evaluate(el=>el.value),11);
 console.log('PASS real RPC: latency shortcut and results for all 11 servers in '+(Date.now()-start)+' ms');
 // Controlled batch receipts exercise UI behavior without extra speed traffic.
 const fixture=structuredClone(actual);fixture.busy=false;fixture.last_success=1700000000;
 fixture.fetch_stage_error='generated_nodes_mismatch';fixture.downloaded_count=9;
 fixture.fetch_path='direct';fixture.control={ok:true,at:1700000000,failures:0};
 fixture.compatibility.warnings=['untested_versions'];
 fixture.compatibility.versions={openwrt:'25.12.5',podkop:'0.7.24',sing_box:'1.14.4'};
 let failId=fixture.nodes[0].id,delay=0;
 const batches=[];
 await page.route('**/ubus/**',async route=>{
   const input=route.request().postDataJSON(),items=Array.isArray(input)?input:[input];
   if(!items.every(item=>item.params?.[1]==='podkop-tools'))return route.continue();
   const replies=[];
   for(const item of items){const kind=item.params[2],params=item.params[3]||{};
     if(kind==='status') {
       const snapshot=structuredClone(fixture);
       if(params.token&&snapshot.batch?.token!==params.token)snapshot.batch=null;
       replies.push({jsonrpc:'2.0',id:item.id,result:[0,snapshot]});
     } else if(kind==='batch') {
       assert.equal(fixture.busy,false);fixture.busy=true;batches.push(params);
       const receipt={token:params.token,state:'running',done:0,total:params.ids.length,errors:{}};fixture.batch=receipt;
       if(params.kinds.includes('latency'))receipt.latency={};
       setTimeout(()=>{
         if(receipt.state!=='running')return;
         const at=Math.floor(Date.now()/1000);
         for(const id of params.ids){const n=fixture.nodes.find(n=>n.id===id);
           for(const metric of params.kinds){
             if(metric==='latency'){n.test.latency=154;n.test.latency_at=at;n.test.latency_stale=false;receipt.latency[id]=154;}
             if(metric==='service')n.test.service={at,ok:id!==failId,error:id===failId?'service_tls_failed':null,stale:false};
             if(metric==='speed'){
               if(n.test.speed_next_at>at){receipt.errors[id]={speed:'speed_cooldown'};continue;}
               Object.assign(n.test,{mbps:60.5,at,speed_stale:false,speed_next_at:at+60,short_sample:true});
             }
           }
         }
         receipt.done=params.ids.length;receipt.state='finished';fixture.busy=false;
       },delay);
       replies.push({jsonrpc:'2.0',id:item.id,result:[0,{ok:true,queued:true}]});
     } else if(kind==='statistics') {
       const hour=Math.floor(Date.now()/3600000)*3600;
       replies.push({jsonrpc:'2.0',id:item.id,result:[0,{id:params.id,period:params.period,rows:[
         {hour:hour-7200,attempts:4,successes:3,delay_sum:300,delay_count:3,delay_min:80,delay_max:120,failures:1,switches:0},
         {hour,attempts:2,successes:2,delay_sum:160,delay_count:2,delay_min:70,delay_max:90,failures:0,switches:1}
       ],truncated:false}]});
     } else if(kind==='cancel') {
       assert.equal(params.token,fixture.batch.token);fixture.batch.state='cancelled';fixture.busy=false;
       replies.push({jsonrpc:'2.0',id:item.id,result:[0,{ok:true}]});
     } else {assert.equal(kind,'fetch');replies.push({jsonrpc:'2.0',id:item.id,result:[0,{ok:true,queued:true}]});}
   }
   await route.fulfill({contentType:'application/json',body:JSON.stringify(Array.isArray(input)?replies:replies[0])});
 });
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 const notice=page.locator('.stk-notice');
 await notice.getByText('Генератор изменил список серверов',{exact:true}).waitFor();
 assert.ok((await notice.innerText()).includes('Скачано серверов: 9'));
 const routing=page.getByText('Подписка и маршрутизация',{exact:true});
 const compatibility=page.getByText('Совместимость',{exact:true});
 await routing.click();
 await compatibility.click();
 const controlCard=page.locator('.stk-diagnostic-grid .stk-card')
   .filter({has:page.getByRole('heading',{name:'Контроль HTTPS',exact:true})});
 await controlCard.getByRole('heading',{name:'Контроль HTTPS',exact:true}).waitFor();
 await page.getByRole('heading',{name:'Проверка операций',exact:true}).waitFor();
 assert.equal(await page.getByText('Код состояния',{exact:true}).isVisible(),false);
 await controlCard.getByText('0',{exact:true}).waitFor();
 fixture.compatibility.versions.podkop='0.7.24 <b>тест</b>';
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 await page.getByText('0.7.24 <b>тест</b>',{exact:true}).waitFor();
 assert.equal(await page.locator('.stk-detail-fields dd b').count(),0);
 fixture.compatibility.versions.podkop='0.7.24';
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 await page.getByText('0.7.24',{exact:true}).waitFor();
 await page.setViewportSize({width:997,height:900});
 await page.evaluate(()=>document.documentElement.setAttribute('data-darkmode','true'));
 await page.screenshot({path:dir+'/diagnostics-dark.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'expanded diagnostics fit mobile');
 await page.screenshot({path:dir+'/diagnostics-mobile.png',fullPage:true});
 await page.evaluate(()=>document.documentElement.removeAttribute('data-darkmode'));
 await routing.click();
 await compatibility.click();
 await page.setViewportSize({width:1440,height:1000});
 await page.getByText('Статистика HTTPS',{exact:true}).click();
 await page.locator('.stk-dashboard svg[role=img]').first().waitFor();
 assert.equal(await page.locator('.stk-dashboard svg[role=img]').count(),3,'native SVG charts');
 await page.setViewportSize({width:390,height:844});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,'statistics charts fit mobile');
 await page.screenshot({path:dir+'/statistics-mobile.png',fullPage:true});
 await page.setViewportSize({width:1440,height:1000});
 await page.getByText('Статистика HTTPS',{exact:true}).click();
 console.log('PASS lazy statistics SVG graphs and mobile gaps');
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 await page.getByText('Параметры проверки',{exact:true}).click();
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверено 11 из 11'}).waitFor({timeout:10000});
 assert.equal(batches.length,1);assert.equal(batches[0].ids.length,11);assert.deepEqual(batches[0].kinds,['latency','service']);
 assert.equal(await page.locator('.stk-latency-medium').filter({hasText:'154 мс'}).count(),11);
 assert.ok((await page.locator('.stk-servers').innerText()).includes('Недоступен'));
 delay=5000;
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByRole('button',{name:'Остановить',exact:true}).waitFor();
 await page.getByRole('button',{name:'Остановить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверка остановлена'}).waitFor({timeout:10000});
 assert.equal(batches.length,2);assert.equal(fixture.busy,false);
 delay=0;failId=null;
 await page.getByRole('checkbox',{name:'Скорость',exact:true}).check();
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 assert.ok((await page.locator('#modal_overlay').innerText()).includes('44 МиБ'));
 await page.getByRole('button',{name:'Отмена',exact:true}).click();assert.equal(batches.length,2);
 await page.getByRole('checkbox',{name:'Задержка',exact:true}).uncheck();
 await page.getByRole('checkbox',{name:'Telegram Web',exact:true}).uncheck();
 fixture.nodes.forEach(n=>n.test.speed_next_at=0);
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByRole('button',{name:'Запустить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверено 11 из 11'}).waitFor({timeout:10000});
 assert.equal(batches.length,3);assert.deepEqual(batches.at(-1).kinds,['speed']);
 assert.ok((await page.locator('.stk-servers').innerText()).includes('60,5 Мбит/с'));
 assert.ok((await page.locator('.stk-servers').innerText()).includes('короткая выборка'));
 // Repeats return a cooldown receipt instead of sleeping in the browser.
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByRole('button',{name:'Запустить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверено 11 из 11'}).waitFor({timeout:10000});
 assert.equal(Object.keys(fixture.batch.errors).length,11);
 fixture.nodes.forEach(n=>n.test.speed_next_at=0);
 await page.getByRole('combobox',{name:'Область:'}).selectOption('active');
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 assert.ok((await page.locator('#modal_overlay').innerText()).includes('4 МиБ'));
 await page.getByRole('button',{name:'Запустить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверено 1 из 1'}).waitFor({timeout:10000});
 assert.deepEqual(batches.at(-1).ids,[baseline.selected_id]);
 await firstCard.getByText('Отдельные проверки',{exact:true}).click();
 await firstCard.getByRole('button',{name:'Задержка',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверка завершена'}).waitFor({timeout:10000});
 assert.deepEqual(batches.at(-1).kinds,['latency']);
 fixture.nodes[0].test={latency:154,latency_at:1700000000,latency_stale:true,mbps:60.5,at:1700000000,speed_stale:true,service:{at:1700000000,ok:true,stale:true}};
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 await firstCard.getByText('Устарела',{exact:true}).first().waitFor();assert.ok((await firstCard.innerText()).includes('Устарела'));assert.ok(!(await firstCard.innerText()).includes('60,5'));
 await firstCard.getByText('Подробности',{exact:true}).click();
 await firstCard.getByText('Прежняя проверка',{exact:true}).waitFor();
 await firstCard.getByText('Между замерами нужна пауза в минуту',{exact:true}).waitFor();
 await page.waitForTimeout(3200);
 assert.equal(await firstCard.locator('details').first().evaluate(el=>el.open),true,'poll preserves details');
 await page.setViewportSize({width:390,height:844});
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'server panels fit mobile');
 await firstCard.screenshot({path:dir+'/server-details-mobile.png'});
 await page.setViewportSize({width:1440,height:1000});
 fixture.nodes=[];await page.getByRole('button',{name:'Обновить список',exact:true}).click();await page.getByText('Серверов пока нет. В разделе «Подписка и маршрутизация» нажмите «Прочитать текущий MAIN».',{exact:true}).waitFor();
 assert.equal(await page.getByRole('button',{name:'Запустить проверку',exact:true}).isDisabled(),true);
 await page.unroute('**/ubus/**');
 // All existing settings, masked source and schedule handler remain functional.
 await page.goto(base+'/cgi-bin/luci/admin/services/podkop_tools/settings');
 await page.getByText('URL подписки',{exact:true}).waitFor();
 await page.getByText('Обязательные фрагменты ответа',{exact:true}).waitFor();
 assert.equal(await page.locator('input[id$="service_status"]').inputValue(),'200');
 const field=page.locator('input[id$="subscription_url"]');assert.equal(await field.getAttribute('type'),'password');assert.equal(await field.inputValue(),'');
 await field.fill('https://subscription.invalid/sub?token=GENERATED_BROWSER_TEST');
 await page.getByRole('button',{name:'Save',exact:true}).click();await page.waitForTimeout(1500);
 const changes=await page.evaluate(async()=>{const uci=await L.require('uci');return uci.changes();});assert.ok(!JSON.stringify(changes).includes('GENERATED_BROWSER_TEST'));
 await page.evaluate(()=>document.dispatchEvent(new CustomEvent('uci-applied')));await page.waitForTimeout(500);
 assert.ok(methods.includes('source')&&methods.includes('schedule'));
 assert.equal(errors.length,0,'uncaught errors: '+errors.join('; '));
 assert.ok(!methods.includes('apply')&&!methods.includes('select'));
 console.log('PASS Bootstrap desktop/mobile: 11 cards, batch/errors/stop, speed consent/cooldown, stale/empty, settings; no page errors');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
