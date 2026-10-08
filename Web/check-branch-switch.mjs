// Created by Василий Маслов on 07.10.2026.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {build} from 'esbuild';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const sdk=`
export class App {
 constructor(){window.fixtureApp=this;window.fixtureMessages=[];window.fixtureCalls=[];window.fixtureState={branchRebase:false,checkoutLocked:false,context:{checkoutId:'/fixture/project',branch:'feature/vmaslov/testflight-26.10.1-navigation-v2-profile-restoration',sha:'original',xcode:'/Applications/Xcode.app/Contents/Developer',appleTarget:null,profileID:null,profileRevision:null},actions:[],tasks:[],runs:[],builds:[],queue:[],layout:{version:1,revision:0,rows:[]},workspace:{drafts:{}},jenkinsConfigured:false};}
 async connect(){}
 getHostContext(){return {};}
 getHostCapabilities(){return {};}
 async callServerTool({name,arguments:args}){
  window.fixtureCalls.push({name,args});
  if(name==='get_state')return {content:[],structuredContent:window.fixtureState};
  let result={};
  if(name==='panel_branch_preferences')window.fixtureState.branchRebase=args.enabled;
  if(name==='panel_branches')result={branches:['develop','feature/target']};
  if(name==='panel_switch_branch'){window.fixtureState.checkoutLocked=true;window.fixtureState.branchSwitch={id:args.requestID,checkout:'/fixture/project',sourceBranch:window.fixtureState.context.branch,targetBranch:args.branch,phase:'awaitingAgent',holdsCheckout:true,delivery:'pending'};result=window.fixtureState.branchSwitch;}
  if(name==='panel_branch_delivery'){const op=window.fixtureState.branchSwitch;result=op?.delivery==='pending'?{operationID:op.id,prompt:'Resolve operation '+op.id}:null;if(result)op.delivery='reserved';}
  if(name==='panel_branch_delivery_result')window.fixtureState.branchSwitch.delivery=args.sent?'sent':'unknown';
  return {content:[],_meta:{'mimic/private':result}};
 }
 async updateModelContext(){}
 async openLink(){}
}
export function applyDocumentTheme(){}
export function applyHostStyleVariables(){}
export class OpenAIExtensions {
 message={send:async message=>{window.fixtureMessages.push(message);if(window.fixtureSendFailure)throw new Error('unknown delivery');return {};}};
 modelContext={update:async()=>{}};
}`;
const compiled=await build({entryPoints:[new URL('./panel.ts',import.meta.url).pathname],bundle:true,write:false,format:'iife',plugins:[{name:'fixture-host',setup(api){api.onResolve({filter:/^(@modelcontextprotocol\/ext-apps|@openai\/mcp-extensions\/app)$/},()=>({path:'host',namespace:'fixture'}));api.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:sdk,loader:'js'}));}}]});
const css=await readFile(new URL('./panel.css',import.meta.url),'utf8');
const html='<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+css+'</style><main id="app"></main><script>'+compiled.outputFiles[0].text.replaceAll('</script','<\\/script')+'</script>';
const server=createServer((_,res)=>{res.setHeader('Content-Type','text/html');res.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
 const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}`);
 const checkbox=page.getByRole('checkbox',{name:'Rebase на develop'});await checkbox.waitFor();
 assert.equal(await checkbox.isChecked(),false);assert.deepEqual(await page.evaluate(()=>window.fixtureMessages),[]);
 await checkbox.check();await page.waitForFunction(()=>window.fixtureState.branchRebase===true);
 assert.equal((await page.evaluate(()=>window.fixtureCalls.find(call=>call.name==='panel_branch_preferences'))).args.context.sha,'original');
 for(const width of [320,360,520]){
  await page.setViewportSize({width,height:700});
  const bounds=await checkbox.boundingBox(),settings=await page.locator('.context-bar').getByRole('button',{name:'Настройки',exact:true}).boundingBox();
  assert(bounds.x>=0&&bounds.x+bounds.width<=width);assert(settings.x>=0&&settings.x+settings.width<=width);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await page.screenshot({path:'/private/tmp/mimic-branch-'+width+'.png'});
 }
 await page.locator('.branch-current').click();
 await page.getByRole('combobox',{name:'Локальная ветка'}).selectOption('feature/target');
 await page.locator('[data-action=branch-switch]').click();
 await page.waitForFunction(()=>window.fixtureMessages.length===1);
 const message=(await page.evaluate(()=>window.fixtureMessages))[0];assert.deepEqual(message._meta['openai/message'],{target:'new',send:true});
 await page.waitForFunction(()=>window.fixtureState.branchSwitch.delivery==='sent');
 assert(await checkbox.isDisabled());
 for(let n=0;n<2;n++)await page.getByRole('button',{name:'Обновить',exact:true}).click();
 assert.equal(await page.evaluate(()=>window.fixtureMessages.length),1,'No duplicate on refresh');
 await page.evaluate(()=>{window.fixtureSendFailure=true;window.fixtureState.branchSwitch={...window.fixtureState.branchSwitch,id:'uncertain-operation',delivery:'pending'};});
 await page.getByRole('button',{name:'Обновить',exact:true}).click();await page.waitForFunction(()=>window.fixtureState.branchSwitch.delivery==='unknown');
 await page.getByRole('button',{name:'Обновить',exact:true}).click();assert.equal(await page.evaluate(()=>window.fixtureMessages.length),2,'No retry after uncertain send');
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:'/private/tmp/mimic-branch-dark.png'});
 assert.deepEqual(errors,[]);
 console.log('PASS: saved checkbox, exact checkout/request ID, long branch at 320/360/520, automatic new-chat handoff, lock, no duplicates or uncertain retries.');
}finally{await browser?.close();server.close();}
