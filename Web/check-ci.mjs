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
const normal={id:'pipeline.123',scopeID:'fixture:272:1',checkout:'/fixture',accountUsername:'me',gitlabURL:'https://gitlab.example.invalid/pipelines/123',pipelineID:123,displayID:'#123',branch:'feature/me/CI-123-compact-panel',status:'running',createdAt:startedAt,startedAt,duration:120,runningJobs:['ui-tests-functional-ios-iPad'],completed:4,total:8,complete:true,waitingForManual:false,updatedAt:now.toISOString(),stale:false};
const worst={...normal,checkout:'/MobilePlatformInfrastructure',branch:'feature/infrastructure/dependency-registry-bootstrap-diagnostics',runningJobs:['functional-tests-iPad-simulator-dependency-registry-recovery'],completed:10001,total:20002,failedChecks:[{id:42,name:'required-ui-tests',url:'https://gitlab.example.invalid/jobs/42'}],analysisPrompt:'Analyze exact pipeline 123 remote-sha'};
const second={...normal,id:'pipeline.122',pipelineID:122,displayID:'#122',gitlabURL:'https://gitlab.example.invalid/pipelines/122',status:'success',runningJobs:[],completed:8};
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
   const progress=summary.locator('.ci-compact-progress').first();assert.equal(await progress.getAttribute('aria-valuenow'),'50');assert.equal(Math.round((await progress.boundingBox()).height),4);
   assert.equal(await summary.locator('.ci-compact-count').first().innerText(),'10001/20002');assert.equal(await summary.locator('.ci-compact-branch').first().getAttribute('title'),worst.branch);
   assert.equal(Math.round((await card.boundingBox()).height),160);assert(await card.evaluate(node=>node.scrollWidth<=node.clientWidth+1));
   assert(await summary.evaluate(node=>node.getBoundingClientRect().bottom<=node.parentElement.getBoundingClientRect().bottom-10));
   const footers=await summary.locator('.ci-context-row').evaluateAll(nodes=>nodes.map(node=>({bottom:node.getBoundingClientRect().bottom,runBottom:node.parentElement.getBoundingClientRect().bottom,top:node.getBoundingClientRect().top,branchBottom:node.parentElement.querySelector('.ci-compact-branch').getBoundingClientRect().bottom})));
   for(const footer of footers){assert(Math.abs(footer.runBottom-footer.bottom-8)<1,JSON.stringify({width,colorScheme,reducedMotion,contrast,size,footer}));assert(footer.top>=footer.branchBottom+3);}
   if(count===2)assert(Math.abs(footers[0].bottom-footers[1].bottom)<1);
   if(reducedMotion==='reduce')assert.equal(await progress.locator('div').evaluate(node=>getComputedStyle(node).transitionDuration),'0s');
  }
  if(width===520&&reducedMotion==='reduce'&&contrast==='no-preference')await page.screenshot({path:`${output}/ci-${colorScheme}.png`});
 }
 await runs([normal,second]);await mode('full');
 const gitlab=summary.locator('.ci-gitlab').first();assert.equal(await gitlab.getAttribute('href'),normal.gitlabURL);
 const iconBox=await gitlab.boundingBox();assert.equal(iconBox.width,28);assert.equal(iconBox.height,28);
 assert(await gitlab.evaluate(node=>Array.from(node.querySelectorAll('path')).every(path=>getComputedStyle(path).fill===getComputedStyle(node).color)));
 await gitlab.evaluate(node=>node.addEventListener('click',event=>event.preventDefault(),{once:true,capture:true}));await gitlab.click();
 assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'false');
 await mode('mini');await set({...normal,runningJobs:['first','second']});assert.equal(await summary.locator('.ci-context-label').getAttribute('title'),'first\nsecond');
 await set({...worst,startedAt:'2025-01-15T11:15:00Z',duration:999999,complete:false,stale:true});
 assert.equal(await summary.locator('.ci-compact-progress').getAttribute('aria-valuenow'),null);assert.equal(await summary.locator('.ci-compact-count').innerText(),'—');assert(await summary.locator('.ci-compact-stale').isVisible());
 assert(await summary.evaluate(node=>node.getBoundingClientRect().bottom<=node.parentElement.getBoundingClientRect().bottom-10));
 await set({...normal,status:'pending',startedAt:null,duration:null,runningJobs:[],completed:null,total:null,complete:false});assert((await summary.locator('.ci-context-row .ci-compact-timing').innerText()).includes('—'));
 await set({...normal,status:'failed',firstFailedJob:'functional-ios-iPad',runningJobs:[],duration:123,completed:8});assert(!await summary.locator('.ci-compact-progress').isVisible());assert((await summary.locator('.ci-context-label').innerText()).includes('functional-ios-iPad'));
 // Completed runs keep the same insets without reserving an empty progress row.
 await set({...normal,status:'success',runningJobs:[],duration:123,finishedAt:'2025-01-15T11:17:03Z'});
 const geometry=await summary.locator('.ci-run-card').evaluate(node=>{
  const box=node.getBoundingClientRect(),heading=node.querySelector('.ci-run-heading').getBoundingClientRect(),branch=node.querySelector('.ci-compact-branch').getBoundingClientRect(),timing=node.querySelector('.ci-context-row .ci-compact-timing').getBoundingClientRect(),footer=node.querySelector('.ci-context-row').getBoundingClientRect();
  return {left:heading.left-box.left,top:heading.top-box.top,timingGap:timing.top-branch.bottom,bottom:box.bottom-footer.bottom};
 });
 assert(Math.abs(geometry.left-8)<1&&Math.abs(geometry.top-8)<1&&Math.abs(geometry.bottom-8)<1,JSON.stringify(geometry));
 assert(geometry.timingGap>=0,JSON.stringify(geometry));
 // Independent analysis captures the exact run, stays pending across polling and never opens Extended.
 await page.setViewportSize({width:520,height:1050});await page.emulateMedia({reducedMotion:'reduce'});await mode('full');
 const failedA={...normal,failedChecks:[{id:7,name:'required',url:'https://gitlab.example.invalid/jobs/7'}],analysisPrompt:'selected pipeline 123 remote-sha'};
 const failedB={...second,status:'failed',firstFailedJob:'required-b',analysisPrompt:'selected pipeline 122 remote-sha-b'};
 await runs([failedA,failedB]);await page.evaluate(()=>window.mimicCIFixture.analysis(350));
 assert.equal(await summary.locator('.ci-ai').first().evaluate(node=>getComputedStyle(node).color),await summary.locator('.ci-compact-status').first().evaluate(node=>getComputedStyle(node).color));
 assert.notEqual(await summary.locator('.ci-ai').first().evaluate(node=>getComputedStyle(node).backgroundColor),'rgba(0, 0, 0, 0)');
 const ai=summary.locator('.ci-ai').nth(1);assert.equal(Math.round((await ai.boundingBox()).height),28);
 await ai.focus();await page.keyboard.press('Enter');await page.keyboard.press('Enter');
 await runs([failedB,failedA]);
 await page.waitForFunction(()=>window.mimicCIFixture.sent()==='selected pipeline 122 remote-sha-b');
 assert.equal(await page.evaluate(()=>window.mimicCIFixture.analysisCount()),1);
 assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'false');
 await page.evaluate(()=>window.mimicCIFixture.analysis(0,true));await summary.locator('.ci-ai').first().click();
 assert((await summary.locator('.ci-ai-message').first().innerText()).includes('Не удалось'));
 await page.evaluate(()=>window.mimicCIFixture.analysis(0,false));
 await runs([normal,second]);assert.equal(await summary.locator('.ci-ai').count(),0);
 // A shared remote scope in another checkout must not inherit an in-flight button or its notice.
 await runs([failedA]);await page.evaluate(()=>window.mimicCIFixture.analysis(200));await summary.locator('.ci-ai').click();
 await runs([{...failedA,checkout:'/other-checkout'}]);assert.equal(await summary.locator('.ci-ai-message').count(),0);
 await page.waitForTimeout(250);assert.equal(await summary.locator('.ci-ai-message').count(),0);
 await page.evaluate(()=>window.mimicCIFixture.analysis(0));
 await runs([{...failedA,analysisPrompt:null},second]);await summary.locator('.ci-ai').click();
 assert((await summary.locator('.ci-ai-message').innerText()).includes('Не удалось'));
 // The context/count row precedes its progress bar and shares its horizontal edges.
 await runs([worst,second]);
 const alignment=await summary.locator('.ci-run-card').first().evaluate(node=>{const a=node.querySelector('.ci-progress-caption').getBoundingClientRect(),b=node.querySelector('.ci-compact-progress').getBoundingClientRect();return{left:a.left-b.left,right:a.right-b.right,gap:b.top-a.bottom};});
 assert(Math.abs(alignment.left)<1&&Math.abs(alignment.right)<1&&alignment.gap>=0&&alignment.gap<=4,JSON.stringify(alignment));
 await page.screenshot({path:output+'/ci-analysis-full.png'});
 await page.evaluate(()=>document.documentElement.style.fontSize='20px');await page.waitForFunction(()=>document.documentElement.dataset.largeText==='true');
 await runs([worst]);assert(await card.evaluate(node=>node.scrollWidth<=node.clientWidth+1));
 const big=await summary.locator('.ci-context-row').evaluate(node=>{const r=node.getBoundingClientRect();return Array.from(node.children).every(c=>{const b=c.getBoundingClientRect();return b.left>=r.left-1&&b.right<=r.right+1&&b.bottom<=r.bottom+1;});});assert(big);
 await card.screenshot({path:output+'/ci-analysis-large.png'});
 await page.evaluate(()=>document.documentElement.style.fontSize='13px');await page.waitForFunction(()=>document.documentElement.dataset.largeText!=='true');
 await set(null);assert.equal(await summary.innerText(),'Нет прогонов');
 await page.evaluate(()=>window.mimicCIFixture.configured(false));
 for(const width of [360,520])for(const colorScheme of ['light','dark'])for(const size of ['mini','full','expanded']){
  await page.setViewportSize({width,height:1050});await page.emulateMedia({colorScheme});await mode(size);
  const setup=card.locator(size==='expanded'?'.block-content .ci-setup':'.block-summary .ci-setup');
  const add=setup.getByRole('button',{name:'Добавить токен',exact:true});assert(await add.isVisible());
  const frame=await add.boundingBox(),tile=await card.boundingBox();assert(frame.x>=tile.x&&frame.x+frame.width<=tile.x+tile.width+1&&frame.y+frame.height<=tile.y+tile.height+1,JSON.stringify({width,colorScheme,size,frame,tile}));
  await add.click();assert.equal(await page.evaluate(()=>window.mimicCIFixture.lastSetup()),'credentials');
  assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),String(size==='expanded'));
  await page.screenshot({path:`${output}/ci-setup-${width}-${colorScheme}-${size}.png`});
 }
 await page.evaluate(()=>window.mimicCIFixture.configured(true));await mode('mini');
 assert.equal(await card.locator('.block-summary .ci-setup').count(),0);
 assert.equal(await summary.innerText(),'Нет прогонов');

 await runs([normal,second]);await mode('full');
 const selectedButton=summary.locator('.ci-run').nth(1);await selectedButton.focus();await runs([second,normal]);assert.equal(await page.evaluate(()=>document.activeElement.dataset.ciIdentity),'fixture:272:1:pipeline.122');
 await runs([normal,second]);await summary.locator('.ci-run').nth(1).click();
 assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'true');await page.waitForFunction(()=>document.querySelector('.ci-inspection-body')?.textContent.includes('Fixture commit'));
 assert((await card.locator('.ci-expanded-summary').innerText()).includes('#122'));
 await runs([normal,{...second,id:'pipeline.121',pipelineID:121,displayID:'#121'}]);assert((await card.locator('.ci-expanded-summary').innerText()).includes('#122'));assert.equal(await card.locator('.ci-run-choices button').count(),2);
 await page.keyboard.press('Escape');assert.equal(await card.locator('.block-title').getAttribute('aria-expanded'),'false');
 await set(normal);await card.locator('.block-title').focus();await page.keyboard.press('Enter');
 const clock=card.locator('.ci-expanded-summary .ci-compact-elapsed'),beforeClock=await clock.innerText();await page.waitForFunction(before=>document.querySelector('.ci-expanded-summary .ci-compact-elapsed')?.textContent!==before,beforeClock,{timeout:5000});assert.notEqual(await clock.innerText(),beforeClock);
 // A slow reply for A must not replace B after switching. Fixture-only transport has no real CI side effects.
 const inspect=value=>({summary:value,loadState:'loaded',jobs:[],bridges:[],commitTitle:'Details '+value.pipelineID});
 await page.evaluate(({a,b})=>{window.mimicCIFixture.details('fixture:272:1:pipeline.123',a,700);window.mimicCIFixture.details('fixture:272:1:pipeline.122',b,0);},{a:inspect(normal),b:inspect(second)});
 await runs([normal,second]);for(const id of [123,122,123,122]){if(await card.locator('.ci-expanded-summary .ci-run-id').innerText()!=='#'+id)await card.locator('.ci-run-choices button[aria-label^="#'+id+' "]').click();}await page.waitForFunction(()=>document.querySelector('.ci-inspection-body')?.textContent.includes('Details 122'));await page.waitForTimeout(850);assert((await card.locator('.ci-expanded-summary').innerText()).includes('#122'));assert(!await card.locator('.ci-inspection-body').innerText().then(value=>value.includes('Details 123')));
 await page.screenshot({path:`${output}/ci-details.png`});
 await page.keyboard.press('Escape');await mode('full');await page.emulateMedia({forcedColors:'active'});await set(normal);assert.equal(await summary.locator('.ci-compact-progress').getAttribute('role'),'progressbar');
 await page.emulateMedia({forcedColors:'none'});await mode('expanded');
 const launchToggle=card.locator('.tool-choice[data-kind="uiTests"]');await launchToggle.click();
 const branchTrigger=card.locator('.ci-launch-form:not([hidden]) .ci-branch-trigger');await branchTrigger.waitFor();
 await page.waitForFunction(()=>document.querySelector('.ci-launch-form:not([hidden]) .ci-branch-trigger')?.textContent.includes('feature/mcp'));
 await branchTrigger.click();const popup=card.locator('.ci-branch-popover:popover-open'),query=popup.getByRole('searchbox');
 await page.evaluate(()=>{window.mimicCIFixture.branches('slow',['old-result'],700);window.mimicCIFixture.branches('fast',['develop']);});
 await query.fill('slow');await page.waitForTimeout(300);await query.fill('fast');
 await popup.getByRole('button',{name:'develop',exact:true}).waitFor();await page.waitForTimeout(500);
 assert.equal(await popup.getByRole('button',{name:'old-result',exact:true}).count(),0);
 assert((await branchTrigger.innerText()).includes('feature/mcp'));
 await popup.getByRole('button',{name:'develop',exact:true}).click();assert((await branchTrigger.innerText()).includes('develop'));
 await launchToggle.click();await launchToggle.click();assert((await branchTrigger.innerText()).includes('develop'));
 await branchTrigger.click();await query.press('Escape');assert.equal(await popup.count(),0);assert(await branchTrigger.evaluate(node=>document.activeElement===node));
 const disclosure=card.locator('.ci-disclosure');await disclosure.click();assert.equal(await disclosure.getAttribute('aria-expanded'),'false');
 await card.locator('.ci-expanded-summary .ci-run-id').click();assert.equal(await disclosure.getAttribute('aria-expanded'),'false');
 await disclosure.click();assert.equal(await disclosure.getAttribute('aria-expanded'),'true');
 assert.deepEqual(errors,[]);console.log('PASS: CI accent analysis action, exact frozen run, double-click protection, checkout isolation, errors, large text; independent monochrome GitLab action; disclosure-only details; remote branch selection, draft and late replies; compact/full/details; 360/440/480/520; themes, contrast, Reduce Motion; long/missing/partial/stale/terminal/empty; focus, second-run selection, retained selection and late replies');
}finally{await browser.close();server.close();}
