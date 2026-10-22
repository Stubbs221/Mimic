// Created by Василий Маслов on 16.10.2026.
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const output=process.env.MIMIC_PANEL_FIXTURE_OUTPUT??'/private/tmp/MimicCustomPanel-20261016/web';await mkdir(output,{recursive:true});
const bundle=await build({entryPoints:['profile-panel.ts'],bundle:true,write:false,format:'iife',globalName:'fixtureModule'});
const strings=JSON.parse(await readFile('ru.json','utf8')),tokens=JSON.parse(await readFile('../Sources/MimicCore/Resources/panel-design-tokens.json','utf8'));
const variables=Object.entries(tokens.palettes.light).map(([key,value])=>`--mimic-${key}:${value}`).join(';');
const css=(await Promise.all(['panel.css','themes/retro-common.css','themes/windows95.css','themes/windows-xp.css'].map(file=>readFile(file,'utf8')))).join('\n');
const html=`<!doctype html><html lang=ru><meta charset=utf-8><style>:root{${variables}}body{margin:0;padding:16px;font-family:-apple-system,BlinkMacSystemFont,sans-serif}#tile{box-sizing:border-box;width:258px;height:160px}#demo{position:fixed;bottom:0}</style><style>${css}</style><section class="card panel-block mini" id=tile data-block="profile:fixture:settings"><button class=block-title>Custom settings</button><div class=block-summary id=host></div></section><nav id=demo><button id=normal>Demo data</button><button id=worst>Worst case</button></nav><script>${bundle.outputFiles[0].text}</script><script>
const t=key=>(${JSON.stringify(strings)})[key]??key;
const definition={id:'settings',block:'profile:fixture:settings',title:'Custom settings',actionID:'settings-action',applications:[{id:'demo',title:'Demo app'}],fields:[{id:'first',title:'First ID'},{id:'second',title:'Second ID'},{id:'target',title:'Environment',pattern:'^[a-z0-9-]+$',placeholder:'Default'}]};
let saved={},actual={first:'123',second:'456',target:'testing'},revision=1,calls=[],launchFailure=false,loseReply=false,readFailure=false,processFailure=false,holdNext=false;const records=new Map(),held=[];
const devices=[{id:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',title:'iPhone Demo'}];
const call=async(name,args)=>{calls.push([name,args]);if(name==='get_task')return records.get(args.taskID);if(name!=='panel_profile_control')throw Error('unexpected tool');const p=args.parameters;if(readFailure&&p.operation==='read')throw Error('fixture read failure');let status='ready';if(!['read','catalog'].includes(p.operation)){
 if(p.expectedRevision!==String(revision)&&p.force!=='true')status='conflict';else{if(p.operation==='apply')actual=JSON.parse(p.values);if(p.operation==='reset')actual={...actual,[p.field]:''};if(p.operation==='resetAll')actual={first:'',second:'',target:''};revision++;status=launchFailure?'launchFailed':'saved';}}
 const record={id:args.requestID,status:processFailure?'failed':'succeeded',panelResult:{status,values:{...actual},revision:String(revision),devices,developerMode:true}};records.set(record.id,record);if(loseReply&&p.operation==='apply'){loseReply=false;throw Error('fixture connection lost');}if(holdNext){holdNext=false;return new Promise((resolve,reject)=>held.push({resolve:()=>resolve(record),reject}));}return record;};
const panel=new fixtureModule.ProfilePanel(definition,call,t,()=>saved,value=>saved=value);panel.update(document.querySelector('#host'),{checkoutId:'/fixture',profileRevision:'r1'});
window.fixture={panel,calls,definition,holdNext(){holdNext=true},release(index,fail=false){const reply=held[index];if(fail)reply.reject(Error('fixture stale reply'));else reply.resolve()},loseNextReply(){loseReply=true},setReadFailure(value){readFailure=value},setProcessFailure(value){processFailure=value},reload(){return panel.reloadValues()},read(){return panel.run('read')},get actual(){return actual},external(){actual={first:'777',second:'888',target:'other'};revision++;return panel.run('read')},failLaunch(){launchFailure=true},restoreLaunch(){launchFailure=false},apply(){return panel.run('apply')},reset(field){return panel.run('reset',field)},resetAll(){return panel.run('resetAll')}};
function data(worst){definition.applications[0].title=worst?'Очень длинное имя приложения 无空格🙂'.repeat(8):'Demo app';panel.application.options[0].text=definition.applications[0].title;panel.device.options[0].text=worst?'LongSimulatorNameWithoutAnySpaces'.repeat(10):'iPhone Demo';}document.querySelector('#normal').onclick=()=>data(false);document.querySelector('#worst').onclick=()=>data(true);
</script>`;
const server=createServer((_req,res)=>{res.setHeader('content-type','text/html;charset=utf-8');res.end(html);});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,channel:'chrome'});try{
 const page=await browser.newPage({viewport:{width:560,height:280}});await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForFunction(()=>!!window.fixture);await page.waitForTimeout(16000);assert.equal(await page.evaluate(()=>window.fixture.calls.length),0,'idle settings must not create tasks');assert.equal(await page.locator('.profile-panel select').count(),0);assert.equal(await page.locator('.profile-panel input').count(),3);assert.deepEqual(await page.locator('.profile-panel button').allTextContents(),[strings['customPanel.resetAll'],strings['customPanel.apply'],strings.refresh]);await page.screenshot({path:output+'/cold.png'});await page.locator('.profile-panel-refresh').click();await page.waitForFunction(()=>window.fixture?.panel.revision==='1');
 await page.getByLabel('First ID',{exact:true}).fill('0');assert.equal(await page.getByRole('button',{name:strings['customPanel.apply'],exact:true}).isEnabled(),false);
 await page.getByLabel('First ID',{exact:true}).fill('321');await page.getByLabel('Environment',{exact:true}).fill('staging');await page.getByRole('button',{name:strings['customPanel.apply'],exact:true}).click();await page.waitForFunction(()=>window.fixture.actual.first==='321');
 await page.getByLabel('Second ID',{exact:true}).fill('999');await page.evaluate(()=>window.fixture.reset('first'));assert.equal(await page.getByLabel('Second ID',{exact:true}).inputValue(),'999');assert.equal(await page.evaluate(()=>window.fixture.actual.second),'456');
 await page.evaluate(()=>window.fixture.external());assert.equal(await page.getByLabel('Second ID',{exact:true}).inputValue(),'999');assert.equal(await page.getByRole('button',{name:strings['customPanel.apply'],exact:true}).isEnabled(),false);
 await page.getByRole('button',{name:strings.refresh,exact:true}).click();await page.waitForFunction(()=>!window.fixture.panel.conflict);await page.getByLabel('Second ID',{exact:true}).fill('999');await page.getByRole('button',{name:strings['customPanel.apply'],exact:true}).click();await page.waitForFunction(()=>window.fixture.actual.second==='999');
 await page.evaluate(()=>window.fixture.resetAll());assert.deepEqual(await page.evaluate(()=>window.fixture.actual),{first:'',second:'',target:''});
 await page.evaluate(()=>window.fixture.failLaunch());await page.getByLabel('First ID',{exact:true}).fill('123');await page.evaluate(()=>window.fixture.apply());assert.equal(await page.getByRole('button',{name:strings['customPanel.apply'],exact:true}).isVisible(),true);
 await page.evaluate(()=>window.fixture.restoreLaunch());await page.getByRole('button',{name:strings['customPanel.apply'],exact:true}).click();
 // A lost mutation reply is reconciled by ID, without another submission.
 await page.getByLabel('First ID',{exact:true}).fill('333');await page.evaluate(()=>window.fixture.loseNextReply());await page.evaluate(()=>window.fixture.apply());
 await page.getByLabel('First ID',{exact:true}).fill('444');
 const submissions=await page.evaluate(()=>window.fixture.calls.filter(([name])=>name==='panel_profile_control').length);
 await page.evaluate(()=>window.fixture.read());assert.equal(await page.evaluate(()=>window.fixture.calls.filter(([name])=>name==='panel_profile_control').length),submissions);
 assert.equal(await page.getByLabel('First ID',{exact:true}).inputValue(),'444');assert.equal(await page.evaluate(()=>window.fixture.panel.baseline.first),'333');assert.equal(await page.evaluate(()=>window.fixture.panel.activeRequest),null);
 // Failed reloads retain the draft; a confirmed reload replaces it.
 await page.getByLabel('First ID',{exact:true}).fill('444');await page.evaluate(()=>window.fixture.setReadFailure(true));await page.evaluate(()=>window.fixture.reload());
 assert.equal(await page.getByLabel('First ID',{exact:true}).inputValue(),'444');await page.evaluate(()=>window.fixture.setReadFailure(false));await page.evaluate(()=>window.fixture.reload());
 assert.equal(await page.getByLabel('First ID',{exact:true}).inputValue(),'333');
 // A saved-looking payload from a failed process is not accepted as confirmation.
 await page.getByLabel('First ID',{exact:true}).fill('555');await page.evaluate(()=>window.fixture.setProcessFailure(true));await page.evaluate(()=>window.fixture.apply());
 assert.equal(await page.evaluate(()=>window.fixture.panel.baseline.first),'333');assert.equal(await page.evaluate(()=>window.fixture.panel.notice),strings['customPanel.failed']);
 await page.evaluate(()=>window.fixture.setProcessFailure(false));await page.evaluate(()=>window.fixture.reload());
 await page.evaluate(()=>window.fixture.definition.fields[2].pattern='[a-z]+');await page.getByLabel('Environment',{exact:true}).fill('testing123');
 assert.equal(await page.getByRole('button',{name:strings['customPanel.apply'],exact:true}).isEnabled(),false);
 await page.evaluate(()=>window.fixture.definition.fields[2].pattern='^[a-z0-9-]+$');await page.getByLabel('Environment',{exact:true}).fill('testing');
 // A response from an old context cannot clear a newer request's observation state.
 await page.evaluate(()=>{window.fixture.holdNext();window.fixture.oldRead=window.fixture.read()});
 const oldID=await page.evaluate(()=>window.fixture.panel.activeRequest.id);
 await page.evaluate(()=>{window.fixture.holdNext();window.fixture.panel.update(document.querySelector('#host'),{checkoutId:'/other-fixture',profileRevision:'r2'});if(window.fixture.panel.activeRequest!==null)throw Error('context change must not submit a request');window.fixture.newRead=window.fixture.panel.start()});
 const newID=await page.evaluate(()=>window.fixture.panel.activeRequest.id);assert.notEqual(newID,oldID);
 await page.evaluate(async()=>{window.fixture.release(0,true);await window.fixture.oldRead});
 assert.equal(await page.evaluate(()=>window.fixture.panel.activeRequest.id),newID);
 await page.evaluate(()=>window.fixture.release(1));await page.waitForFunction(()=>!window.fixture.panel.pending);
 let count=0;for(const theme of ['tileGrid','legacy','windows95','windowsXP'])for(const width of [258,528])for(const worst of [false,true]){
  await page.evaluate(({theme,width})=>{document.documentElement.dataset.appearance=theme;document.querySelector('#tile').style.width=width+'px';document.querySelector('#tile').classList.toggle('mini',width===258);},{theme,width});await page.locator(worst?'#worst':'#normal').click();
  const bounds=await page.locator('.profile-panel').evaluate(host=>{const rect=host.getBoundingClientRect();return{right:rect.right,bottom:rect.bottom,tile:host.closest('#tile').getBoundingClientRect().toJSON(),overflow:host.scrollWidth-host.clientWidth};});
  assert.ok(bounds.right<=bounds.tile.right+1);assert.ok(bounds.bottom<=bounds.tile.bottom+1,JSON.stringify({theme,width,bounds}));assert.ok(bounds.overflow<=1);count++;
  if(!worst)await page.locator('#tile').screenshot({path:output+'/'+theme+'-'+width+'.png'});
 }
 await writeFile(output+'/result.json',JSON.stringify({result:'PASS',layouts:count,validation:true,partialReset:true,conflict:true,environmentReset:true,launchRetry:true,lostReplyRecovery:true,failedReloadRetainsDraft:true,failedProcessRejected:true,fullPatternValidation:true,lateContextIsolation:true},null,2));console.log('ProfilePanel PASS: '+count+' layouts, validation, partial reset, draft conflict, environment reset, launch retry, uncertain-response recovery, failed reload, failed process, full pattern validation');
}finally{await browser.close();server.close();}
