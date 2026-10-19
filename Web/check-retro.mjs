// Created by Василий Маслов on 12.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {build} from 'esbuild';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const compiled=await build({entryPoints:['appearance.ts'],bundle:true,write:false,format:'esm',platform:'node'});
const {AppearanceState}=await import('data:text/javascript;base64,'+Buffer.from(compiled.outputFiles[0].text).toString('base64'));
const state=new AppearanceState();assert.equal(state.accept(undefined,undefined),'legacy');
state.accept({version:1,selection:'windowsXP',revision:3},'legacy');
for(const selection of [{version:1,selection:'windows95',revision:2},{version:1,selection:'legacy',revision:3},{version:1,selection:'bad',revision:4},undefined])assert.equal(state.accept(selection,'legacy'),'windowsXP');
const html=await readFile('../Sources/MimicMCP/Resources/panel.html');
const server=createServer((_,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output='/private/tmp/MimicRetroImplementation-20261012/web';await mkdir(output,{recursive:true});
let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:520,height:1050}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const url=`http://127.0.0.1:${server.address().port}/?preview=1`;
 await page.goto(url);await page.waitForFunction(()=>!!window.mimicToolsFixture);
 const appearance=value=>page.evaluate(value=>window.mimicToolsFixture.appearance(value),value);
 for(const theme of ['tileGrid','legacy','windows95','windowsXP'])for(const host of ['light','dark'])for(const width of [360,440,480,520]){
  await appearance(theme);await page.setViewportSize({width,height:1050});await page.emulateMedia({colorScheme:host});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`${theme}/${host}/${width} overflow`);
  if(theme.startsWith('windows')){
   const colors=await page.evaluate(()=>({background:getComputedStyle(document.documentElement).backgroundColor,colorScheme:getComputedStyle(document.documentElement).colorScheme}));
   assert.equal(colors.colorScheme,'light');assert.equal(colors.background,theme==='windows95'?'rgb(192, 192, 192)':'rgb(236, 233, 216)');
   assert.equal((await page.locator('.chrome-project-row>.chrome-icon-button').boundingBox()).height,24);const caption=page.locator('[data-block=utils]>.retro-caption');const box=await caption.boundingBox();assert.equal(box.width,theme==='windows95'?16:21);assert.equal(box.height,theme==='windows95'?14:21);
  }
  if(width===520||width===360)await page.screenshot({path:`${output}/${theme}-${host}-${width}.png`,fullPage:true});
 }
 await page.setViewportSize({width:520,height:1050});await appearance('windowsXP');
 await page.evaluate(()=>window.mimicToolsFixture.mode('expanded'));
 await page.locator('[data-block=utils] [data-tool=generation] .tools-catalog-open').click();
 const input=page.locator('[data-block=utils] input[type=text]').first();await input.fill('ДлинныйЧерновикЁё');await input.focus();await input.evaluate(n=>{window.retainedInput=n;n.setSelectionRange(2,7);});
 for(const theme of ['windows95','tileGrid','legacy','windowsXP']){
  await appearance(theme);assert(await input.evaluate(n=>n===window.retainedInput&&document.activeElement===n&&n.selectionStart===2&&n.selectionEnd===7));assert.equal(await input.inputValue(),'ДлинныйЧерновикЁё');
 }
 // Exercise a harmless refresh button: immediate hold, leave/return, release outside, Space and Escape.
 const press=page.locator('.chrome-more');let count=0;await press.evaluate(n=>{window.retroClickCount=0;n.addEventListener('click',()=>window.retroClickCount++);});
 const box=await press.boundingBox();await page.mouse.move(box.x+5,box.y+5);await page.mouse.down();assert(await press.getAttribute('data-pressed')!==null);
 await page.mouse.move(box.x-30,box.y-30);assert.equal(await press.getAttribute('data-pressed'),null);
 await page.mouse.move(box.x+5,box.y+5);assert(await press.getAttribute('data-pressed')!==null);
 await page.mouse.up();assert.equal(await page.evaluate(()=>window.retroClickCount),1);await page.keyboard.press('Escape');
 await page.mouse.move(box.x+5,box.y+5);await page.mouse.down();await page.mouse.move(box.x-30,box.y-30);await page.mouse.up();assert.equal(await page.evaluate(()=>window.retroClickCount),1);
 await press.focus();await page.keyboard.down('Space');assert(await press.getAttribute('data-pressed')!==null);await page.keyboard.up('Space');assert.equal(await page.evaluate(()=>window.retroClickCount),2);await page.keyboard.press('Escape');
 await page.keyboard.down('Space');await page.keyboard.press('Escape');await page.keyboard.up('Space');assert.equal(await page.evaluate(()=>window.retroClickCount),2);
 await page.evaluate(()=>{window.mimicBootstrapFixture.mode('full');window.mimicBootstrapFixture.task('running');});
 const terminal=page.locator('[data-block=bootstrap] .terminal-host');await terminal.waitFor();await terminal.evaluate(n=>window.retainedTerminal=n);
 for(const theme of ['windows95','windowsXP','legacy','tileGrid']){await appearance(theme);assert(await terminal.evaluate(n=>n===window.retainedTerminal));}
 await page.locator('[data-block=simulators] .block-title').click();await page.locator('.sim-surface').waitFor();await page.locator('.sim-surface').evaluate(n=>window.retainedSimulator=n);
 for(const theme of ['windows95','windowsXP']){await appearance(theme);assert(await page.locator('.sim-surface').evaluate(n=>n===window.retainedSimulator));}
 await page.goto(url+'&appearance=windowsXP&data=empty');await page.waitForFunction(()=>!!window.mimicToolsFixture);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 await page.evaluate(()=>document.documentElement.style.fontSize='26px');await page.waitForFunction(()=>document.documentElement.dataset.largeText==='true');assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 await page.emulateMedia({reducedMotion:'reduce'});await page.screenshot({path:output+'/xp-large-empty.png',fullPage:true});
 // Save through the real picker, including delayed rejection and the legacy host transition.
 await page.goto(url);await page.waitForFunction(()=>!!window.mimicToolsFixture);
 await page.locator('.chrome-icon-gear').locator('..').click();await page.locator('[data-setup=appearance]').click();
 const choices=page.locator('.appearance-choice');assert.equal(await choices.count(),4);
 await page.evaluate(()=>window.mimicToolsFixture.appearanceSave(true,180));await page.locator('[data-appearance-choice=windowsXP]').click();assert(await page.locator('[data-appearance-choice=tileGrid]').isDisabled());
 await page.waitForFunction(()=>!document.querySelector('[data-appearance-choice=tileGrid]').disabled);assert.equal(await page.locator('html').getAttribute('data-appearance'),'tileGrid');assert(await page.locator('.appearance-message').innerText());
 await page.evaluate(()=>window.mimicToolsFixture.appearanceSave(false));
 for(const theme of ['windows95','legacy','windowsXP','tileGrid']){const choice=page.locator(`[data-appearance-choice=${theme}]`);await choice.click();await page.waitForFunction(theme=>document.documentElement.dataset.appearance===theme,theme);await page.waitForFunction(theme=>!document.querySelector(`[data-appearance-choice=${theme}]`).disabled,theme);assert(await choice.evaluate(n=>document.activeElement===n),theme+': '+await page.evaluate(()=>document.activeElement.className));assert.equal(await choice.getAttribute('aria-checked'),'true');}
 await page.keyboard.press('Escape');await appearance('windowsXP');
 await page.locator('.chrome-layout').click();const layoutDraft=await page.evaluate(()=>JSON.stringify(window.mimicToolsFixture.current().layoutDraft));
 const grip=page.locator('[data-block=utils] .drag-handle'),gripBox=await grip.boundingBox();await page.mouse.move(gripBox.x+15,gripBox.y+8);await page.mouse.down();await page.waitForTimeout(380);assert.equal(await page.locator('[data-drag-active]').count(),1);assert.equal(await page.locator('[data-drag-active]').evaluate(n=>getComputedStyle(n).scale),'1');await appearance('windows95');await page.mouse.up();assert.equal(await page.locator('[data-drag-active]').count(),0);assert.equal(await page.evaluate(()=>JSON.stringify(window.mimicToolsFixture.current().layoutDraft)),layoutDraft);await page.keyboard.press('Escape');
 // Scrollbar metrics, line repeat, page and direct thumb movement use native overflow state.
 await page.evaluate(()=>{const n=document.createElement('div');n.id='scroll-fixture';n.className='list';n.style.cssText='height:100px;width:180px;overflow:auto;line-height:14px';for(let i=0;i<40;i++){const row=document.createElement('div');row.textContent='Строка '+i;n.append(row);}document.querySelector('main').prepend(n);});
 const scroll=page.locator('#scroll-fixture'),rail=scroll.locator('..').locator('.retro-scrollbar');await rail.waitFor();assert.equal((await rail.boundingBox()).width,17);
 const down=rail.locator('.retro-scroll-down'),downBox=await down.boundingBox();await page.mouse.move(downBox.x+8,downBox.y+8);await page.mouse.down();const first=await scroll.evaluate(n=>n.scrollTop);assert(first>0);await page.waitForTimeout(250);assert.equal(await scroll.evaluate(n=>n.scrollTop),first);await page.waitForTimeout(230);assert(await scroll.evaluate(n=>n.scrollTop)>first);await page.mouse.up();const stopped=await scroll.evaluate(n=>n.scrollTop);await page.waitForTimeout(120);assert.equal(await scroll.evaluate(n=>n.scrollTop),stopped);
 const thumb=rail.locator('.retro-scroll-thumb'),thumbBox=await thumb.boundingBox();await page.mouse.move(thumbBox.x+8,thumbBox.y+4);await page.mouse.down();await page.mouse.move(thumbBox.x+8,thumbBox.y+28);await page.mouse.up();assert(await scroll.evaluate(n=>n.scrollTop)>stopped);
 await scroll.evaluate(n=>n.scrollTop=0);const track=rail.locator('.retro-scroll-track'),trackBox=await track.boundingBox();await page.mouse.click(trackBox.x+8,trackBox.y+trackBox.height-2);assert.equal(await scroll.evaluate(n=>n.scrollTop),100);
 await scroll.hover();await page.mouse.wheel(0,80);await page.waitForTimeout(150);assert(await scroll.evaluate(n=>n.scrollTop)>100);
 // Pending tooltip must never return after theme change.
 await appearance('windowsXP');await page.locator('.chrome-branch').hover();await page.waitForTimeout(550);assert(await page.locator('.retro-tooltip').isVisible());await appearance('windows95');await page.waitForTimeout(550);assert(await page.locator('.retro-tooltip').isHidden());
 // Custom select owns no values: its original node handles changes and Escape.
 await page.evaluate(()=>window.mimicBuildFixture.mode('full'));const select=page.locator('[data-block=builds] [data-build-field=scheme]').first();await select.focus();await page.keyboard.press('ArrowDown');assert(await page.locator('.retro-select-popup').isVisible());await page.keyboard.press('Escape');assert(await select.evaluate(n=>document.activeElement===n));
 await page.goto(url+'&helper=old');await page.waitForFunction(()=>!!window.mimicToolsFixture);assert.equal(await page.locator('html').getAttribute('data-appearance'),'legacy');await page.getByRole('button',{name:'Настройки',exact:true}).first().click();await page.getByRole('button',{name:'Оформление',exact:true}).click();assert.equal(await page.locator('.appearance-choice:disabled').count(),4);assert(await page.locator('.appearance-message').innerText());
 assert.deepEqual(errors,[]);
 console.log('PASS: revision rollback protection; 32 theme/host/width combinations; caption dimensions; field/selection/focus, terminal and simulator identity; held leave/return, outside release, Space and Escape; empty/large text; picker save/rejection/focus/old-helper; rail repeat/page/thumb/wheel; tooltip cancellation; native select focus.');
 console.log('Local fonts:',await page.evaluate(async()=>{const result={};for(const family of ['Mimic Win95','Mimic Tahoma']){try{result[family]=(await document.fonts.load(`11px "${family}"`,'Ёё')).length;}catch{result[family]=0;}}return result;}));
}finally{await browser?.close();server.close();}
