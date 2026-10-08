// Created by Василий Маслов on 07.10.2026.
import assert from 'node:assert/strict';
import {panelCommand} from './check-chrome-helpers.mjs';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {build}=require('esbuild');
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const sdk=`
export class App {
 constructor(){window.fixtureApp=this;window.fixtureMessages=[];window.fixtureReads=0;window.fixtureState={needsBinding:true,context:null,actions:[],tasks:[],runs:[],builds:[],queue:[],layout:{version:1,revision:0,rows:[]},workspace:{drafts:{}},jenkinsConfigured:false};}
 async connect(){}
 getHostContext(){return {};}
 getHostCapabilities(){return {};}
 async callServerTool({name}){if(name==='get_state'){window.fixtureReads++;return {content:[],structuredContent:window.fixtureState};}return {content:[],_meta:{'mimic/private':{}}};}
 async updateModelContext(){}
}
export function applyDocumentTheme(){}
export function applyHostStyleVariables(){}
export class OpenAIExtensions {
 message={send:async message=>{window.fixtureMessages.push(message);}};
 modelContext={update:async()=>{}};
}`;
const compiled=await build({entryPoints:[new URL('./panel.ts',import.meta.url).pathname],bundle:true,write:false,format:'iife',plugins:[{name:'fixture-host',setup(api){api.onResolve({filter:/^(@modelcontextprotocol\/ext-apps|@openai\/mcp-extensions\/app)$/},()=>({path:'host',namespace:'fixture'}));api.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:sdk,loader:'js'}));}}]});
const html='<main id="app"></main><script>'+compiled.outputFiles[0].text.replaceAll('</script','<\\/script')+'</script>';
const server=createServer((_,res)=>{res.setHeader('Content-Type','text/html');res.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
 const page=await browser.newPage(),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}`);
 const binding=page.getByRole('button',{name:'Подключить проект чата',exact:true});
 await binding.waitFor();
 assert.deepEqual(await page.evaluate(()=>window.fixtureMessages),[],'Opening an unbound panel must stay quiet');
 await panelCommand(page,'Обновить');
 assert.deepEqual(await page.evaluate(()=>window.fixtureMessages),[],'Refreshing must stay quiet');
 await binding.click();
 await page.waitForFunction(()=>window.fixtureMessages.length===1);
 assert.equal((await page.evaluate(()=>window.fixtureMessages))[0].content[0].text.includes('вызови open_panel с checkout'),true);
 await page.evaluate(()=>{window.fixtureState={...window.fixtureState,needsBinding:false,context:{checkoutId:'/fixture/chat',branch:'fixture',sha:'fixture',xcode:'',appleTarget:null,profileID:null,profileRevision:null}};window.fixtureApp.ontoolresult({structuredContent:window.fixtureState});});
 assert.equal(await binding.count(),0);
 await panelCommand(page,'Обновить');
 assert.equal(await page.evaluate(()=>window.fixtureMessages.length),1);
 assert.deepEqual(errors,[]);
 console.log('PASS: open/refresh stay quiet; explicit binding click sends once; bound panel hides request and stays quiet.');
}finally{await browser?.close();server.close();}
