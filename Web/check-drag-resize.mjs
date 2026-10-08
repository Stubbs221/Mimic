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
 const card=kind=>page.locator(`.panel-block[data-block="${kind}"]`),grid=page.locator('.panel-grid');
 const mini=kind=>card(kind).evaluate(n=>n.classList.contains('mini'));
 const revision=()=>grid.getAttribute('data-layout-revision');
 async function load(query=''){await page.goto(url+query);await card('bootstrap').waitFor();await page.waitForTimeout(250);}
 async function hold(kind){const node=await card(kind).evaluate(n=>({x:n.offsetLeft,y:n.offsetTop,width:n.offsetWidth,height:n.offsetHeight})),bounds=await grid.boundingBox();const pointer={x:bounds.x+node.x+40,y:bounds.y+node.y+28},anchor={x:40/node.width,y:28/node.height};await page.mouse.move(pointer.x,pointer.y);await page.mouse.down();await page.waitForTimeout(530);assert.equal(await page.locator('[data-drag-active]').count(),1);return{pointer,anchor};}
 async function cancel(){await page.keyboard.press('Escape');await page.mouse.up();await page.waitForTimeout(180);}
 async function moveInGrid(x,y){const box=await grid.boundingBox();const point={x:box.x+box.width*x,y:box.y+y};await page.mouse.move(point.x,point.y);return point;}
 async function pointerAnchored(kind,point,anchor){const box=await card(kind).boundingBox();assert(Math.abs(box.x+box.width*anchor.x-point.x)<2,'horizontal anchor follows pointer through morph');assert(Math.abs(box.y+box.height*anchor.y-point.y)<2,'vertical anchor follows pointer through morph');}
 await load();await card('bootstrap').evaluate(n=>window.resizeCardIdentity=n);
 const grabbed=await hold('bootstrap'),right=await moveInGrid(.95,28);
 await page.waitForTimeout(400);assert(!await mini('bootstrap'),'does not shrink before half a second');
 await page.waitForTimeout(180);assert(await mini('bootstrap'),'stationary edge shrinks');await pointerAnchored('bootstrap',right,grabbed.anchor);
 await page.waitForTimeout(200);assert(await card('bootstrap').evaluate(n=>n===window.resizeCardIdentity));assert(Math.abs((await card('bootstrap').boundingBox()).width-238*1.04)<1);
 const center=await moveInGrid(.6,28);await page.waitForTimeout(400);assert(await mini('bootstrap'),'reverse also waits');await page.waitForTimeout(180);assert(!await mini('bootstrap'));await pointerAnchored('bootstrap',center,grabbed.anchor);await page.waitForTimeout(200);
 await page.mouse.move(0,300);await page.waitForTimeout(200);assert(!await mini('bootstrap'),'leaving the valid region retains the confirmed full size');
 await cancel();assert.equal(await revision(),'0');assert(!await mini('bootstrap'));
 // Fast crossings and continuous travel do not resize an existing mini card.
 await hold('builds');await moveInGrid(.9,176);await moveInGrid(.6,176);await page.waitForTimeout(200);await moveInGrid(.1,176);assert(await mini('builds'));await cancel();assert.equal(await revision(),'0');
 await hold('builds');for(let step=0;step<9;step++){await moveInGrid(.32+step*.04,176);await page.waitForTimeout(80);}assert(await mini('builds'),'travel beyond 50pt repeatedly resets dwell');await cancel();
 // A stationary lift starts dwell; early drop and cancellation never complete a pending resize later.
 await hold('builds');await page.waitForTimeout(550);assert(!await mini('builds'));await cancel();assert.equal(await revision(),'0');
 await hold('builds');await moveInGrid(.6,176);await page.waitForTimeout(180);await page.mouse.up();await page.waitForTimeout(600);assert(await mini('builds'));assert.equal(await revision(),'0');
 await hold('builds');await moveInGrid(.6,176);await page.waitForTimeout(180);await cancel();await page.waitForTimeout(550);assert(await mini('builds'));assert.equal(await revision(),'0');
 // Size-only changes save once and survive polling; editing remains a cancellable draft.
 await load();await hold('bootstrap');await moveInGrid(.95,28);await page.waitForTimeout(750);await page.mouse.up();await page.waitForTimeout(280);assert(await mini('bootstrap'));assert.equal(await revision(),'1');assert.equal(await card('bootstrap').evaluate(n=>n.style.gridColumn),'2');
 await panelCommand(page,'Обновить');await page.waitForTimeout(100);assert(await mini('bootstrap'));assert.equal(await revision(),'1');
 await load();await panelCommand(page,'Настроить панель');await hold('bootstrap');await moveInGrid(.05,28);await page.waitForTimeout(750);await page.mouse.up();await page.waitForTimeout(250);assert(await mini('bootstrap'));assert.equal(await revision(),'0');await page.getByRole('button',{name:'Отмена',exact:true}).click();assert(!await mini('bootstrap'));
 for(const failure of ['failed','conflict']){await load('&dragSaveFailure='+failure);await hold('bootstrap');await moveInGrid(.95,28);await page.waitForTimeout(750);await page.mouse.up();await page.waitForTimeout(280);assert(!await mini('bootstrap'));assert.equal(await revision(),failure==='conflict'?'1':'0');}
 // Single-column Codex keeps logical mini size; Reduce Motion retains the half-second delay.
 for(const width of [360,440,480,520]){
  await page.setViewportSize({width,height:1050});await page.emulateMedia({reducedMotion:'reduce',colorScheme:width===440?'dark':'light'});await load();const box=await grid.boundingBox();await hold('bootstrap');await moveInGrid(.95,28);await page.waitForTimeout(400);assert(!await mini('bootstrap'));await page.waitForTimeout(180);assert(await mini('bootstrap'));assert.equal(await card('bootstrap').evaluate(n=>getComputedStyle(n).scale),'1');const shrunk=await card('bootstrap').boundingBox();assert(Math.abs(shrunk.width-(width<480?box.width:(box.width-12)/2))<1);await cancel();
 }
 await page.setViewportSize({width:520,height:1050});await page.emulateMedia({reducedMotion:'no-preference'});await load();await hold('bootstrap');await moveInGrid(.95,28);await page.waitForTimeout(750);assert(await mini('bootstrap'));await page.screenshot({path:'/private/tmp/Mimic-drag-resize-mini.png'});await cancel();
 assert.deepEqual(errors,[]);console.log('PASS: 500ms radius resize/reverse, pointer anchor during morph, node identity, fast crossing/continuous motion, no-motion/early-drop/cancel, size-only save/poll/draft/failure/conflict, 360/440/480/520, Reduce Motion');
}finally{await browser.close();server.close();}
