// Created by Василий Маслов on 16.10.2026.
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const profile=process.env.MIMIC_SERVICE_MANIFEST?JSON.parse(await readFile(process.env.MIMIC_SERVICE_MANIFEST,'utf8')):{serviceTools:[{id:'fixture',title:'Service fixture',actions:[{id:'create',title:'Create',hint:'Fixture',usesUID:true,returnsUID:false,variants:[{id:'default',title:'Default',fields:[{id:'phone',title:'Phone',kind:'text',required:false,defaultValue:'',advanced:false,secret:false},{id:'app_version',title:'Version',kind:'integer',required:true,defaultValue:'',advanced:true,secret:false,source:'appVersion'}]}]}]}]},definition=profile.serviceTools[0];
const catalog={id:definition.id,title:definition.title,actions:definition.actions.map(a=>({...a,variants:a.variants.map(v=>({id:v.id,title:v.title,fields:v.fields}))}))};
const bundle=await build({entryPoints:['service-tool.ts'],bundle:true,write:false,format:'iife',globalName:'fixtureModule'});
const strings=JSON.parse(await readFile('ru.json','utf8')),tokens=JSON.parse(await readFile('../Sources/MimicCore/Resources/panel-design-tokens.json','utf8'));
const variables=Object.entries(tokens.palettes.light).map(([k,v])=>`--mimic-${k}:${v}`).join(';');
const css=(await Promise.all(['panel.css','themes/retro-common.css','themes/windows95.css','themes/windows-xp.css'].map(p=>readFile(p,'utf8')))).join('\n');
const html=`<!doctype html><meta charset=utf-8><style>:root{${variables}}body{padding:16px;font-family:-apple-system,sans-serif}#tile{box-sizing:border-box;width:258px;height:160px}#tile input,#tile select{box-sizing:border-box}</style><style>${css}</style><section class="card panel-block mini" id=tile><button class=block-title>Service fixture</button><div class=block-summary id=host></div></section><nav><button id=normal>Demo data</button><button id=worst>Worst case</button></nav><script>${bundle.outputFiles[0].text}</script><script>
const t=k=>(${JSON.stringify(strings)})[k]??k,definition=${JSON.stringify(catalog)};
let calls=[],state={uid:'123',drafts:{},recent:[{uid:'123',contact:'+79000000000'}],result:null},context={namespace:'fixture',appVersion:'456',profileRevision:'r1'};
const call=async(name,args)=>{calls.push([name,args]);if(name==='panel_service_configuration')return structuredClone({tool:definition,context,state});if(name==='panel_service_save'){state={...state,uid:args.uid,drafts:args.drafts,recent:args.clearRecent?[]:state.recent};return structuredClone(state);}if(name==='panel_service_run'){const result={phase:'success',requestID:args.requestID,namespace:context.namespace,data:{uid:'456',email:'fixture@example.test',password:'fixture-password',session:'fixture-session'}};state={...state,uid:'456',result};return result;}throw Error(name);};
const panel=new fixtureModule.ServiceToolPanel(definition,call,t);panel.update(document.querySelector('#host'));
window.fixture={panel,calls,definition,change(){context={...context,namespace:'other'};state={uid:'',drafts:{},recent:[],result:null};return panel.refresh();}};
document.querySelector('#worst').onclick=()=>{context={...context,namespace:'qa-profile-preconditions-regression-'+('x'.repeat(28))};state={...state,uid:'18446744073709551615',recent:[{uid:'18446744073709551615',contact:'bartholomew.fitzgerald@northwind-industries-holdings.example.com'}]};return panel.refresh();};document.querySelector('#normal').onclick=()=>void panel.refresh();
</script>`;
const server=createServer((_q,r)=>{r.setHeader('content-type','text/html');r.end(html);});await new Promise(r=>server.listen(0,'127.0.0.1',r));
const output=process.env.MIMIC_SERVICE_OUTPUT??'/private/tmp/MimicServiceTools-20261016/web';await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,channel:'chrome'});try{
 const page=await browser.newPage({viewport:{width:650,height:650}});await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForFunction(()=>window.fixture.panel.config!==null);const initialReads=await page.evaluate(()=>window.fixture.calls.length);await page.waitForTimeout(2100);assert.equal(await page.evaluate(()=>window.fixture.calls.length),initialReads,'idle service form must not poll');
 await page.getByLabel('UID',{exact:true}).fill('321');await page.waitForTimeout(1200);assert.equal(await page.getByLabel('UID',{exact:true}).inputValue(),'321');
 await page.getByRole('button',{name:strings['service.run'],exact:true}).click();await page.waitForFunction(()=>window.fixture.panel.result?.phase==='success');
 await page.getByRole('button',{name:strings['service.result'],exact:true}).click();assert.equal(await page.locator('dialog pre').textContent().then(s=>s.includes('fixture-session')),false);
 await page.locator('dialog input[type=checkbox]').check();assert.equal(await page.locator('dialog pre').textContent().then(s=>s.includes('fixture-session')),true);await page.locator('dialog button').first().click();
 let count=0;for(const theme of ['tileGrid','legacy','windows95','windowsXP'])for(const width of [258,528])for(const darkness of ['light','dark'])for(const action of catalog.actions){
  await page.evaluate(({theme,width,action,darkness})=>{document.documentElement.dataset.theme=darkness;document.documentElement.dataset.retro=String(theme==='windows95'||theme==='windowsXP');document.documentElement.dataset.appearance=theme;document.querySelector('#tile').style.width=width+'px';const p=window.fixture.panel;p.actionID=action;p.variantID=p.currentAction().variants[0].id;p.buildForm();},{theme,width,action:action.id,darkness});
  const bounds=await page.locator('.service-tool').evaluate(h=>({host:h.getBoundingClientRect().toJSON(),tile:h.closest('#tile').getBoundingClientRect().toJSON(),overflow:h.scrollWidth-h.clientWidth}));
  assert.ok(bounds.host.bottom<=bounds.tile.bottom+1,JSON.stringify({theme,width,action:action.id,bounds}));assert.ok(bounds.overflow<=1,JSON.stringify({theme,width,action:action.id,bounds}));count++;
 }
 await page.getByRole('button',{name:strings['service.extra'],exact:true}).click();await page.locator('dialog button').first().click();
 await page.evaluate(()=>window.fixture.change());await page.waitForFunction(()=>document.querySelector('.service-namespace').textContent==='other');assert.equal(await page.getByLabel('UID',{exact:true}).inputValue(),'');assert.equal(await page.getByRole('button',{name:strings['service.result'],exact:true}).isEnabled(),false);
 await page.locator('#worst').click();assert.equal(await page.locator('.service-tool').evaluate(h=>h.scrollWidth<=h.clientWidth+1),true);
 await page.locator('#tile').screenshot({path:output+'/service-mini.png'});await writeFile(output+'/result.json',JSON.stringify({result:'PASS',layouts:count,secrets:true,typing:true,namespaceIsolation:true},null,2));console.log('ServiceTool PASS: '+count+' layouts; typing, secret reveal, namespace isolation');
}finally{await browser.close();server.close();}
