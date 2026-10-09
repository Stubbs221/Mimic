// Created by Василий Маслов on 09.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const {chromium}=createRequire(import.meta.url)(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output='/private/tmp/Mimic-build-card-acceptance-20261009';await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage({viewport:{width:520,height:1100},reducedMotion:'reduce'});
 const errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1&layout=all&data=empty`);
 await page.waitForFunction(()=>!!window.mimicBuildFixture);
 const card=page.locator('[data-block="builds"]');
 const mode=mode=>page.evaluate(mode=>window.mimicBuildFixture.mode(mode),mode);
 const sameHeight=async()=>{
  const result=await page.evaluate(()=>{
   const cards=[...document.querySelectorAll('.panel-block:not(.expanded)')].filter(card=>card.offsetParent!==null);
   const expected=160*Number(getComputedStyle(document.documentElement).getPropertyValue('--bootstrap-text-scale')||1);
   const builds=document.querySelector('[data-block="builds"]'),bounds=builds.getBoundingClientRect();
   const controls=[...builds.querySelectorAll('[data-build-action],[data-build-cancel],[role=progressbar],select')].filter(control=>control.offsetParent!==null);
   return {expected,heights:cards.map(card=>card.getBoundingClientRect().height),escaped:controls.filter(control=>{const r=control.getBoundingClientRect();return r.bottom>bounds.bottom+1||r.top<bounds.top-1||r.right>bounds.right+1||r.left<bounds.left-1;}).map(control=>control.outerHTML)};
  });
  assert(result.heights.every(height=>Math.abs(height-result.expected)<1),JSON.stringify(result));
  assert.deepEqual(result.escaped,[],'all controls must fit the shared tile height');
 };
 await mode('mini');await card.locator('[data-build-action="run"]').waitFor();
 await page.waitForFunction(()=>window.mimicBuildFixture.draft().scheme==='Fixture');await page.waitForTimeout(300);
 assert.equal(await card.locator('[data-build-action]').count(),3);
 await card.locator('[data-build-action="run"]').evaluate(button=>{button.click();button.click();});
 await page.waitForFunction(()=>window.mimicBuildFixture.calls().length===1);
 assert.equal((await page.evaluate(()=>window.mimicBuildFixture.calls()))[0].operation,'run');
 assert(!await card.evaluate(card=>card.classList.contains('expanded')));
 await sameHeight();
 await page.evaluate(()=>window.mimicBuildFixture.task('running','installation',1));
 assert.equal(await card.locator('[role="progressbar"]').getAttribute('aria-valuenow'),'33');
 assert(await card.locator('[data-build-action="run"]').isDisabled());
 assert(!await card.locator('[data-build-action="run"]').isVisible());await sameHeight();
 await card.locator('[data-build-cancel]').click();await page.waitForTimeout(100);
 assert(!await card.evaluate(card=>card.classList.contains('expanded')));
 await page.evaluate(()=>window.mimicBuildFixture.empty());await mode('full');
 await card.locator('[data-build-action="tests"]').focus();await card.locator('[data-build-action="tests"]').press('Enter');
 const popup=page.locator('.build-popover:popover-open');await popup.waitFor();
 assert.equal((await page.evaluate(()=>window.mimicBuildFixture.calls())).length,1,'opening catalogue does not submit');
 await popup.locator('[data-catalogue-load]').click();await page.waitForFunction(()=>window.mimicBuildFixture.calls().length===2);
 assert.equal((await page.evaluate(()=>window.mimicBuildFixture.calls()))[1].operation,'catalogue');
 await page.evaluate(()=>window.mimicBuildFixture.task('succeeded','catalogue'));
 await popup.getByLabel('testOne()',{exact:true}).waitFor();
 await popup.getByLabel('testOne()',{exact:true}).check();
 await popup.getByRole('searchbox').fill('Another');assert.equal(await popup.locator('.build-test-row').count(),1);
 await popup.getByLabel('testAnother()',{exact:true}).check();await popup.getByRole('searchbox').fill('');
 assert(await popup.getByLabel('testOne()',{exact:true}).isChecked());
 await page.screenshot({path:output+'/test-picker-light.png'});
 await popup.locator('[data-tests-start]').click();await page.waitForFunction(()=>window.mimicBuildFixture.calls().length===3);
 const selected=(await page.evaluate(()=>window.mimicBuildFixture.calls()))[2];
 assert.equal(selected.operation,'tests');assert.deepEqual(selected.parameters.testIdentifiers,['FixtureTests/Checkout/testOne()','FixtureTests/Other/testAnother()']);
 assert(!await card.evaluate(card=>card.classList.contains('expanded')));
 await page.evaluate(()=>window.mimicBuildFixture.task('succeeded'));
 for(const width of [520,360,260])for(const theme of ['light','dark']){
  await page.setViewportSize({width,height:1100});await page.emulateMedia({colorScheme:theme,contrast:'more',reducedMotion:'reduce'});await mode(width===520?'full':'mini');
  assert(await card.locator('[data-build-action="run"]').isVisible());
  const overflow=await card.evaluate(card=>card.scrollWidth>card.clientWidth+1);assert(!overflow,`overflow at ${width}/${theme}`);
  await sameHeight();
  await card.screenshot({path:output+`/${width}-${theme}.png`});
 }
 await page.evaluate(()=>document.documentElement.style.setProperty('--bootstrap-text-scale','1.5'));await mode('mini');
 assert(!await card.evaluate(card=>card.scrollWidth>card.clientWidth+1));await sameHeight();await card.screenshot({path:output+'/large-text.png'});
 await page.evaluate(()=>document.documentElement.style.removeProperty('--bootstrap-text-scale'));
 for(const width of [520,360,260]){
  await page.setViewportSize({width,height:1100});await mode(width===520?'full':'mini');
  for(const status of ['queued','running','failed','succeeded']){await page.evaluate(status=>window.mimicBuildFixture.task(status,'installation',1),status);await sameHeight();}
  await page.evaluate(()=>window.mimicBuildFixture.empty());await sameHeight();
 }
 await page.setViewportSize({width:520,height:1100});await mode('extended');assert.equal(await card.getByRole('tab').count(),3);
 await card.getByRole('tab',{name:'Тесты',exact:true}).click();assert(await card.locator('[data-tests-start]').isVisible());
 await mode('mini');await card.locator('[data-build-action="run"]').click();await page.waitForTimeout(100);
 await page.evaluate(()=>window.mimicBuildFixture.products());await page.locator('.build-popover:popover-open').getByRole('button',{name:'App2',exact:true}).click();
 await sameHeight();
 assert.equal(await page.evaluate(()=>window.mimicBuildFixture.draft().scheme),'Fixture');
 await page.evaluate(()=>window.mimicBuildFixture.changeContext());assert.equal(await page.locator('.build-popover:popover-open').count(),0);
 assert.deepEqual(errors,[]);console.log('PASS: standalone Mini/Full, progress/cancel, explicit catalogue, exact selection, themes/narrow widths, Extended tabs, product picker, context change');
}finally{await browser.close();server.close();}
