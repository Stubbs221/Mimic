//
//  check-resource-policy.mjs
//  Mimic
//
//  Created by Василий Маслов on 21.10.2026.
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';

const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const sdk=`
export class App {
 constructor(){window.resourceCalls=[];window.resourceState={appearance:'tileGrid',needsBinding:false,context:{checkoutId:'/fixture',branch:'main',sha:'one',xcode:'/fixture/Developer',appleTarget:null,profileID:null,profileRevision:null},actions:[],tasks:[],runs:[],builds:[],queue:[],jenkinsConfigured:false};}
 async connect(){} getHostContext(){return {};} getHostCapabilities(){return {};}
 async callServerTool({name,arguments:args}){
  window.resourceCalls.push({name,args});if(window.resourceOffline&&['panel_poll_state','get_state'].includes(name))throw new Error('offline fixture');let value={};
  if(name==='get_state')value=window.resourceState;
  if(name==='panel_poll_state'&&location.pathname==='/legacy-panel')throw new Error('Unknown tool');
  if(name==='panel_poll_state')value={revision:'fixture-revision',changed:args.afterRevision!=='fixture-revision',state:window.resourceState};
  if(name==='panel_build_control'&&args.operation==='get')value={draft:{operation:'build',backend:'cli',scheme:'',configuration:'Debug',destinationID:'',testPlan:'',testIdentifiers:[],workspaceTab:''},developerDirectory:'/fixture/Developer'};
  return name.startsWith('panel_')?{content:[],_meta:{'mimic/private':value}}:{content:[],structuredContent:value};
 }
 async updateModelContext(){} async openLink(){}
}
export function applyDocumentTheme(){} export function applyHostStyleVariables(){}
export class OpenAIExtensions {modelContext={update:async()=>{}};}
`;
const panel=await build({entryPoints:['panel.ts'],bundle:true,write:false,format:'iife',plugins:[{name:'resource-host',setup(api){
 api.onResolve({filter:/^(@modelcontextprotocol\/ext-apps|@openai\/mcp-extensions\/app)$/},()=>({path:'host',namespace:'fixture'}));
 api.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:sdk,loader:'js'}));
}}]});
const controls=await build({entryPoints:['build-panel.ts'],bundle:true,write:false,format:'iife',globalName:'resourceBuild'});
const strings=JSON.parse(await readFile('ru.json','utf8'));
const wrap=script=>'<main id="app"></main><script>'+script.replaceAll('</script','<\\/script')+'</script>';
const buildFixture=wrap(controls.outputFiles[0].text+`
let holdNextGet=false,releaseHeldGet;const calls=[],context={checkoutId:'/fixture',branch:'main',sha:'one',xcode:'/fixture/Developer',profileID:null,profileRevision:null};
const draft={operation:'build',backend:'cli',scheme:'Fixture',configuration:'Debug',destinationID:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',testPlan:'',testIdentifiers:[],workspaceTab:''};
const tool=async(name,args)=>{calls.push({name,args});if(name==='panel_build_control'&&args.operation==='get'){const value={draft:{...structuredClone(draft),scheme:args.context.sha==='two'?'Current':draft.scheme},developerDirectory:context.xcode};if(holdNextGet){holdNextGet=false;return new Promise(resolve=>releaseHeldGet=()=>resolve(value));}return value;}
 if(name==='start_build_configuration')return{status:'ready',result:{context:args.context,cli:{schemes:['Fixture'],configurations:['Debug'],destinations:[{id:draft.destinationID,name:'Fixture device'}],testPlans:[]},xcode:{workspaces:{}}}};
 return {id:'fixture-operation'};};
const panel=new resourceBuild.BuildPanel(tool,key=>(${JSON.stringify(strings)})[key]??key,async()=>{},()=>{});
panel.update(document.querySelector('#app'),'full',context,[]);
window.buildResource={panel,calls,context,hold(){holdNextGet=true},release(){releaseHeldGet()}};
`);
const server=createServer((request,response)=>{response.setHeader('content-type','text/html');response.end(request.url==='/build'?buildFixture:wrap(panel.outputFiles[0].text));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,channel:'chrome'});
try {
 const page=await browser.newPage();
 await page.goto(`http://127.0.0.1:${server.address().port}/build`);
 await page.waitForFunction(()=>window.buildResource&&!window.buildResource.panel.loading);
 await page.evaluate(()=>{const f=window.buildResource;for(let i=0;i<30;i++)f.panel.update(document.querySelector('#app'),'full',{...f.context},[]);});
 assert.equal(await page.evaluate(()=>window.buildResource.calls.filter(c=>c.name==='start_build_configuration').length),0,'mounting and redraws must not discover');
 await page.locator('[data-build-action=build]').click();
 await page.waitForFunction(()=>window.buildResource.calls.some(c=>c.name==='panel_build_control'&&c.args.operation==='build'));
 assert.equal(await page.evaluate(()=>window.buildResource.calls.filter(c=>c.name==='start_build_configuration').length),1,'saved compact action must load once and execute directly');
 await page.evaluate(()=>{const f=window.buildResource;f.hold();f.panel.update(document.querySelector('#app'),'full',{...f.context,sha:'pending'},[]);});
 await page.waitForFunction(()=>window.buildResource.panel.loading);
 await page.evaluate(()=>{const f=window.buildResource;f.panel.update(document.querySelector('#app'),'full',{...f.context,sha:'two'},[]);});
 await page.waitForFunction(()=>!window.buildResource.panel.loading&&window.buildResource.panel.draft.scheme==='Current');
 await page.evaluate(()=>window.buildResource.release());
 assert.equal(await page.evaluate(()=>window.buildResource.panel.draft.scheme),'Current','late old-context reply must not block or replace current draft');
 assert.equal(await page.evaluate(()=>window.buildResource.calls.filter(c=>c.name==='start_build_configuration').length),1);
 await page.close();

 const state=await browser.newPage();await state.clock.install();
 await state.goto(`http://127.0.0.1:${server.address().port}/panel`);
 await state.waitForFunction(()=>window.resourceCalls?.some(c=>c.name==='get_state'));
 await state.clock.runFor(1000);
 assert.equal(await state.evaluate(()=>window.resourceCalls.filter(c=>c.name==='start_build_configuration').length),0);
 await state.clock.runFor(30000);
 await state.waitForFunction(()=>window.resourceCalls.some(c=>c.name==='panel_poll_state'));
 await state.evaluate(()=>{window.resourceOriginalControl=document.querySelector('.build-card-controls');});
 await state.clock.runFor(60000);assert.equal(await state.evaluate(()=>window.resourceOriginalControl===document.querySelector('.build-card-controls')),true,'unchanged snapshot must retain controls');
 assert.equal(await state.evaluate(()=>window.resourceCalls.filter(c=>c.name==='get_state').length),1,'unchanged polls must not fetch a full legacy snapshot');
 await state.evaluate(()=>{window.resourceOffline=true;});await state.clock.runFor(31000);
 await state.waitForFunction(text=>document.querySelector('.error')?.textContent.includes(text),strings.stale);
 await state.evaluate(()=>{window.resourceOffline=false;});await state.clock.runFor(31000);
 await state.waitForFunction(text=>![...document.querySelectorAll('.error')].some(e=>e.textContent.includes(text)),strings.stale);
 await state.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});Object.defineProperty(document,'visibilityState',{configurable:true,get:()=> 'hidden'});document.dispatchEvent(new Event('visibilitychange'));});
 const count=await state.evaluate(()=>window.resourceCalls.length);
 await state.clock.runFor(120000);
 assert.equal(await state.evaluate(()=>window.resourceCalls.length),count,'hidden panel must stop requests');
 await state.close();
 const legacy=await browser.newPage();await legacy.clock.install();
 await legacy.goto(`http://127.0.0.1:${server.address().port}/legacy-panel`);
 await legacy.waitForFunction(()=>window.resourceCalls?.some(c=>c.name==='get_state'));
 await legacy.clock.runFor(31000);
 await legacy.waitForFunction(()=>window.resourceCalls.filter(c=>c.name==='get_state').length===2);
 await legacy.clock.runFor(31000);
 await legacy.waitForFunction(()=>window.resourceCalls.filter(c=>c.name==='get_state').length===3);
 assert.equal(await legacy.evaluate(()=>window.resourceCalls.filter(c=>c.name==='panel_poll_state').length),1,'old helper must fall back after a plain host rejection');
 await legacy.close();
 console.log('PASS: cold/redrawn cards do not discover, saved action executes directly, revision polling skips legacy snapshots, hidden panel stops requests, old helper fallback');
} finally {await browser.close();server.close();}
