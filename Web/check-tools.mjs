// Created by Василий Маслов on 07.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {build} from 'esbuild';
const compiled=await build({entryPoints:[new URL('./tools.ts',import.meta.url).pathname],bundle:true,write:false,format:'esm',platform:'node'});
const {validateFavorites,toolTask}=await import('data:text/javascript;base64,'+Buffer.from(compiled.outputFiles[0].text).toString('base64'));
assert.deepEqual(validateFavorites({revision:1,favorites:[]}).favorites,['generation','localization','format']);assert.throws(()=>validateFavorites({revision:1,favorites:['format','format']}));
const sample={id:'finished',toolID:'format',status:'succeeded',createdAt:'2026-10-07T01:00:00Z',context:{checkoutId:'/fixture'}};
assert.equal(toolTask([sample,{...sample,id:'running',status:'running'},{...sample,id:'preview',status:'running',isPreview:true}],'format','/fixture').id,'running');
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end(html);});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output='/private/tmp/Mimic-tools-web';await mkdir(output,{recursive:true});let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:520,height:1100}}),errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);await page.waitForFunction(()=>!!window.mimicToolsFixture);
 const card=page.locator('.panel-block[data-block="utils"]'),summary=card.locator(':scope > .block-summary'),mode=value=>page.evaluate(value=>window.mimicToolsFixture.mode(value),value);
 const context=await page.evaluate(()=>window.mimicToolsFixture.context()),tasks=[{...sample,context,status:'running',startedAt:new Date(Date.now()-120000).toISOString()},{...sample,id:'preview',toolID:'generation',context,isPreview:true}];
 for(const width of [320,440,480,520])for(const colorScheme of ['light','dark'])for(const reducedMotion of ['reduce','no-preference']){
  await page.setViewportSize({width,height:1100});await page.emulateMedia({colorScheme,reducedMotion});await page.evaluate(tasks=>window.mimicToolsFixture.tasks(tasks),tasks);
  for(const size of ['mini','full'])for(const count of [1,2,3]){
   await page.evaluate(count=>window.mimicToolsFixture.favorites(['generation','localization','format'].slice(0,count)),count);await mode(size);
   assert.equal(await summary.locator('.tools-favorite').count(),count);assert.equal(Math.round((await card.boundingBox()).height),160);
   assert(await card.evaluate(node=>node.scrollWidth<=node.clientWidth+1));
   await checkGeometry(count);await card.screenshot({path:`${output}/${width}-${colorScheme}-${reducedMotion}-${size}-${count}.png`});
  }
 }
 async function checkGeometry(count){
  const geometry=await summary.evaluate(host=>({box:host.getBoundingClientRect().toJSON(),rows:[...host.children].map(node=>({box:node.getBoundingClientRect().toJSON(),scroll:node.scrollWidth,client:node.clientWidth,transition:getComputedStyle(node).transitionDuration,shadow:getComputedStyle(node).boxShadow,icon:node.querySelector('.tools-icon').getBoundingClientRect().toJSON(),content:[...node.children].map(child=>child.getBoundingClientRect().toJSON()).filter(box=>box.width>0&&box.height>0)}))}));
  assert.equal(geometry.rows.length,count);const first=geometry.rows[0].box,last=geometry.rows.at(-1).box;
  assert(Math.abs(first.y-geometry.box.y)<1);assert(Math.abs(last.bottom-geometry.box.bottom)<1);
  for(const [index,row]of geometry.rows.entries()){
   assert(Math.abs(row.box.height-first.height)<1);assert(Math.abs(row.box.width-geometry.box.width)<1);assert(row.scroll<=row.client+1);assert.equal(row.transition,'0s');assert.equal(row.shadow,'none');assert.equal(row.icon.width,24);assert.equal(row.icon.height,20);
   if(index)assert(Math.abs(row.box.y-geometry.rows[index-1].box.bottom-8)<1);
   for(const [childIndex,child]of row.content.entries()){assert(child.x>=row.box.x+7);assert(child.right<=row.box.right-7);if(childIndex)assert(child.x>=row.content[childIndex-1].right-1);}
  }
 }
 await page.setViewportSize({width:520,height:1100});await page.emulateMedia({colorScheme:'light',reducedMotion:'reduce'});
 await page.evaluate(()=>window.mimicToolsFixture.favorites(['generation','localization','format']));await mode('full');
 // Polls must update a focused favorite in place, with a single status line instead of its description.
 const favorite=summary.locator('[data-tool="format"]');await favorite.focus();
 await favorite.evaluate(node=>window.focusedFavorite=node);
 for(const status of ['queued','running','succeeded','failed','cancelled','interrupted']){
  const task={...sample,context,status,startedAt:'2026-10-07T01:00:00Z',finishedAt:['queued','running'].includes(status)?null:'2026-10-07T01:02:05Z'};
  await page.evaluate(task=>window.mimicToolsFixture.tasks([task]),task);
  assert(await favorite.evaluate(node=>document.activeElement===node&&window.focusedFavorite===node));
  assert.equal(await favorite.locator('.tools-state').getAttribute('data-status'),status);
  const annotation=await favorite.locator('.tools-annotation').innerText();assert(!annotation.includes('\n'));assert(!annotation.includes('Форматирование Swift-кода'));
  assert((await favorite.getAttribute('title')).includes('Форматирование Swift-кода'));await checkGeometry(3);
 }
 // A press inside the card padding opens its form and never starts a tile drag or task.
 for(const id of ['generation','localization','format']){
  await mode('mini');const target=summary.locator(`[data-tool="${id}"]`);await target.hover();
  await target.click({position:{x:4,y:(await target.boundingBox()).height/2},delay:420});
  const current=await page.evaluate(()=>window.mimicToolsFixture.current());assert.equal(current.selectedTool,id);assert.equal(current.expanded,'utils');assert(!await card.evaluate(node=>node.classList.contains('dragging')));
 }
 // Keyboard activation opens the same form as padding clicks; hover/press/focus use T4 feedback.
 await mode('full');const keyboardTarget=summary.locator('[data-tool="generation"]');
 await page.keyboard.press('Tab');await keyboardTarget.focus();assert(await keyboardTarget.evaluate(node=>getComputedStyle(node).outlineWidth==='2px'));
 await page.keyboard.press('Enter');assert.equal((await page.evaluate(()=>window.mimicToolsFixture.current())).selectedTool,'generation');
 await mode('mini');await keyboardTarget.hover();
 assert(await keyboardTarget.evaluate(node=>getComputedStyle(node).backgroundColor==='rgb(238, 232, 248)'));
 await page.mouse.down();assert(await keyboardTarget.evaluate(node=>getComputedStyle(node).opacity==='0.8'));await page.mouse.up();
 for(const appearance of ['legacy','tileGrid']){
  await page.evaluate(value=>window.mimicToolsFixture.appearance(value),appearance);await mode('mini');await checkGeometry(3);
 }
 await page.evaluate(()=>{window.mimicToolsFixture.appearance('tileGrid');document.documentElement.style.fontSize='26px';});await page.waitForTimeout(100);
 for(const size of ['mini','full']){await mode(size);await checkGeometry(3);assert(await card.evaluate(node=>node.scrollWidth<=node.clientWidth+1));await card.screenshot({path:output+'/large-text-'+size+'.png'});}
 // Use real translated cleanup names for long text; this is a fixture selection, not a DOM text patch.
 await page.evaluate(()=>{document.documentElement.style.fontSize='';window.mimicToolsFixture.favorites(['fullCleanup','derivedDataCleanup','localization']);});await page.waitForTimeout(100);for(const size of ['mini','full']){await mode(size);await checkGeometry(3);assert(await card.evaluate(node=>node.scrollWidth<=node.clientWidth+1));await card.screenshot({path:output+'/long-names-'+size+'.png'});}
 await page.evaluate(()=>window.mimicToolsFixture.favorites(['generation','localization','format']));
 await mode('expanded');assert.equal(await card.locator('.tools-catalog-row').count(),6);assert(await card.locator('[data-pin="proto"]').isDisabled());
 await card.locator('[data-pin="localization"]').click();await card.locator('[data-pin="proto"]').click();assert.deepEqual((await page.evaluate(()=>window.mimicToolsFixture.current())).favorites,['generation','format','proto']);
 await card.locator('[data-tool="proto"] [data-direction="up"]').click();assert.deepEqual((await page.evaluate(()=>window.mimicToolsFixture.current())).favorites,['generation','proto','format']);
 await card.locator('[data-tool="generation"] .tools-catalog-open').click();let input=card.locator('input[type="text"]');await input.fill('InfrastructureDependencyRegistryConfiguration');await input.focus();
 await page.evaluate(()=>window.mimicToolsFixture.tasks([]));assert.equal(await input.inputValue(),'InfrastructureDependencyRegistryConfiguration');assert(await input.evaluate(node=>document.activeElement===node));
 await card.getByRole('tab',{name:'Sicilia',exact:true}).click();await input.fill('Gallery');await card.getByRole('tab',{name:'UI-компонент',exact:true}).click();assert.equal(await input.inputValue(),'InfrastructureDependencyRegistryConfiguration');
 await card.getByRole('button',{name:'Проверить будущие файлы',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.panel-block[data-block="utils"] .preview-files')?.textContent?.includes('Sources/Fixture.swift'));
 assert.equal((await page.evaluate(()=>window.mimicToolsFixture.current())).selectedTool,'generation');await card.screenshot({path:output+'/generation.png'});
 await card.getByRole('button',{name:'Создать файлы',exact:true}).click();assert.equal((await page.evaluate(()=>window.mimicToolsFixture.current())).selectedTool,'generation');
 await card.locator('.tools-back').click();await card.locator('[data-tool="format"] .tools-catalog-open').click();await card.getByRole('button',{name:'Запустить',exact:true}).click();assert(await card.getByRole('button',{name:'Запустить',exact:true}).isDisabled());assert.equal((await page.evaluate(()=>window.mimicToolsFixture.current())).selectedTool,'format');
 await card.locator('[data-action="tool-cancel"]').click();assert(await card.getByRole('button',{name:'Запустить',exact:true}).isEnabled());
 await page.evaluate(()=>window.mimicToolsFixture.unavailable(['protoc']));await page.waitForFunction(()=>document.querySelector('.tools-readiness')?.textContent?.includes('protoc'));assert(await card.getByRole('button',{name:'Запустить',exact:true}).isDisabled());
 await page.evaluate(()=>window.mimicToolsFixture.unavailable([]));await card.locator('.tools-back').click();await page.evaluate(()=>window.mimicToolsFixture.favorites(['format']));await card.locator('[data-pin="format"]').click();assert.deepEqual((await page.evaluate(()=>window.mimicToolsFixture.current())).favorites,['generation','localization','format']);
 await card.screenshot({path:output+'/catalog.png'});await card.locator('[data-tool="fullCleanup"] .tools-catalog-open').click();await card.screenshot({path:output+'/cleanup.png'});assert.deepEqual(errors,[]);
 console.log('PASS: favorites/catalog, drafts/focus, preview/generation, launch retention/repeat/cancel, readiness; 96 equal-height compact renders; padding clicks, retained focus, every task status, large text, long names and both appearances.');
}finally{await browser?.close();server.close();}
