// Created by Василий Маслов on 13.10.2026.
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const output=process.env.MIMIC_WORK_OUTPUT??'/private/tmp/MimicWork02-20261019/web';await mkdir(output,{recursive:true});
const bundle=await build({entryPoints:['work-panel.ts'],bundle:true,write:false,format:'esm'});
const source=bundle.outputFiles[0].text.replace('export {','window.workModule = {');
const css=await readFile('panel.css','utf8'),strings=JSON.parse(await readFile('ru.json','utf8')),tokens=JSON.parse(await readFile('../Sources/MimicCore/Resources/panel-design-tokens.json','utf8'));
const theme=values=>Object.entries(values).map(([k,v])=>`--mimic-${k}:${typeof v==='number'?v+'px':v}`).join(';');
const retroCSS=(await Promise.all(['retro-common','windows95','windows-xp'].map(name=>readFile('themes/'+name+'.css','utf8')))).join('\n');
const html=`<!doctype html><html lang=ru><meta charset=utf-8><style>:root{${theme(tokens.palettes.light)};${theme(tokens.metrics)}}:root[data-theme=dark]{${theme(tokens.palettes.dark)}}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:16px;background:var(--mimic-paper);color:var(--mimic-ink)}#fixture{position:fixed;bottom:0;background:var(--mimic-paper);padding:8px}#card{width:258px;box-sizing:border-box;max-width:100%}</style><style>${css}\n${retroCSS}</style><div id=app><section id=card class="panel-block card mini" data-block=workItem><div id=host class=block-summary></div></section></div><nav id=fixture><button data-case=demo>Demo data</button><button data-case=worst>Worst case</button><button data-case=empty>Empty</button><button data-case=one>One</button><button data-case=huge>1,000 rows</button></nav><script>${source}</script><script>
const t=k=>(${JSON.stringify(strings)})[k]??k;
const context={checkoutId:'/fixture',branch:'feature/DEMO-248',profileRevision:'fixture'};
const demo={phase:'ready',candidates:['DEMO-248'],stale:false,manual:false,fetchedAt:'2026-10-13T08:00:00Z',issue:{key:'DEMO-248',title:'Восстановить позицию списка при возврате',status:'В работе',url:'https://example.invalid/browse/DEMO-248',description:'Возврат сохраняет позицию списка и выбранный элемент.',requirements:{},documents:[{id:'1',title:'Навигация и возврат',url:'https://example.invalid/page/1'},{id:'2',title:'Критерии проверки',url:'https://example.invalid/page/2'}],incomplete:false}};
let snapshot=demo,calls=[],releasePage;Object.defineProperty(navigator,'clipboard',{value:{writeText:async value=>calls.push(['copy',value])}});const send=async value=>calls.push(['send',value]);
const tool=async(name,args)=>{calls.push([name,args]);if(name==='panel_work_report')return{text:'Не проверено: критерии приёмки.',evidence:[{id:'build:1',title:'Tests',result:'incomplete'}]};if(name==='panel_work_search')return{issues:[demo.issue]};if(name==='panel_work_page')return await new Promise(r=>releasePage=r);return snapshot;};
const panel=new window.workModule.WorkPanel(tool,t,async value=>calls.push(['open',value]),send),host=document.querySelector('#host');
window.update=(data,full=false)=>{snapshot=data;document.querySelector('#card').style.width=full?'488px':'238px';document.querySelector('#card').classList.toggle('mini',!full);panel.update(host,full,data,context);};
window.changeBranch=()=>{context.branch='feature/DEMO-249';panel.update(host,false,demo,context);};
window.resolvePage=()=>releasePage?.({id:'1',title:'OLD DOCUMENT',content:'OLD DATA',url:'https://example.invalid/1'});
window.calls=calls;window.demo=demo;
const cases={demo,worst:{...demo,issue:{...demo.issue,key:'DEMO-'+('9'.repeat(24)),title:'👩🏽‍💻 Đặng Thị Ngọc Hân 王秀英 '+('Benachrichtigungseinstellungen'.repeat(5)),status:'Ожидает повторного подтверждения всех связанных требований',description:'<scr'+'ipt>alert(1)</scr'+'ipt> '+('Описание '.repeat(500))}},empty:{phase:'empty',candidates:[],stale:false,manual:false},one:{...demo,issue:{...demo.issue,documents:demo.issue.documents.slice(0,1)}},huge:{...demo,issue:{...demo.issue,documents:Array.from({length:1000},(_,i)=>({id:String(i),title:'Документ '+i,url:'https://example.invalid/'+i}))}}};
window.fixtureCases=cases;document.querySelectorAll('[data-case]').forEach(b=>b.onclick=()=>window.update(cases[b.dataset.case]));window.update(demo);
</script>`;
await writeFile(output+'/fixture.html',html);
const bundled=await readFile('../Sources/MimicMCP/Resources/panel.html','utf8');
const server=createServer((req,res)=>{res.setHeader('content-type','text/html;charset=utf-8');res.end(req.url?.startsWith('/bundled')?bundled:html);});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage({viewport:{width:600,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForSelector('.work-panel').catch(error=>{console.error(errors);throw error;});
 for(const appearance of ['tileGrid','legacy','windows95','windowsXP'])for(const scale of [1,2])for(const full of [false,true])for(const width of [320,600])for(const mode of ['light','dark'])for(const kind of ['demo','worst','empty','one','huge']){
  await page.setViewportSize({width,height:1000});await page.evaluate(({full,mode,kind,scale,appearance})=>{document.documentElement.dataset.appearance=appearance;document.documentElement.dataset.retro=String(appearance.startsWith('windows'));document.documentElement.style.setProperty('--bootstrap-text-scale',String(scale));document.documentElement.style.setProperty('--collapsed-card-height','160px');document.documentElement.dataset.theme=mode;document.querySelector('[data-case='+kind+']').click();window.update(window.fixtureCases[kind],full);},{full,mode,kind,scale,appearance});
  const bounds=await page.evaluate(()=>({scroll:document.querySelector('#card').scrollWidth,width:document.querySelector('#card').clientWidth,buttons:[...document.querySelectorAll('.work-panel .work-button')].map(n=>({x:n.getBoundingClientRect().x,right:n.getBoundingClientRect().right}))}));assert.equal(await page.locator('#card').evaluate(n=>n.getBoundingClientRect().height),160*scale);assert(bounds.scroll<=bounds.width+2,'card overflow '+JSON.stringify({full,width,mode,kind,bounds}));
  if(scale===1){const outside=await page.locator('#card').evaluate(card=>{const r=card.getBoundingClientRect();return [...card.querySelectorAll('.work-panel .work-button')].some(n=>{const b=n.getBoundingClientRect();return b.bottom>r.bottom||b.right>r.right;});});assert(!outside,'compact action clipped');}
  if(appearance==='tileGrid'&&scale===1&&width===600&&kind==='demo')await page.screenshot({path:output+'/'+(full?'full':'mini')+'-'+mode+'.png'});
 }
 await page.evaluate(()=>{document.documentElement.dataset.appearance='tileGrid';document.documentElement.dataset.retro='false';document.documentElement.style.setProperty('--bootstrap-text-scale','1');document.documentElement.style.setProperty('--collapsed-card-height','160px');window.update(window.demo);});await page.locator('.work-header .work-button').click();await page.getByRole('button',{name:'Черновик отчёта',exact:true}).click();await page.locator('.work-dialog textarea').fill('USER DRAFT');await page.evaluate(()=>window.update(window.demo));assert.equal(await page.locator('.work-dialog textarea').inputValue(),'USER DRAFT');await page.getByRole('button',{name:'Дополнить с агентом',exact:true}).click();assert(await page.evaluate(()=>window.calls.some(c=>c[0]==='send'&&c[1].includes('USER DRAFT'))));
 await page.getByRole('button',{name:'Закрыть',exact:true}).click();await page.getByRole('button',{name:'Документы',exact:true}).click();await page.getByRole('button',{name:'Навигация и возврат ↗',exact:true}).click();assert(await page.evaluate(()=>window.calls.some(c=>c[0]==='open'&&c[1]==='https://example.invalid/page/1')));await page.getByRole('button',{name:'Копировать ссылку · Навигация и возврат',exact:true}).click();assert(await page.evaluate(()=>window.calls.some(c=>c[0]==='copy'&&c[1]==='https://example.invalid/page/1')));await page.keyboard.press('Escape');assert.equal(await page.locator('dialog[open]').count(),0);await page.getByRole('button',{name:'Документы',exact:true}).click();await page.getByRole('button',{name:'Читать здесь',exact:true}).click();await page.getByRole('button',{name:'Навигация и возврат',exact:true}).click();await page.evaluate(()=>{window.changeBranch();window.resolvePage();});await page.waitForTimeout(100);assert.equal(await page.locator('dialog[open]').count(),0);
 // Catch cascade and focus regressions in the complete shipped document, not only the component fixture.
 const demo=await page.evaluate(()=>window.demo);
 await page.setViewportSize({width:520,height:740});
 await page.goto(`http://127.0.0.1:${server.address().port}/bundled?preview=1&appearance=tileGrid`);
 await page.waitForFunction(()=>!!window.mimicChromeFixture&&!!window.mimicDragFixture);
 for(const mode of ['light','dark'])for(const full of [true,false]){
  await page.emulateMedia({colorScheme:mode});
  await page.evaluate(({demo,full})=>{window.mimicChromeFixture.update({work:demo});window.mimicDragFixture.set({version:1,revision:0,rows:[{id:'work-geometry',slots:full?['workItem']:['workItem','ci']}]});},{demo,full});
  const card=page.locator('[data-block=workItem]'),copy=card.locator('.work-actions>.work-button').nth(0),docs=card.locator('.work-actions>.work-button').nth(1);
  await page.mouse.move(0,0);
  await page.waitForFunction(width=>document.querySelector('[data-block=workItem]').getBoundingClientRect().width===width,full?488:238);
  const metrics=await card.evaluate(card=>{const r=card.getBoundingClientRect(),title=card.querySelector('.work-title'),copy=card.querySelector('.work-actions>.work-button'),key=card.querySelector('.work-header>.work-button');return {width:r.width,height:r.height,key:key.getBoundingClientRect().width,titleY:title.getBoundingClientRect().top-r.top,titleBG:getComputedStyle(title).backgroundColor,weight:getComputedStyle(title).fontWeight,copyWidth:copy.getBoundingClientRect().width,copyHeight:copy.getBoundingClientRect().height,copyY:copy.getBoundingClientRect().top-r.top};});
  assert.equal(metrics.width,full?488:238);assert.equal(metrics.height,160);assert.equal(metrics.key,114);assert.equal(metrics.titleY,56);assert.equal(metrics.titleBG,'rgba(0, 0, 0, 0)');assert.equal(metrics.weight,'600');assert.equal(metrics.copyWidth,full?164:96);assert.equal(metrics.copyHeight,32);assert.equal(metrics.copyY,full?87:98);
  await copy.focus();await page.evaluate(demo=>window.mimicChromeFixture.update({work:demo}),demo);assert(await copy.evaluate(n=>n===document.activeElement),'polling lost keyboard target');
  await copy.evaluate(n=>n.blur());await page.mouse.move(0,0);await card.screenshot({path:output+'/bundled-'+(full?'full':'mini')+'-'+mode+'.png'});
  await docs.click();const popup=page.locator('.work-popover[open]');assert.equal(await popup.count(),1);assert.equal(await popup.evaluate(n=>n.matches(':modal')),false);
  if(full&&mode==='light')await page.screenshot({path:output+'/bundled-documents.png'});
  await page.keyboard.press('Escape');assert.equal(await popup.count(),0);assert(await docs.evaluate(n=>n===document.activeElement),'popover did not return focus');
  await docs.click();await copy.evaluate(n=>{document.querySelector('.work-popover[open]').close();n.focus();});await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));assert(await copy.evaluate(n=>n===document.activeElement),'delayed popup close stole the next keyboard target');
 }
 assert.deepEqual(errors,[]);await writeFile(output+'/result.json',JSON.stringify({result:'PASS',scenarios:320,draftPolling:'PASS',explicitAgentRequest:'PASS',lateDocument:'PASS',images:9,bundledGeometry:'PASS',retainedFocus:'PASS',anchoredPopover:'PASS'},null,2));console.log('WorkPanel PASS: 320 fixture states, including 200% text, retained report draft, explicit agent request, late-document rejection, bundled geometry, retained focus and anchored popovers');
}finally{await browser.close();server.close();}
