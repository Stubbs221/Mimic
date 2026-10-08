// Created by Василий Маслов on 08.10.2026.
import assert from 'node:assert/strict';
import {panelCommand} from './check-chrome-helpers.mjs';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {build} from 'esbuild';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const module=await build({entryPoints:['appearance.ts'],bundle:true,write:false,format:'esm',platform:'node'});
const {resolveAppearance}=await import('data:text/javascript;base64,'+Buffer.from(module.outputFiles[0].text).toString('base64'));
assert.equal(resolveAppearance(undefined),'legacy');assert.equal(resolveAppearance('tileGrid'),'tileGrid');
assert.equal(resolveAppearance('invalid','tileGrid'),'tileGrid');assert.equal(resolveAppearance(null,'legacy'),'legacy');
const html=await readFile('../Sources/MimicMCP/Resources/panel.html');
const server=createServer((_,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output='/private/tmp/MimicTileGrid-20261008/web';await mkdir(output,{recursive:true});
let browser;
try {
 browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:520,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);await page.waitForFunction(()=>!!window.mimicToolsFixture);
 const appearance=value=>page.evaluate(value=>window.mimicToolsFixture.appearance(value),value);
 const block=kind=>page.locator(`[data-block="${kind}"]`);
 for(const style of ['tileGrid','legacy'])for(const colorScheme of ['light','dark'])for(const width of [320,360,440,480,520]) {
  await appearance(style);await page.setViewportSize({width,height:1000});await page.emulateMedia({colorScheme,reducedMotion:'reduce'});
  await page.waitForFunction(narrow=>document.querySelector('.panel-grid').classList.contains('single-column')===narrow,width<480);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`${style} ${colorScheme} ${width} overflow`);
  assert.equal(Math.round((await block('utils').boundingBox()).height),160);
  if(style==='tileGrid'){
   const first=await block('utils').boundingBox(),second=await block('builds').boundingBox();
   assert.equal(Math.round(first.width),width>=480?(width-44)/2:width-32);
   assert.equal(first.y===second.y,width>=480);
   const ios=await block('bootstrap').getByRole('button',{name:'iOS',exact:true}).boundingBox(),tv=await block('bootstrap').getByRole('button',{name:'tvOS',exact:true}).boundingBox();
   if(width<480)assert(tv.y>=ios.y+ios.height,'N2 stacks narrow platform buttons');else assert.equal(ios.y,tv.y);assert(Math.abs(ios.width-tv.width)<1);
  }
  if(width===520)await page.screenshot({path:`${output}/${style}-${colorScheme}.png`,fullPage:true});
 }
 await page.setViewportSize({width:520,height:1000});await appearance('tileGrid');
 await page.evaluate(()=>window.mimicToolsFixture.mode('expanded'));
 await block('utils').locator('[data-tool="generation"] .tools-catalog-open').click();
 const input=block('utils').locator('input[type=text]');await input.fill('ДлинныйЧерновик🧩');await input.focus();
 await input.evaluate(node=>window.appearanceField=node);
 const before=await page.evaluate(()=>window.mimicToolsFixture.current());
 for(const style of ['legacy','tileGrid','invalid',undefined]){
  await appearance(style);
  assert.equal(await input.inputValue(),'ДлинныйЧерновик🧩');assert(await input.evaluate(node=>node===window.appearanceField&&document.activeElement===node));
  assert.deepEqual(await page.evaluate(()=>window.mimicToolsFixture.current()),before);
 }
 assert.equal(await page.locator('html').getAttribute('data-appearance'),'tileGrid');
 await page.evaluate(()=>{window.mimicBootstrapFixture.mode('full');window.mimicBootstrapFixture.task('running');});
 await block('bootstrap').locator('.terminal-host').waitFor();await page.waitForTimeout(800);
 await block('bootstrap').locator('.terminal-host').evaluate(node=>window.appearanceTerminal=node);
 const terminalInput=block('bootstrap').locator('.xterm-helper-textarea');await terminalInput.focus();await terminalInput.press('a');
 for(const style of ['legacy','tileGrid']){
  await appearance(style);assert(await block('bootstrap').locator('.terminal-host').evaluate(node=>node===window.appearanceTerminal));
  assert(await terminalInput.evaluate(node=>document.activeElement===node));
 }
 assert((await page.evaluate(()=>window.mimicBootstrapFixture.inputCount))>0);
 await block('simulators').locator('.block-title').click();await page.locator('.sim-surface').waitFor();
 await page.locator('.sim-surface').evaluate(node=>window.appearanceScreen=node);
 for(const style of ['legacy','tileGrid']){await appearance(style);assert(await page.locator('.sim-surface').evaluate(node=>node===window.appearanceScreen));}
 await block('simulators').locator('.block-title').click();
 await block('builds').locator('.block-title').click();assert(await block('utils').evaluate(node=>node.hidden&&node.inert&&node.getAttribute('aria-hidden')==='true'));
 await block('builds').locator('.block-title').click();assert(await block('utils').isVisible());
 await panelCommand(page,'Настроить панель');
 const revision=await page.locator('.panel-grid').getAttribute('data-layout-revision');
 const card=await block('utils').boundingBox();await page.mouse.move(card.x+5,card.y+5);await page.mouse.down();await page.waitForTimeout(390);
 assert(await block('utils').evaluate(node=>node.classList.contains('dragging')),'350ms hold activates');
 await appearance('legacy');assert(!await block('utils').evaluate(node=>node.classList.contains('dragging')));await page.mouse.up();
 assert.equal(await page.locator('.panel-grid').getAttribute('data-layout-revision'),revision);assert(await page.getByRole('button',{name:'Готово',exact:true}).isVisible());await page.keyboard.press('Escape');
 await appearance('tileGrid');await page.evaluate(()=>document.documentElement.style.fontSize='26px');await page.waitForTimeout(80);
 assert.equal(await page.locator('html').getAttribute('data-large-text'),'true');
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 assert.equal(await page.locator('.panel-grid').evaluate(node=>getComputedStyle(node).gridTemplateColumns.split(' ').length),1);
 await page.screenshot({path:output+'/large-text.png',fullPage:true});
 assert.deepEqual(errors,[]);console.log('PASS: private appearance fallback, 20 width/theme/style combinations, live field/focus/terminal/simulator identity, peer isolation, drag cancellation/draft retention, 200% text.');
} finally {await browser?.close();server.close();}
