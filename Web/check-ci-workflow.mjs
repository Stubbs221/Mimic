//
//  check-ci-workflow.mjs
//  Mimic
//
//  Created by Василий Маслов on 28.10.2026.
import assert from 'node:assert/strict';
import {readFile, mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const {chromium}=createRequire(import.meta.url)(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
const output='/private/tmp/Mimic-ci-workflow-20261028';await mkdir(output,{recursive:true});
try{
 const page=await browser.newPage({viewport:{width:520,height:1000},reducedMotion:'reduce'}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1&layout=all&data=empty`);
 await page.waitForFunction(()=>!!window.mimicBuildFixture?.workflow);
 // The data toggle exists only in this disposable preview. It never enters the shipped UI.
 await page.evaluate(()=>{
  const toggle=document.createElement('select');toggle.id='ci-fixture-data';toggle.setAttribute('aria-label','Demo data / Worst case');
  for(const [value,text] of [['demo','Demo data'],['worst','Worst case']])toggle.add(new Option(text,value));
  Object.assign(toggle.style,{position:'fixed',bottom:'12px',left:'12px',zIndex:'10000'});
  toggle.onchange=()=>window.mimicBuildFixture.workflow(toggle.value==='worst');document.body.append(toggle);
 });
 const card=page.locator('[data-block="builds"]');
 for(const width of [560,520,360,260])for(const theme of ['light','dark'])for(const worst of [false,true]){
  await page.setViewportSize({width,height:1000});await page.emulateMedia({colorScheme:theme});
  await page.evaluate(mode=>window.mimicBuildFixture.mode(mode),width>=520?'full':'mini');
  await page.selectOption('#ci-fixture-data',worst?'worst':'demo');
  await page.evaluate(worst=>window.mimicBuildFixture.workflow(worst),worst);
  const context=card.locator('.build-work-context');await context.waitFor();
  assert((await context.innerText()).includes('3c58385'));assert((await context.innerText()).includes(worst?'Claude Code':'Codex'));
  assert((await card.locator('.build-work-identity').innerText()).includes(worst?'10000':'332'));
  const cancel=card.locator('[data-build-cancel]');assert(await cancel.isVisible());
  const escaped=await card.evaluate(card=>{
   const box=card.getBoundingClientRect();
   return [...card.querySelectorAll('[data-build-cancel],[role=progressbar]')].filter(n=>{const r=n.getBoundingClientRect();return r.bottom>box.bottom+1||r.right>box.right+1||r.left<box.left-1;}).map(n=>n.outerHTML);
  });assert.deepEqual(escaped,[]);assert(!await card.evaluate(n=>n.scrollWidth>n.clientWidth+1));
  if(worst)await card.screenshot({path:`${output}/V1-${width}-${theme}.png`});
 }
 await page.setViewportSize({width:520,height:1000});await page.evaluate(()=>document.documentElement.style.setProperty('--bootstrap-text-scale','1.5'));
 await page.evaluate(()=>{window.mimicBuildFixture.mode('full');window.mimicBuildFixture.workflow(true,true);});
 assert((await card.locator('.build-case-coverage').innerText()).includes('неизвестна'));
 await page.evaluate(()=>{document.documentElement.style.removeProperty('--bootstrap-text-scale');window.mimicBuildFixture.workflow(false);});
 await card.locator('[data-build-cancel]').click();
 await page.waitForFunction(()=>document.querySelector('[data-block="builds"] [data-build-action="tests"]')?.offsetParent!==null);
 assert.deepEqual(errors,[]);console.log(JSON.stringify({passed:true,checks:'V1 context, 10000 methods, 4 widths, themes, scaling, cases unknown, compact cancel',screenshots:output}));
}finally{await browser.close();server.close();}
