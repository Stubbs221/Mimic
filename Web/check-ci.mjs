// Created by Василий Маслов on 06.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output='/private/tmp/Mimic-ci-previews';await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
const now=new Date(),startedAt=new Date(now.getTime()-120000).toISOString();
const normal={id:'pipeline.123',scopeID:'fixture:272:1',checkout:'/fixture',pipelineID:123,branch:'feature/me/CI-123-compact-panel',status:'running',createdAt:startedAt,startedAt,duration:120,runningJobs:['ui-tests-functional-ios-iPad'],completed:4,total:8,complete:true,waitingForManual:false,updatedAt:now.toISOString(),stale:false};
const worst={...normal,branch:'feature/me/'+('очень-длинная-ветка-😀'.repeat(25)),runningJobs:['ui-tests-'+('неразрывноеимяджобы'.repeat(30))],completed:10001,total:20002};
try{
 const page=await browser.newPage({viewport:{width:440,height:1050}}),errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);
 await page.waitForFunction(()=>!!window.mimicCIFixture);
 const card=page.locator('.panel-block[data-block="ci"]'),summary=card.locator(':scope > .block-summary'),progress=card.locator(':scope > .ci-compact-progress');
 const set=value=>page.evaluate(value=>window.mimicCIFixture.set(value),value);
 for(const width of [360,440,480,520])for(const colorScheme of ['light','dark'])for(const reducedMotion of ['reduce','no-preference']){
  await page.setViewportSize({width,height:1050});await page.emulateMedia({colorScheme,reducedMotion});
  await set(worst);await page.evaluate(()=>window.mimicCIFixture.mode('mini'));
  assert(await summary.isVisible());assert.equal(await progress.getAttribute('aria-valuenow'),'50');
  assert.equal(Math.round((await progress.boundingBox()).height),3);
  assert.equal(await summary.locator('.ci-compact-count').innerText(),'Завершено 10001/20002');
  assert.equal(await summary.locator('.ci-compact-branch').getAttribute('title'),worst.branch);
  assert(await summary.evaluate(node=>node.scrollWidth<=node.clientWidth+1));
  assert(await card.evaluate(node=>node.scrollWidth<=node.clientWidth+1));
  assert.equal(Math.round((await card.boundingBox()).height),170);
  assert(await page.locator('.panel-block:not([hidden]):not(.expanded)').evaluateAll(nodes=>nodes.every(node=>Math.abs(node.getBoundingClientRect().height-170)<1)));
  assert(await summary.evaluate(node=>node.getBoundingClientRect().bottom<=node.parentElement.getBoundingClientRect().bottom-3));
  if(reducedMotion==='reduce')assert.equal(await progress.locator('div').evaluate(node=>getComputedStyle(node).transitionDuration),'0s');
  if(width===520&&reducedMotion==='reduce')await page.screenshot({path:`${output}/ci-${colorScheme}.png`});
 }
 await set({...normal,runningJobs:['first','second']});assert.equal(await summary.locator('.ci-compact-current').getAttribute('title'),'first\nsecond');
 await set({...worst,startedAt:'2025-01-15T11:15:00Z',duration:999999,complete:false,stale:true});assert.equal(await progress.getAttribute('aria-valuenow'),null);
 assert.equal(await summary.locator('.ci-compact-count').innerText(),'Завершено 10001/—');assert(await summary.locator('.ci-compact-stale').isVisible());
 assert(await summary.evaluate(node=>node.getBoundingClientRect().bottom<=node.parentElement.getBoundingClientRect().bottom-3));
 await set({...normal,status:'pending',startedAt:null,duration:null,runningJobs:[],completed:null,total:null,complete:false});
 assert((await summary.locator('.ci-compact-timing').innerText()).includes('—'));
 await set({...normal,status:'failed',runningJobs:[],duration:123,completed:8});assert.equal(await progress.getAttribute('aria-valuenow'),'100');
 await set(null);assert.equal(await summary.innerText(),'Нет прогонов');assert(!await progress.isVisible());
 await set(normal);await card.locator('.block-title').focus();await page.keyboard.press('Enter');
 assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'true');assert(await card.locator('.ci-expanded-summary').isVisible());
 const clock=card.locator('.ci-expanded-summary .ci-compact-elapsed'),beforeClock=await clock.innerText();
 await page.waitForTimeout(1100);assert.notEqual(await clock.innerText(),beforeClock);
 await page.keyboard.press('Escape');assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'false');
 await summary.click();assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'true');
 await page.keyboard.press('Escape');
 for(const mode of ['mini','full','expanded']){
  await page.evaluate(mode=>window.mimicBootstrapFixture.mode(mode),mode);
  const bootstrap=page.locator('.panel-block[data-block=bootstrap]');
  assert.equal(await bootstrap.locator('.bootstrap-terminal-region').isVisible(),mode!=='mini');
  const height=(await bootstrap.boundingBox()).height;assert(mode==='expanded'?height>170:Math.abs(height-170)<1);
 }
 await page.emulateMedia({forcedColors:'active'});assert.equal(await progress.getAttribute('role'),'progressbar');
 assert.deepEqual(errors,[]);
 console.log('PASS: CI widths 360/440/480/520, themes, Reduce Motion, contrast, long values, parallel jobs, missing/partial/stale/failure/empty, progress and keyboard/click disclosure');
}finally{await browser.close();server.close();}
