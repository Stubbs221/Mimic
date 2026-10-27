// Created by Василий Маслов on 09.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const {chromium}=createRequire(import.meta.url)(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output='/private/tmp/Mimic-build-card-acceptance-20261023';await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage({viewport:{width:520,height:1100},reducedMotion:'reduce'});
 const errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1&layout=all&data=empty`);
 await page.waitForFunction(()=>!!window.mimicBuildFixture);
 const card=page.locator('[data-block="builds"]');
 const mode=mode=>page.evaluate(mode=>window.mimicBuildFixture.mode(mode),mode);
 const task=(status,stage='compilation',count=null)=>page.evaluate(([status,stage,count])=>window.mimicBuildFixture.task(status,stage,count),[status,stage,count]);
 const fit=async()=>{
  const result=await card.evaluate(card=>{
   const bounds=card.getBoundingClientRect(),controls=[...card.querySelectorAll('[data-build-action],[data-build-cancel],[role=progressbar],select')].filter(n=>n.offsetParent!==null);
   const scale=Number(getComputedStyle(document.documentElement).getPropertyValue('--bootstrap-text-scale')||1);
   return{height:bounds.height,expected:160*scale,escaped:controls.filter(n=>{const r=n.getBoundingClientRect();return r.bottom>bounds.bottom+1||r.top<bounds.top-1||r.right>bounds.right+1||r.left<bounds.left-1;}).map(n=>n.outerHTML)};
  });assert(Math.abs(result.height-result.expected)<1,JSON.stringify(result));assert.deepEqual(result.escaped,[]);
 };
 await mode('mini');await page.waitForFunction(()=>window.mimicBuildFixture.draft().testTarget==='FixtureTests');
 assert.equal(await card.getByRole('searchbox').count(),0);assert.equal(await card.locator('[data-catalogue-load]').count(),0);
 assert.equal(await card.locator('select[data-build-field=testTarget]').inputValue(),'FixtureTests');
 await card.locator('[data-build-action=tests]').evaluate(b=>{b.click();b.click();});
 await page.waitForFunction(()=>window.mimicBuildFixture.calls().length===1);
 const call=(await page.evaluate(()=>window.mimicBuildFixture.calls()))[0];assert.equal(call.operation,'tests');assert.equal(call.parameters.testTarget,'FixtureTests');assert.deepEqual(call.parameters.testIdentifiers,[]);assert.equal(call.parameters.backend,'cli');
 await task('running','compilation');assert(!await card.locator('[data-build-action=tests]').isVisible());assert(await card.getByRole('progressbar').isVisible());await fit();
 await task('succeeded');assert(await card.locator('[data-build-action=tests]').isVisible());assert(!await card.getByRole('progressbar').isVisible());
 await task('failed');assert(await card.getByRole('progressbar').isVisible());assert(!await card.locator('[data-build-action=tests]').isVisible());
 await card.locator('.build-current-work').press('Enter');await page.waitForFunction(()=>document.querySelector('[data-block="builds"] [data-build-action=tests]')?.offsetParent!==null);
 assert(!await card.getByRole('progressbar').isVisible());
 await page.evaluate(()=>window.mimicBuildFixture.empty());await mode('full');await card.locator('[data-build-action=tests]').click();await task('running','installation',1);
 assert.equal(await card.getByRole('progressbar').getAttribute('aria-valuenow'),'33');
 const widths=await card.evaluate(card=>({bar:card.querySelector('[role=progressbar]').getBoundingClientRect().width,content:card.querySelector('.build-card-controls').getBoundingClientRect().width}));assert(widths.bar<=widths.content/2+0.5,JSON.stringify(widths));
 await card.locator('[data-build-cancel]').click();await page.waitForTimeout(100);assert(await card.locator('[data-build-action=tests]').isVisible());
 for(const width of [560,520,360,260])for(const theme of ['light','dark']){
  await page.setViewportSize({width,height:1100});await page.emulateMedia({colorScheme:theme,reducedMotion:'reduce'});await mode(width>=520?'full':'mini');
  for(const status of ['succeeded','running','cancelled']){await task(status,'compilation');await fit();}
  assert(!await card.evaluate(n=>n.scrollWidth>n.clientWidth+1));await card.screenshot({path:output+`/B-${width}-${theme}.png`});
 }
 await page.setViewportSize({width:520,height:1100});await page.evaluate(()=>document.documentElement.style.setProperty('--bootstrap-text-scale','1.5'));await mode('full');await task('running');await fit();await page.evaluate(()=>document.documentElement.style.removeProperty('--bootstrap-text-scale'));
 await task('succeeded');await mode('extended');assert.equal(await card.getByRole('tab').count(),3);await card.getByRole('tab',{name:'Тесты',exact:true}).click();assert.equal(await card.getByRole('searchbox').count(),0);assert.equal(await card.locator('textarea').count(),0);assert(await card.getByText('Окружение',{exact:true}).isVisible());
 await page.screenshot({path:output+'/B-extended.png'});assert.deepEqual(errors,[]);console.log(JSON.stringify({passed:true,cases:'target launch, states, failure acknowledgement, progress width, 4 widths, themes, text scaling',screenshots:output}));
}finally{await browser.close();server.close();}
