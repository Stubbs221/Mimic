// Created by Василий Маслов on 07.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
const url=`http://127.0.0.1:${server.address().port}/?preview=1`,errors=[];
try{
 const page=await browser.newPage({viewport:{width:520,height:1050}});page.on('pageerror',e=>errors.push(e.message));
 const card=kind=>page.locator(`.panel-block[data-block="${kind}"]`),grid=page.locator('.panel-grid');
 async function load(query=''){await page.goto(url+query);await card('bootstrap').waitFor();await page.waitForTimeout(250);}
 async function hold(kind){const box=await card(kind).locator('.block-title').boundingBox();const point={x:box.x+40,y:box.y+10};await page.mouse.move(point.x,point.y);await page.mouse.down();await page.waitForTimeout(540);assert.equal(await page.locator('[data-drag-active]').count(),1);return point;}
 async function cancel(){await page.keyboard.press('Escape');await page.mouse.up();await page.waitForTimeout(240);}
 async function logical(kind){return card(kind).evaluate(n=>{const g=n.parentElement.getBoundingClientRect();return{x:g.x+n.offsetLeft,y:g.y+n.offsetTop,width:n.offsetWidth,height:n.offsetHeight};});}
 async function matchesPlaceholder(kind){const source=await logical(kind),placeholder=await page.locator('.drag-placeholder').boundingBox();assert(placeholder);for(const key of ['x','y','width','height'])assert(Math.abs(source[key]-placeholder[key])<1,`${key}: placeholder matches live layout`);}
 await load();const press=await hold('utils');await page.waitForTimeout(150);await matchesPlaceholder('utils');
 await page.evaluate(()=>{
  window.dragMeasurements={renders:0,frames:[],running:true};
  const data=window.dragMeasurements;new MutationObserver(records=>data.renders+=records.length).observe(document.querySelector('.panel-grid'),{attributes:true,attributeFilter:['data-layout-revision']});
  let previous=performance.now();const tick=time=>{if(!data.running)return;data.frames.push(time-previous);previous=time;requestAnimationFrame(tick);};requestAnimationFrame(tick);
 });
 for(let index=0;index<60;index++){await page.mouse.move(press.x+Math.sin(index)*10,press.y+Math.cos(index)*10);await page.waitForTimeout(10);}
 const measurements=await page.evaluate(()=>{window.dragMeasurements.running=false;return window.dragMeasurements;});
 assert.equal(measurements.renders,0,'pointer events inside a placeholder do not rerender the grid');
 const frames=measurements.frames.slice(1).sort((a,b)=>a-b),p95=frames[Math.floor(frames.length*.95)];
 assert(frames.length>=30,'sample enough live frames');assert(p95<60,`drag frame p95 ${p95.toFixed(2)}ms`);
 await cancel();await card('utils').locator('.block-title').click();assert.equal(await card('utils').locator('.block-title').getAttribute('aria-expanded'),'true','Escape never suppresses the next normal click');
 await load();await hold('bootstrap');const box=await grid.boundingBox();await page.mouse.move(box.x+box.width*.95,box.y+28);
 await page.waitForTimeout(200);assert.equal(await page.locator('.drag-status').getAttribute('data-pending'),'right');
 assert(await page.locator('.drag-dwell-progress').evaluate(n=>getComputedStyle(n).transform!=='matrix(0, 0, 0, 1, 0, 0)'));
 await page.waitForTimeout(400);assert(await card('bootstrap').evaluate(n=>n.classList.contains('mini')));await matchesPlaceholder('bootstrap');
 const destination=await logical('simulators');await page.mouse.move(destination.x+destination.width/2,destination.y+destination.height/2);await page.waitForTimeout(100);
 await matchesPlaceholder('bootstrap');const preview=await grid.evaluate(n=>n.dataset.placeholders);
 await page.waitForTimeout(250);assert.equal(await grid.evaluate(n=>n.dataset.placeholders),preview,'stationary pointer cannot oscillate after insertion');
 const expected=await card('bootstrap').evaluate(n=>[n.style.gridRow,n.style.gridColumn]);await page.mouse.up();await page.waitForTimeout(250);
 assert.deepEqual(await card('bootstrap').evaluate(n=>[n.style.gridRow,n.style.gridColumn]),expected,'drop commits the shown placeholder');
 await load('&layout=all');assert.equal(await page.locator('.panel-block:not([hidden])').count(),16);
 await page.setViewportSize({width:360,height:700});await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});
 await page.evaluate(()=>document.documentElement.style.fontSize='26px');assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 await hold('bootstrap');await page.mouse.move(180,690);await page.waitForTimeout(700);assert(await page.evaluate(()=>scrollY)>50);await cancel();
 await page.screenshot({path:'/private/tmp/Mimic-drag-all-360.png',fullPage:true});
 assert.deepEqual(errors,[]);console.log(`PASS: live placeholder after resize/reorder, stationary stability, drop agreement, progress, next click, max catalog/large text/autoscroll; ${frames.length} frames, p95=${p95.toFixed(2)}ms, grid renders=${measurements.renders}`);
}finally{await browser.close();server.close();}
