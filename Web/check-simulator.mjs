//
//  check-simulator.mjs
//  MimicPanel
//
//  Created by Василий Маслов on 05.10.2026.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage({viewport:{width:940,height:1100}}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);
 await page.locator('.panel-block[data-block="simulators"] .block-title').click();
 await page.getByRole('button',{name:'Обновить устройства',exact:true}).click();
 await page.getByRole('button',{name:'Открыть экран',exact:true}).click();
 await page.locator('.simulator-image').waitFor({state:'visible'});
 const input=page.locator('#sim-text');
 await input.fill('Привет  🧪');
 await input.focus();
 await input.evaluate(node=>{window.__input=node;window.__image=document.querySelector('.simulator-image');node.setSelectionRange(4,4);});
 await page.waitForTimeout(6100);
 assert.equal(await input.evaluate(node=>node===window.__input&&document.activeElement===node&&node.selectionStart===4),true,'Polling must preserve textarea identity, focus and selection');
 assert.equal(await page.locator('.simulator-image').evaluate(node=>node===window.__image),true,'Polling must preserve the image node');
 await page.getByRole('button',{name:'Ввести на устройстве',exact:true}).click();
 await page.waitForFunction(()=>document.querySelector('#sim-text')?.value==='');
 await page.getByRole('button',{name:'Обновить экран',exact:true}).click();
 await page.waitForFunction(()=>document.querySelector('.simulator-image')?.getAttribute('aria-disabled')==='false');
 assert.equal(await page.locator('.simulator-image').evaluate(node=>node===window.__image),true);
 await page.setViewportSize({width:480,height:1100});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Narrow layout must not overflow');
 await page.screenshot({path:process.env.MIMIC_PANEL_SCREENSHOT??'/private/tmp/MimicSimulatorPanel-20261005.png',fullPage:true});
 await page.getByRole('button',{name:'Закрыть экран',exact:true}).click();
 await page.waitForFunction(()=>document.querySelector('.simulator-image')?.hidden===true);
 assert.deepEqual(errors,[]);
 console.log('PASS: simulator UI, Unicode input, stable DOM/focus/selection, refresh, narrow layout and close');
}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
