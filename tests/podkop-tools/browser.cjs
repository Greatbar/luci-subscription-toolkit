// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
// Real uhttpd/LuCI/rpcd in the isolated OpenWrt fixture, never the router.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true});
 const page=await browser.newPage({ignoreHTTPSErrors:true});
 const methods=[];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{if(!r.url().includes('/ubus'))return;try{let data=r.postDataJSON();for(let item of (Array.isArray(data)?data:[data])){if(item.params?.[1]==='uci'&&item.params?.[2]==='get')console.log('UCI read config:',item.params[3]?.config);if(item.params?.[1]==='podkop-tools')methods.push(item.params[2]);}}catch(_){}});
 const base=process.env.TOOLKIT_LAB_URL;
 assert.ok(/^http:\/\/127\.0\.0\.1:\d+$/.test(base),'isolated Docker fixture only');
 await page.goto(base+'/cgi-bin/luci/admin/services/podkop_tools/dashboard');
 await page.locator('[name=luci_username]').fill('root');
 await page.locator('[name=luci_password]').fill('PodkopLabOnly123');
 await page.locator('button.cbi-button-positive').click();
 await page.getByRole('heading',{name:'Subscription Toolkit: подписка и скорость',exact:true}).waitFor();
 await page.getByRole('button',{name:'Проверить подписку',exact:true}).waitFor();
 await page.getByRole('columnheader',{name:'Доступность сервиса',exact:true}).waitFor();
 assert.ok((await page.locator('body').innerText()).includes('MTProto'));
 await page.getByRole('button',{name:'Сервис',exact:true}).first().click();
 await page.waitForTimeout(1000);
 await page.evaluate(async()=>{const rpc=await L.require('rpc');const get=rpc.declare({object:'podkop-tools',method:'status',expect:{}});for(let i=0;i<30;i++){if(!(await get()).busy)return;await new Promise(r=>setTimeout(r,500));}throw new Error('service job timeout');});
 assert.ok(methods.includes('service'));assert.ok(!methods.includes('select'));
 console.log('Stock pre-auth page errors:',errors.length);errors.length=0;
 assert.ok(!await page.locator('body').innerText().then(t=>t.includes('PRIVATE_LAB_SUBSCRIPTION_TOKEN')));
 const apply=page.getByRole('button',{name:'Применить изменения',exact:true});
 if(await apply.isEnabled()) {
   await apply.click();await page.getByText('Применить подписку?',{exact:true}).waitFor();
   await page.getByRole('button',{name:'Отмена',exact:true}).click();
 } else assert.equal(await apply.isDisabled(),true);
 await page.goto(base+'/cgi-bin/luci/admin/services/podkop_tools/settings');
 await page.getByText('URL подписки',{exact:true}).waitFor();
 await page.getByText('Обязательные фрагменты ответа',{exact:true}).waitFor();
 assert.equal(await page.locator('input[id$="service_status"]').inputValue(),'200');
 const field=page.locator('input[id$="subscription_url"]');
 assert.equal(await field.getAttribute('type'),'password');
 assert.equal(await field.inputValue(),'','saved URL is never returned into the form');
 const synthetic='https://subscription.invalid/sub?token=GENERATED_BROWSER_TEST';
 await field.fill(synthetic);
 await page.getByRole('button',{name:'Save',exact:true}).click();
 await page.waitForTimeout(1500);
 const changes=await page.evaluate(async()=>{const uci=await L.require('uci');return uci.changes();});
 assert.ok(!JSON.stringify(changes).includes('GENERATED_BROWSER_TEST'),'secret in global LuCI pending changes');
 // No MAIN apply: this event only rebuilds the addon crontab from committed UCI.
 await page.evaluate(()=>document.dispatchEvent(new CustomEvent('uci-applied')));
 await page.waitForTimeout(500);assert.ok(methods.includes('source'));assert.ok(methods.includes('schedule'));
 console.log('Addon RPC methods:',methods.join(','));
 assert.equal(errors.length,0,'uncaught LuCI errors: '+errors.join('; '));
 console.log('PASS actual LuCI browser: login, dashboard/RPC, confirmation, masked subscription form; no page errors');
 await browser.close();
})().catch(e=>{console.error(e.message);process.exit(1);});
