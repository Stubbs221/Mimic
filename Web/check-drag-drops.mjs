// Created by Василий Маслов on 13.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage({viewport:{width:520,height:1250}}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);
 await page.waitForFunction(()=>!!window.mimicDragFixture);
 const original=await page.evaluate(()=>window.mimicDragFixture.snapshot().saved);
 const card=block=>page.locator(`.panel-block[data-block="${block}"]`);
 const snapshot=()=>page.evaluate(()=>window.mimicDragFixture.snapshot());
 const slots=layout=>layout.rows.map(r=>r.slots);
 async function reset(){await page.evaluate(layout=>window.mimicDragFixture.set(layout),original);await page.waitForTimeout(180);}
 async function hold(block){const rect=await card(block).locator('.block-title').boundingBox();await page.mouse.move(rect.x+24,rect.y+12);await page.mouse.down();await page.waitForTimeout(200);assert.equal(await page.locator('[data-drag-active]').count(),1);}
 for(let index=0;index<50;index++){
  const width=[360,440,480,520][index%4];await page.setViewportSize({width,height:1250});
  await page.emulateMedia({colorScheme:index%2?'dark':'light',reducedMotion:index%3?'no-preference':'reduce'});await reset();
  const source=index%2?'ci':'utils',destination=index%2?'builds':'simulators';
  await hold(source);assert.equal(await page.locator('.drag-zone,.drag-status,.drag-dwell-progress').count(),0);const rect=await card(destination).boundingBox();
  await page.mouse.move(rect.x+rect.width/2,rect.y+rect.height/2);
  await page.waitForFunction(()=>{const s=window.mimicDragFixture.snapshot();return s.valid&&JSON.stringify(s.shown.rows.map(r=>r.slots))!==JSON.stringify(s.saved.rows.map(r=>r.slots));});
  const shown=(await snapshot()).shown,placeholder=await page.locator('.drag-placeholder').boundingBox();assert(placeholder);
  const release={x:placeholder.x+(index%3===0?2:placeholder.width/2),y:placeholder.y+placeholder.height/2};
  await page.mouse.move(release.x,release.y);const beforeRelease=await snapshot();await page.mouse.up();await page.waitForTimeout(180);
  const saved=(await snapshot()).saved;assert.deepEqual(saved.rows,shown.rows,`drop ${index} ${width}: commits shown placeholder ${JSON.stringify({beforeRelease,placeholder,release})}`);
  assert.deepEqual(saved.rows.flatMap(r=>r.slots).filter(Boolean).sort(),original.rows.flatMap(r=>r.slots).filter(Boolean).sort());
  assert.equal(await page.locator('[data-drag-active]').count(),0);
 }
 await page.setViewportSize({width:520,height:1250});await page.emulateMedia({reducedMotion:'no-preference'});await reset();
 await hold('builds');await page.waitForTimeout(500);assert.deepEqual(slots((await snapshot()).shown),slots(original),'stationary lift never resizes');
 await page.keyboard.press('Escape');await page.mouse.up();await reset();await hold('bootstrap');
 const grid=await page.locator('.panel-grid').boundingBox();await page.mouse.move(grid.x+grid.width*.95,grid.y+28);
 await page.waitForTimeout(190);assert(!await card('bootstrap').evaluate(n=>n.classList.contains('mini')),'resize waits 250ms');
 await page.waitForTimeout(100);assert(await card('bootstrap').evaluate(n=>n.classList.contains('mini')),'resize confirms after movement and dwell');
 const pinned=await page.locator('.drag-placeholder').boundingBox();await page.mouse.move(pinned.x+2,pinned.y+pinned.height/2);await page.mouse.up();await page.waitForTimeout(180);assert((await snapshot()).saved.rows.some(r=>r.slots[1]==='bootstrap'),'chosen right half persists');
 await reset();await hold('utils');await page.mouse.move(0,500);await page.mouse.up();await page.waitForTimeout(180);assert.deepEqual(slots((await snapshot()).saved),slots(original),'outside drop rolls back');
 assert.deepEqual(errors,[]);console.log('PASS: 50/50 browser drops match preview at 360/440/480/520, themes/Reduce Motion, edges/animation, no loss; stationary hold, 250ms resize/right pin, outside rollback');
}finally{await browser.close();server.close();}
