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
const normal={id:'pipeline.123',scopeID:'fixture:272:1',checkout:'/fixture',pipelineID:123,displayID:'#123',branch:'feature/me/CI-123-compact-panel',status:'running',createdAt:startedAt,startedAt,duration:120,runningJobs:['ui-tests-functional-ios-iPad'],completed:4,total:8,complete:true,waitingForManual:false,updatedAt:now.toISOString(),stale:false};
const worst={...normal,checkout:'/MobilePlatformInfrastructure',branch:'feature/infrastructure/dependency-registry-bootstrap-diagnostics',runningJobs:['functional-tests-iPad-simulator-dependency-registry-recovery'],completed:10001,total:20002};
const second={...normal,id:'pipeline.122',pipelineID:122,displayID:'#122',status:'success',runningJobs:[],completed:8};
try{
 const page=await browser.newPage({viewport:{width:440,height:1050}}),errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);await page.waitForFunction(()=>!!window.mimicCIFixture);
 const card=page.locator('.panel-block[data-block="ci"]'),summary=card.locator(':scope > .block-summary');
 const set=value=>page.evaluate(value=>window.mimicCIFixture.set(value),value);
 const runs=values=>page.evaluate(values=>window.mimicCIFixture.setRuns(values),values);
 const mode=value=>page.evaluate(value=>window.mimicCIFixture.mode(value),value);
 for(const width of [360,440,480,520])for(const colorScheme of ['light','dark'])for(const reducedMotion of ['reduce','no-preference'])for(const contrast of ['more','no-preference']){
  await page.setViewportSize({width,height:1050});await page.emulateMedia({colorScheme,reducedMotion,contrast});await runs([worst,second]);
  for(const size of ['mini','full']){
   await mode(size);const count=size==='full'&&width>=480?2:1;assert.equal(await summary.locator('.ci-run').count(),count);
   const progress=summary.locator('.ci-compact-progress').first();assert.equal(await progress.getAttribute('aria-valuenow'),'50');assert.equal(Math.round((await progress.boundingBox()).height),6);
   assert.equal(await summary.locator('.ci-compact-count').first().innerText(),'10001/20002');assert.equal(await summary.locator('.ci-compact-branch').first().getAttribute('title'),worst.branch);
   assert.equal(Math.round((await card.boundingBox()).height),160);assert(await card.evaluate(node=>node.scrollWidth<=node.clientWidth+1));
   assert(await summary.evaluate(node=>node.getBoundingClientRect().bottom<=node.parentElement.getBoundingClientRect().bottom-10));
   const footers=await summary.locator('.ci-run-footer').evaluateAll(nodes=>nodes.map(node=>({bottom:node.getBoundingClientRect().bottom,runBottom:node.parentElement.getBoundingClientRect().bottom,top:node.getBoundingClientRect().top,branchBottom:node.parentElement.querySelector('.ci-compact-branch').getBoundingClientRect().bottom})));
   for(const footer of footers){assert(Math.abs(footer.bottom-footer.runBottom)<1,JSON.stringify({width,colorScheme,reducedMotion,contrast,size,footer}));assert(footer.top>=footer.branchBottom+3);}
   if(count===2)assert(Math.abs(footers[0].bottom-footers[1].bottom)<1);
   if(reducedMotion==='reduce')assert.equal(await progress.locator('div').evaluate(node=>getComputedStyle(node).transitionDuration),'0s');
  }
  if(width===520&&reducedMotion==='reduce'&&contrast==='no-preference')await page.screenshot({path:`${output}/ci-${colorScheme}.png`});
 }
 await mode('mini');await set({...normal,runningJobs:['first','second']});assert.equal(await summary.locator('.ci-compact-current').getAttribute('title'),'first\nsecond');
 await set({...worst,startedAt:'2025-01-15T11:15:00Z',duration:999999,complete:false,stale:true});
 assert.equal(await summary.locator('.ci-compact-progress').getAttribute('aria-valuenow'),null);assert.equal(await summary.locator('.ci-compact-count').innerText(),'Прогресс пока недоступен');assert(await summary.locator('.ci-compact-stale').isVisible());
 assert(await summary.evaluate(node=>node.getBoundingClientRect().bottom<=node.parentElement.getBoundingClientRect().bottom-10));
 await set({...normal,status:'pending',startedAt:null,duration:null,runningJobs:[],completed:null,total:null,complete:false});assert((await summary.locator('.ci-compact-timing').innerText()).includes('—'));
 await set({...normal,status:'failed',firstFailedJob:'functional-ios-iPad',runningJobs:[],duration:123,completed:8});assert(!await summary.locator('.ci-compact-progress').isVisible());assert((await summary.locator('.ci-compact-current').innerText()).includes('functional-ios-iPad'));
 await set(null);assert.equal(await summary.innerText(),'Нет прогонов');
 await runs([normal,second]);await mode('full');
 const selectedButton=summary.locator('.ci-run').nth(1);await selectedButton.focus();await runs([second,normal]);assert.equal(await page.evaluate(()=>document.activeElement.dataset.ciIdentity),'fixture:272:1:pipeline.122');
 await runs([normal,second]);await summary.locator('.ci-run').nth(1).click();
 assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'true');await page.waitForFunction(()=>document.querySelector('.ci-inspection-body')?.textContent.includes('Fixture commit'));
 assert((await card.locator('.ci-expanded-summary').innerText()).includes('#122'));
 await runs([normal,{...second,id:'pipeline.121',pipelineID:121,displayID:'#121'}]);assert((await card.locator('.ci-expanded-summary').innerText()).includes('#122'));assert.equal(await card.locator('.ci-run-choices button').count(),3);
 await page.keyboard.press('Escape');assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'false');
 await set(normal);await card.locator('.block-title').focus();await page.keyboard.press('Enter');
 const clock=card.locator('.ci-expanded-summary .ci-compact-elapsed'),beforeClock=await clock.innerText();await page.waitForFunction(before=>document.querySelector('.ci-expanded-summary .ci-compact-elapsed')?.textContent!==before,beforeClock,{timeout:5000});assert.notEqual(await clock.innerText(),beforeClock);
 // A slow reply for A must not replace B after switching. Fixture-only transport has no real CI side effects.
 const inspect=value=>({summary:value,loadState:'loaded',jobs:[],bridges:[],commitTitle:'Details '+value.pipelineID});
 await page.evaluate(({a,b})=>{window.mimicCIFixture.details('fixture:272:1:pipeline.123',a,700);window.mimicCIFixture.details('fixture:272:1:pipeline.122',b,0);},{a:inspect(normal),b:inspect(second)});
 await runs([normal,second]);await card.locator('.ci-run-choices button').nth(1).click();await card.locator('.ci-run-choices button').nth(0).click();await card.locator('.ci-run-choices button').nth(1).click();await page.waitForFunction(()=>document.querySelector('.ci-inspection-body')?.textContent.includes('Details 122'));await page.waitForTimeout(850);assert((await card.locator('.ci-expanded-summary').innerText()).includes('#122'));assert(!await card.locator('.ci-inspection-body').innerText().then(value=>value.includes('Details 123')));
 await page.screenshot({path:`${output}/ci-details.png`});
 await page.keyboard.press('Escape');await mode('full');await page.emulateMedia({forcedColors:'active'});await set(normal);assert.equal(await summary.locator('.ci-compact-progress').getAttribute('role'),'progressbar');
 assert.deepEqual(errors,[]);console.log('PASS: CI compact/full/details; 360/440/480/520; themes, contrast, Reduce Motion; long/missing/partial/stale/terminal/empty; focus, second-run selection, retained selection and late replies');
}finally{await browser.close();server.close();}
