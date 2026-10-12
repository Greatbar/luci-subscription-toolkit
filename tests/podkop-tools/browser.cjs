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
 const methods=[],errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{if(!r.url().includes('/ubus'))return;try{const data=r.postDataJSON();for(const item of (Array.isArray(data)?data:[data]))if(item.params?.[1]==='podkop-tools')methods.push(item.params[2]);}catch(_){}});
 const base=process.env.TOOLKIT_LAB_URL;
 assert.ok(/^http:\/\/127\.0\.0\.1:\d+$/.test(base),'isolated Docker fixture only');
 await page.goto(base+'/cgi-bin/luci/admin/services/podkop_tools/dashboard');
 await page.locator('[name=luci_username]').fill('root');
 await page.locator('[name=luci_password]').fill('PodkopLabOnly123');
 await page.locator('button.cbi-button-positive').click();
 await page.getByRole('heading',{name:'Серверы и подписка',exact:true}).waitFor();
 errors.length=0;
 const read=()=>page.evaluate(async()=>{const rpc=await L.require('rpc');return rpc.declare({object:'podkop-tools',method:'status',expect:{}})();});
 const baseline=await read();assert.equal(baseline.nodes.length,11);assert.equal(baseline.nodes.find(n=>n.selected).name,'Латвия');
 assert.equal(await page.locator('.stk-table tr').count(),12);
 assert.equal(await page.getByRole('columnheader').count(),7);
 assert.equal(await page.getByRole('checkbox',{name:'Задержка',exact:true}).isChecked(),true);
 assert.equal(await page.getByRole('checkbox',{name:'Доступность сервиса',exact:true}).isChecked(),true);
 assert.equal(await page.getByRole('checkbox',{name:'Скорость',exact:true}).isChecked(),false);
 assert.equal(await page.getByRole('button',{name:'Применить изменения',exact:true}).count(),0);
 assert.ok(!(await page.locator('body').innerText()).includes('MTProto'));
 assert.ok(!(await page.locator('body').innerText()).includes('PRIVATE_LAB_SUBSCRIPTION_TOKEN'));
 const dir='test-results';fs.mkdirSync(dir,{recursive:true});
 await page.screenshot({path:dir+'/servers-desktop.png',fullPage:true});
 await page.evaluate(()=>document.documentElement.setAttribute('data-darkmode','true'));
 await page.screenshot({path:dir+'/servers-dark.png',fullPage:true});
 await page.evaluate(()=>document.documentElement.removeAttribute('data-darkmode'));
 await page.setViewportSize({width:390,height:844});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,'controls must fit mobile width');
 assert.equal(await page.locator('.stk-table').evaluate(el=>el.scrollWidth>el.clientWidth),true,'table scrolls on mobile');
 assert.equal(await page.getByRole('columnheader',{name:'Сервис',exact:true}).isVisible(),true);
 assert.equal(await page.locator('.stk-table tr').nth(1).evaluate(el=>getComputedStyle(el).display),'table-row');
 await page.screenshot({path:dir+'/servers-mobile.png',fullPage:true});
 await page.locator('.stk-section').first().locator('summary').click();
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,'page details fit mobile width');
 await page.locator('.stk-section').first().locator('summary').click();
 await page.locator('.stk-table').evaluate(el=>{el.scrollLeft=el.scrollWidth;});
 await page.screenshot({path:dir+'/servers-mobile-actions.png',fullPage:true});
 assert.equal(await page.locator('.stk-table tr').nth(1).evaluate(el=>{const buttons=el.querySelectorAll('.cbi-button');return buttons[0].getBoundingClientRect().right<=buttons[1].getBoundingClientRect().left;}),true,'mobile actions overlap');
 await page.locator('.stk-table').evaluate(el=>{el.scrollLeft=0;});
 await page.setViewportSize({width:1440,height:1000});
 // Real per-row backend probes: no external fixture endpoint survives baseline setup.
 await page.getByRole('button',{name:'Тест',exact:true}).first().click();
 await page.getByRole('status').filter({hasText:'Проверка завершена'}).waitFor({timeout:60000});
 assert.ok(methods.includes('latency')&&methods.includes('service'));
 let actual=await read();assert.equal(actual.selected_id,baseline.selected_id);
 assert.ok(actual.nodes[0].test.latency_at);assert.ok(actual.nodes[0].test.service.at);
 assert.equal(actual.nodes[0].test.latency_stale,false);assert.equal(actual.nodes[0].test.service.stale,false);
 assert.ok(!methods.some(m=>['select','apply','seed'].includes(m)));
 console.log('PASS real RPC: latency/service, cleanup, unchanged Selector');
 // Controlled public-status responses exercise queue edge cases without 44 MiB of network traffic.
 const fixture=structuredClone(actual);fixture.busy=false;fixture.last_success=1700000000;
 let failId=fixture.nodes[0].id,delay=0,cronAfterSpeed=false;
 const probes=[];
 await page.route('**/ubus/**',async route=>{
   const input=route.request().postDataJSON();const batch=Array.isArray(input)?input:[input];
   if(!batch.every(item=>item.params?.[1]==='podkop-tools'))return route.continue();
   const replies=[];
   for(const item of batch){const kind=item.params[2],params=item.params[3]||{};
     if(kind==='status')replies.push({jsonrpc:'2.0',id:item.id,result:[0,structuredClone(fixture)]});
     else if(['latency','service','speed'].includes(kind)){
       assert.equal(fixture.busy,false,'no overlapping jobs');fixture.busy=true;probes.push({kind,id:params.id,at:Date.now()});
       setTimeout(()=>{const n=fixture.nodes.find(n=>n.id===params.id);const at=Math.floor(Date.now()/1000);
         if(kind==='latency'){n.test.latency=154;n.test.latency_at=at;n.test.latency_stale=false;}
         if(kind==='service')n.test.service={at,ok:params.id!==failId,error:params.id===failId?'service_tls_failed':null,stale:false};
         if(kind==='speed'){n.test.mbps=60.5;n.test.at=at;n.test.speed_stale=false;n.test.speed_next_at=at+60;}
         fixture.measurement={sequence:(fixture.measurement?.sequence||0)+1,id:params.id,kind,ok:params.id!==failId,error:params.id===failId?'router_busy':null};fixture.busy=false;
         if(kind==='speed'&&cronAfterSpeed){cronAfterSpeed=false;fixture.busy=true;setTimeout(()=>{fixture.busy=false;},2000);}
       },delay);
       replies.push({jsonrpc:'2.0',id:item.id,result:[0,{ok:true,queued:true}]});
     } else {assert.equal(kind,'fetch');replies.push({jsonrpc:'2.0',id:item.id,result:[0,{ok:true,queued:true}]});}
   }
   await route.fulfill({contentType:'application/json',body:JSON.stringify(Array.isArray(input)?replies:replies[0])});
 });
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверено 11 из 11'}).waitFor({timeout:40000});
 assert.equal(probes.length,22);assert.equal(new Set(probes.map(p=>p.id)).size,11);
 assert.ok((await page.locator('.stk-table').innerText()).includes('Недоступен'));
 assert.ok(!(await page.locator('.stk-table').innerText()).includes('router_busy'));
 // Stop while a worker is alive: it completes; no next measurement is sent.
 delay=1800;const before=probes.length;
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.waitForFunction(()=>document.querySelector('[role=status]').textContent.includes('Задержка'));
 await page.getByRole('button',{name:'Остановить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверка остановлена'}).waitFor({timeout:10000});
 assert.equal(probes.length,before+1);assert.equal(fixture.busy,false);
 // Speed consent, sequential different IDs and cron after a completed receipt.
 delay=0;
 await page.getByRole('checkbox',{name:'Скорость',exact:true}).check();
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByText('Запустить проверку скорости?',{exact:true}).waitFor();
 assert.ok((await page.locator('#modal_overlay').innerText()).includes('44 МиБ'));
 const cancelBefore=probes.length;await page.getByRole('button',{name:'Отмена',exact:true}).click();assert.equal(probes.length,cancelBefore);
 await page.getByRole('checkbox',{name:'Задержка',exact:true}).uncheck();
 await page.getByRole('checkbox',{name:'Доступность сервиса',exact:true}).uncheck();
 failId=null;cronAfterSpeed=true;
 const speedBefore=probes.length;
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByRole('button',{name:'Запустить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Ожидание текущего задания'}).waitFor();
 assert.ok((await page.locator('.stk-table tr').nth(1).innerText()).includes('60,5 Мбит/с'),'finished speed result is visible while cron holds the next lock');
 await page.getByRole('status').filter({hasText:'Проверено 11 из 11'}).waitFor({timeout:20000});
 const speeds=probes.slice(speedBefore);assert.equal(speeds.length,11);assert.equal(new Set(speeds.map(p=>p.id)).size,11);
 assert.ok(speeds.every(p=>p.kind==='speed'));assert.ok(speeds.at(-1).at-speeds[0].at<20000,'no fixed 60-second wait between distinct servers');
 // Stop while waiting to retest the same server; no additional probe.
 fixture.nodes.forEach(n=>n.test.speed_next_at=Math.floor(Date.now()/1000)+60);
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 await page.getByRole('button',{name:'Запустить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Ожидание интервала скорости'}).waitFor();
 await page.getByRole('button',{name:'Остановить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверка остановлена'}).waitFor();assert.equal(probes.length,speedBefore+11);
 // Only active scope and a single menu test use the same queue.
 fixture.nodes.forEach(n=>n.test.speed_next_at=0);
 await page.getByRole('combobox',{name:'Область:'}).selectOption('active');
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 const activeBefore=probes.length;
 await page.getByRole('button',{name:'Запустить проверку',exact:true}).click();
 assert.ok((await page.locator('#modal_overlay').innerText()).includes('4 МиБ'));
 await page.getByRole('button',{name:'Запустить',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверено 1 из 1'}).waitFor();
 assert.equal(probes.length,activeBefore+1);assert.equal(probes.at(-1).id,baseline.selected_id);
 await page.locator('.stk-table tr').nth(1).getByText('Ещё',{exact:true}).click();
 await page.locator('.stk-table tr').nth(1).getByRole('button',{name:'Задержка',exact:true}).click();
 await page.getByRole('status').filter({hasText:'Проверка завершена'}).waitFor();assert.equal(probes.at(-1).kind,'latency');
 fixture.nodes[0].test={latency:154,latency_at:1700000000,latency_stale:true,mbps:60.5,at:1700000000,speed_stale:true,service:{at:1700000000,ok:true,stale:true}};
 await page.getByRole('button',{name:'Обновить список',exact:true}).click();
 const row=page.locator('.stk-table tr').nth(1);await row.getByText('Устарела',{exact:true}).first().waitFor();assert.ok((await row.innerText()).includes('Устарела'));assert.ok(!(await row.innerText()).includes('60,5'));
 await row.locator('summary').first().click();await page.waitForTimeout(3200);assert.equal(await row.locator('details').first().evaluate(el=>el.open),true,'poll preserves details');
 fixture.nodes=[];await page.getByRole('button',{name:'Обновить список',exact:true}).click();await page.getByText('Серверов пока нет. Прочитайте текущий MAIN в подробностях.',{exact:true}).waitFor();
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
 console.log('PASS Bootstrap desktop/mobile: 11 rows, batch/errors/stop, speed consent/cooldown, stale/empty, settings; no page errors');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
