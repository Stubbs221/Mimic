// Created by Василий Маслов on 08.10.2026.
// Addressed source-selection and continuous-input checks in disposable Chrome.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_request,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage({viewport:{width:720,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);
 await page.locator('[data-block="simulators"] .block-title').click();
 const panel=page.locator('.simulator-v2'),screen=page.locator('.sim-surface');
 await page.waitForFunction(()=>document.querySelector('.simulator-v2')?.dataset.hidReady==='true');
 assert.equal(await panel.getAttribute('data-image-source'),'auto');assert.equal(await panel.getAttribute('data-input-source'),'hid');
 assert.equal(await page.locator('[data-image-source="websocket"]').isDisabled(),true);
 await screen.scrollIntoViewIfNeeded();await page.waitForTimeout(150);const r=await screen.boundingBox();await page.mouse.move(r.x+r.width*.5,r.y+r.height*.5);await page.mouse.down();
 await page.waitForFunction(()=>window.mimicSimulatorFixture.inputEvents().some(e=>e.phase==='down'),null,{timeout:5000}).catch(async error=>{console.log(await panel.evaluate(n=>({state:{...n.dataset},calls:window.mimicSimulatorFixture.calls(),events:window.mimicSimulatorFixture.inputEvents()})));throw error;});
 assert.equal((await page.evaluate(()=>window.mimicSimulatorFixture.inputEvents())).some(e=>e.phase==='up'),false,'Down is delivered before release');
 await page.mouse.move(r.x+r.width*.5,r.y+r.height*.35,{steps:8});await page.mouse.up();
 await page.waitForFunction(()=>window.mimicSimulatorFixture.inputEvents().some(e=>e.phase==='up'));
 const events=await page.evaluate(()=>window.mimicSimulatorFixture.inputEvents());assert.equal(events[0].phase,'down');assert.equal(events.at(-1).phase,'up');assert.ok(events.some(e=>e.phase==='move'));assert.ok(events.every((e,i)=>e.sequence===i+1));
 assert.equal((await page.evaluate(()=>window.mimicSimulatorFixture.actions())).length,0,'HID does not dispatch a legacy swipe');
 await page.waitForFunction(()=>document.querySelector('.simulator-v2')?.dataset.hidActive==='false');
 await page.locator('button[data-image-source="snapshots"]').click();await page.waitForFunction(()=>document.querySelector('.simulator-v2')?.dataset.imageSource==='snapshots'&&document.querySelector('.simulator-v2')?.dataset.hidReady==='true');
 assert.equal(await panel.getAttribute('data-input-source'),'hid');
 const videoStarts=await page.evaluate(()=>window.mimicSimulatorFixture.calls().filter(x=>x==='simulator_ui_video'||x==='simulator_ui_video_stop').length);await page.locator('button[data-input-source="apple"]').click();await page.waitForFunction(()=>document.querySelector('.simulator-v2')?.dataset.inputSource==='apple');assert.equal(await panel.getAttribute('data-image-source'),'snapshots');
 await page.locator('button[data-input-source="hid"]').click();await page.waitForFunction(()=>document.querySelector('.simulator-v2')?.dataset.hidReady==='true');
 assert.equal(await page.evaluate(()=>window.mimicSimulatorFixture.calls().filter(x=>x==='simulator_ui_video'||x==='simulator_ui_video_stop').length),videoStarts,'Input changes retain the image delivery');
 await page.getByRole('button',{name:'Повернуть',exact:true}).click();await page.waitForFunction(()=>window.mimicSimulatorFixture.actions().some(a=>a.action.type==='orientation'));
 await page.waitForFunction(()=>document.querySelector('.simulator-v2')?.dataset.hidReady==='true');assert.equal(await panel.getAttribute('data-last-action-status'),'succeeded');
 const calls=await page.evaluate(()=>window.mimicSimulatorFixture.calls()),action=calls.lastIndexOf('simulator_ui_viewer_action'),cancel=calls.lastIndexOf('simulator_ui_input_cancel',action);assert.ok(cancel>=0&&action>cancel);assert.equal(calls.slice(cancel+1,action).includes('simulator_ui_input'),false,'No helper restart between cancellation and Apple admission');
 await page.locator('button[data-image-source="mcp"]').click();await page.waitForFunction(()=>!!document.querySelector('.simulator-v2')?.dataset.sourceFailure);
 assert.equal(await page.locator('.simulator-image').isVisible(),false);assert.match(await page.locator('.sim-message').textContent(),/недоступен/i);
 await page.waitForTimeout(500);const before=await page.evaluate(()=>window.mimicSimulatorFixture.calls().filter(x=>x==='simulator_ui_frame').length);await page.waitForTimeout(900);assert.equal(await page.evaluate(()=>window.mimicSimulatorFixture.calls().filter(x=>x==='simulator_ui_frame').length),before,'Explicit video does not start snapshot polling');
 await page.locator('button[data-image-source="auto"]').click();await page.locator('.simulator-image').waitFor({state:'visible'});
 const output='/private/tmp/MimicSimulatorInputAcceptance-20261008';await mkdir(output,{recursive:true});
 for(const width of [320,360,720]){await page.setViewportSize({width,height:1000});for(const theme of ['light','dark']){await page.emulateMedia({colorScheme:theme});await page.waitForTimeout(100);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);for(const button of await page.locator('.sim-source-option').all()){const box=await button.boundingBox();assert.ok(box&&box.width>20&&box.height>20&&box.x>=0&&box.x+box.width<=width);}await page.locator('.sim-sources').screenshot({path:`${output}/sources-${width}-${theme}.png`});}}
 await page.locator('[data-block="simulators"] .block-title').click();await page.waitForTimeout(250);const frames=await page.evaluate(()=>window.mimicSimulatorFixture.calls().filter(x=>x==='simulator_ui_frame').length);await page.waitForTimeout(700);assert.equal(await page.evaluate(()=>window.mimicSimulatorFixture.calls().filter(x=>x==='simulator_ui_frame').length),frames);
 await page.locator('[data-block="simulators"] .block-title').click();await page.waitForFunction(()=>document.querySelector('.simulator-v2')?.dataset.hidReady==='true');
 assert.deepEqual(errors,[]);console.log('PASS: V2 independent sources, immediate ordered HID input, orientation cancellation, unavailable explicit video, auto fallback, 320/360/720 light/dark and collapse/resume');
}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
