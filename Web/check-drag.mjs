// Created by Василий Маслов on 06.10.2026.
import assert from 'node:assert/strict';
import {panelCommand} from './check-chrome-helpers.mjs';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
const url=`http://127.0.0.1:${server.address().port}/?preview=1`,errors=[];
try{
 const page=await browser.newPage({viewport:{width:520,height:1050}});page.on('pageerror',e=>errors.push(e.message));
 const block=kind=>page.locator(`.panel-block[data-block="${kind}"]`),title=kind=>block(kind).locator('.block-title'),grid=page.locator('.panel-grid');
 const revision=()=>grid.getAttribute('data-layout-revision');
 const positions=()=>page.locator('.panel-block:not([hidden])').evaluateAll(nodes=>nodes.map(n=>[n.dataset.block,n.style.gridRow,n.style.gridColumn]));
 async function load(query=''){await page.goto(url+query);await title('bootstrap').waitFor();await page.waitForTimeout(250);}
 async function hold(kind){const box=await title(kind).boundingBox(),point={x:box.x+Math.min(40,box.width/2),y:box.y+12};await page.mouse.move(point.x,point.y);await page.mouse.down();await page.waitForTimeout(540);assert.equal(await page.locator('[data-drag-active]').count(),1);return point;}
 async function reorder(source='utils',destination='simulators'){const box=await block(destination).boundingBox();await hold(source);await page.mouse.move(box.x+box.width/2,box.y+box.height/2,{steps:8});await page.mouse.up();await page.waitForTimeout(260);}
 await load();
 for(const width of [360,440,480,520])for(const scheme of ['light','dark']){
  await page.setViewportSize({width,height:1050});await page.emulateMedia({colorScheme:scheme,reducedMotion:'reduce'});await page.waitForFunction(()=>{const node=document.querySelector('.panel-block[data-block="utils"]');return node&&node.style.gridColumn===(matchMedia('(max-width:479px)').matches?'1 / -1':'1');});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`no overflow ${width} ${scheme}`);
  const a=await block('utils').boundingBox(),b=await block('builds').boundingBox();
  if(width<480){assert(Math.abs(a.x-b.x)<1,JSON.stringify({width,scheme,a,b,styles:await positions()}));assert(b.y>a.y,'mini pair stacks without persisting a different layout');}
  else{assert(Math.abs(a.y-b.y)<1);if(width===520)assert(Math.abs(a.width-238)<1);}
  await title('builds').click();assert(await block('utils').evaluate(n=>n.hidden&&n.inert));await title('builds').click();
 }
 await page.setViewportSize({width:520,height:1050});await page.emulateMedia({colorScheme:'light',reducedMotion:'no-preference'});
 await block('utils').evaluate(node=>window.dragCardIdentity=node);
 const before=await positions(),originalRevision=await revision();
 const destination=await block('simulators').boundingBox(),press=await hold('utils');
 assert(await block('utils').evaluate(n=>n===window.dragCardIdentity));
 const captured=await block('utils').boundingBox();
 await page.mouse.move(destination.x+destination.width/2,destination.y+destination.height/2);
 const moved=await block('utils').boundingBox();assert(Math.abs(moved.x-captured.x-(destination.x+destination.width/2-press.x))<2);assert(Math.abs(moved.y-captured.y-(destination.y+destination.height/2-press.y))<2);
 assert.notDeepEqual(await positions(),before,'neighbours preview the insertion before release');assert.equal(await revision(),originalRevision);
 await page.mouse.up();await page.waitForTimeout(280);assert.equal(await revision(),'1');assert(await block('utils').evaluate(n=>n===window.dragCardIdentity));assert.equal(await page.locator('[data-drag-active]').count(),0);
 const saved=await positions();await panelCommand(page,'Обновить');await page.waitForTimeout(100);assert.deepEqual(await positions(),saved);
 // A lifted stationary card is neither a click nor a save.
 await hold('utils');await page.mouse.up();await page.waitForTimeout(250);assert.equal(await revision(),'1');assert.equal(await title('utils').getAttribute('aria-expanded'),'false');
 await hold('ci');await page.mouse.move(30,30);await page.keyboard.press('Escape');await page.mouse.up();await page.waitForTimeout(250);assert.deepEqual(await positions(),saved);assert.equal(await revision(),'1');
 await hold('ci');await page.mouse.move(0,500);await page.mouse.up();await page.waitForTimeout(250);assert.equal(await revision(),'1');assert.deepEqual(await positions(),saved);
 // The current test picker keeps the saved selection across collapse and a cancelled lift.
 await title('builds').click();await block('builds').getByRole('tab',{name:'Тесты',exact:true}).click();await block('builds').getByText('Ввести identifiers вручную',{exact:true}).click();const identifiers=block('builds').locator('textarea');await identifiers.fill('FixtureTests/Drag/testIdentity');await title('builds').click();
 await title('builds').click();await hold('builds');assert(await block('builds').locator('.block-content').evaluate(n=>n.hidden));await page.keyboard.press('Escape');await page.mouse.up();await page.waitForTimeout(250);assert.equal(await title('builds').getAttribute('aria-expanded'),'true');await block('builds').getByRole('tab',{name:'Тесты',exact:true}).click();await block('builds').getByText('Ввести identifiers вручную',{exact:true}).click();assert.equal(await identifiers.inputValue(),'FixtureTests/Drag/testIdentity');await title('builds').click();
 const header=await title('ci').boundingBox();await page.mouse.move(header.x+20,header.y+10);await page.mouse.down();await page.mouse.move(header.x+35,header.y+10);await page.waitForTimeout(540);assert.equal(await page.locator('[data-drag-active]').count(),0);await page.mouse.up();assert.equal(await title('ci').getAttribute('aria-expanded'),'false');
 // Interactive controls never lift their containing card.
 const preset=block('bootstrap').locator('.bootstrap-launchers button, select').first(),presetBox=await preset.boundingBox();await page.mouse.move(presetBox.x+10,presetBox.y+10);await page.mouse.down();await page.waitForTimeout(540);assert.equal(await page.locator('[data-drag-active]').count(),0);await page.mouse.up();await page.keyboard.press('Escape');
 await load();await hold('utils');await grid.evaluate(n=>n.releasePointerCapture(1));await page.mouse.up();await page.waitForTimeout(250);assert.equal(await page.locator('[data-drag-active]').count(),0);assert.equal(await revision(),'0');
 await load();await panelCommand(page,'Настроить панель');await reorder();assert.equal(await revision(),'0');await page.getByRole('button',{name:'Отмена',exact:true}).click();assert.deepEqual(await positions(),before);
 await load('&dragSaveFailure=failed');await reorder();assert.equal(await revision(),'0');assert.deepEqual(await positions(),before);assert(await page.getByText('Не удалось сохранить перестановку.',{exact:false}).isVisible());
 await load('&dragSaveFailure=conflict');await reorder();assert.equal(await revision(),'1');assert.deepEqual(await positions(),before);assert(await page.getByText('Раскладка уже изменена.',{exact:false}).isVisible());
 await load('&dragSaveDelay=500');const target=await block('simulators').boundingBox();await hold('utils');await page.mouse.move(target.x+60,target.y+50);await page.mouse.up();const pending=await positions();await panelCommand(page,'Обновить');await page.waitForTimeout(80);assert.deepEqual(await positions(),pending,'poll cannot overwrite an unacknowledged reorder');await page.waitForTimeout(520);assert.equal(await revision(),'1');
 await load();await page.getByRole('button',{name:'История',exact:true}).click();await page.locator('.item').filter({hasText:'Bootstrap iOS'}).first().click();const terminal=page.locator('.bootstrap-history-details .terminal-host');await terminal.locator('.xterm').waitFor();
 await terminal.evaluate(node=>window.dragTerminalIdentity=node);await reorder();await panelCommand(page,'Обновить');await page.waitForTimeout(200);assert(await terminal.evaluate(node=>node===window.dragTerminalIdentity),'terminal instance survives a grid save and a poll');
 await load();await page.setViewportSize({width:520,height:420});await title('utils').scrollIntoViewIfNeeded();await hold('utils');const scrollBefore=await page.evaluate(()=>scrollY);await page.mouse.move(250,415);await page.waitForTimeout(400);assert(await page.evaluate(()=>scrollY)>scrollBefore+20,'document autoscroll follows edge depth');await page.keyboard.press('Escape');await page.mouse.up();
 await page.setViewportSize({width:520,height:1050});await load();await page.emulateMedia({colorScheme:'dark',reducedMotion:'no-preference',contrast:'more'});await block('utils').locator('.block-name').evaluate(n=>n.textContent='Benachrichtigungseinstellungen / Инструменты и генераторы');await block('simulators').locator('.block-summary').evaluate(n=>n.textContent='Очень длинное имя симулятора без ограничения длины 👩🏽‍💻');assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await page.screenshot({path:'/private/tmp/Mimic-drag-520-dark.png',fullPage:true});
 for(const layout of ['empty','one']){await page.goto(url+'&layout='+layout);await grid.waitFor({state:'attached'});assert.equal(await page.locator('.panel-block:not([hidden])').count(),layout==='empty'?0:1);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));}
 await page.setViewportSize({width:360,height:1050});await page.emulateMedia({colorScheme:'light',reducedMotion:'reduce',contrast:'no-preference'});await load();await page.screenshot({path:'/private/tmp/Mimic-drag-360-light.png',fullPage:true});await hold('utils');assert.equal(await block('utils').evaluate(n=>getComputedStyle(n).scale),'1');await page.mouse.move(100,700);await page.keyboard.press('Escape');await page.mouse.up();assert.equal(await revision(),'0');
 assert.deepEqual(errors,[]);console.log('PASS: 360/440/480/520, themes/contrast/Reduce Motion, live source identity/1:1 movement, insertion preview, save/no-op/cancel/conflict/offline/poll race, disclosure/form identity, control exclusion, pointer capture, editing draft, autoscroll, long labels, empty/one');
}finally{await browser.close();server.close();}
