// Created by Василий Маслов on 08.10.2026.
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {panelCommand} from './check-chrome-helpers.mjs';
const require=createRequire(import.meta.url);
const {build}=require('esbuild');
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const sdk=`
export class App {
 constructor(){window.fixtureApp=this;window.missing=['swiftformat'];window.calls=[];window.buildDraft={operation:'build',backend:'cli',scheme:'',configuration:'Debug',destinationID:'',testPlan:'',testTarget:null,testIdentifiers:[],workspaceTab:''};window.state={appearance:'tileGrid',needsBinding:false,context:{checkoutId:'/fixture/MobilePlatform',branch:'feature/infrastructure/dependency-registry-bootstrap-diagnostics',sha:'fixture',xcode:'/Applications/Xcode 27.0.app/Contents/Developer',appleTarget:null,profileID:null,profileRevision:null},actions:[{id:'format',title:'Format',parameters:[],presentation:'regular',remote:false}],interface:{version:1,bindings:[{role:'format',actionID:'format',fields:{}}]},tasks:[],runs:[],builds:[],queue:[],workspace:{drafts:location.pathname==='/restore'?{builds:{backend:'xcodeMCP',workspaceTab:'window',simulatorConfirmed:'true'}}:{}},jenkinsConfigured:false};}
 async connect(){} getHostContext(){return {};} getHostCapabilities(){return {};}
 async callServerTool({name,arguments:args}){
  window.calls.push({name,args});let value={};
  if(name==='get_state')value=window.state;
  if(name==='panel_build_control'){if(args.operation==='get')value={context:window.state.context,developerDirectory:window.state.context.xcode,draft:window.buildDraft};else if(args.operation==='resources')value={blocking:false};else if(args.operation==='save'){window.buildDraft=structuredClone(args.parameters);value={saved:true};}else value={id:'fixture-build'};}
  if(name==='panel_branches')value={branches:['develop','feature/test']};
  if(name==='start_build_configuration')value={status:'ready',queryID:'q',result:{context:window.state.context,cli:{schemes:['Fixture','Other'],configurations:['Debug'],destinations:args.scheme?[{id:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',name:'iPhone Fixture'}]:[],testPlans:['Smoke'],testTargets:[{name:'FixtureTests',testPlan:'Smoke'}]},xcode:{workspaces:{window:'Fixture.xcworkspace'}}}};
  if(name==='panel_get_tool_configuration'&&window.deferConfiguration){const missing=[...window.missing];await new Promise(resolve=>window.resolveConfiguration=resolve);value={missing,command:'fixture-format'};return {content:[],_meta:{'mimic/private':value}};}
  if(name==='start_build_configuration'&&window.deferCatalogue)await new Promise(resolve=>window.resolveCatalogue=resolve);
  if(name==='panel_save_workspace')value=args.workspace;if(name==='panel_get_tool_configuration')value={missing:window.missing,command:'fixture-format'};
  if(name==='build_project'||name==='run_selected_tests')value={activity:{id:'build'}};
  return name.startsWith('panel_')?{content:[],_meta:{'mimic/private':value}}:{content:[],structuredContent:value};
 }
 async updateModelContext(){} async openLink(){}
}
export function applyDocumentTheme(){} export function applyHostStyleVariables(){}
export class OpenAIExtensions {modelContext={update:async()=>{}};}
`;
const compiled=await build({entryPoints:[new URL('./panel.ts',import.meta.url).pathname],bundle:true,write:false,format:'iife',plugins:[{name:'audit-host',setup(api){api.onResolve({filter:/^(@modelcontextprotocol\/ext-apps|@openai\/mcp-extensions\/app)$/},()=>({path:'host',namespace:'fixture'}));api.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:sdk,loader:'js'}));}}]});
const bundled=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url),'utf8');
const style=bundled.match(/<style>([\s\S]*?)<\/style>/)[1];
const mock='<style>'+style+'</style><main id="app"></main><script>'+compiled.outputFiles[0].text.replaceAll('</script','<\\/script')+'</script>';
const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end((req.url.startsWith('/mock')||req.url.startsWith('/restore'))?mock:bundled);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});

try{
 const page=await browser.newPage({viewport:{width:360,height:1100}}),errors=[];
 page.setDefaultTimeout(10000);page.on('pageerror',error=>errors.push(error.message));
 await page.emulateMedia({reducedMotion:'reduce'});
 const base='http://127.0.0.1:'+server.address().port;
 await page.goto(base+'/mock');await page.getByRole('button',{name:'Локальная ветка',exact:true}).waitFor();
 // The branch picker opens immediately and reuses its controls.
 await page.getByRole('button',{name:'Локальная ветка',exact:true}).click();
 await page.getByRole('listbox',{name:'Выбрать ветку',exact:true}).waitFor();
 assert.equal(await page.locator('[data-action=branch-switch]').count(),1);
 await page.getByRole('button',{name:'Локальная ветка',exact:true}).click();
 await page.getByRole('button',{name:'Локальная ветка',exact:true}).click();
 await page.getByRole('listbox',{name:'Выбрать ветку',exact:true}).waitFor();
 assert.equal(await page.locator('[data-action=branch-switch]').count(),1);
 await page.keyboard.press('Escape');
 // Retained build controls use the native draft contract and explicit catalogue refresh.
 await page.locator('[data-block="builds"] .block-title').click();
 const buildCard=page.locator('[data-block="builds"]');
 const queriesBeforeRefresh=await page.evaluate(()=>window.calls.filter(x=>x.name==='start_build_configuration').length);
 await buildCard.locator('[data-catalogue-refresh]').click();
 const scheme=buildCard.locator('select[data-build-field="scheme"]');await scheme.selectOption('Fixture');
 const destination=buildCard.locator('select[data-build-field="destinationID"]');
 await destination.locator('option[value="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]').waitFor({state:'attached'});
 assert.equal(await page.evaluate(()=>window.calls.filter(x=>x.name==='start_build_configuration').length),queriesBeforeRefresh+2);
 await destination.selectOption('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA');
 await buildCard.getByRole('tab').first().click();await buildCard.locator('[data-build-action="build"]').click();
 await page.waitForFunction(()=>window.calls.some(x=>x.name==='panel_build_control'&&x.args.operation==='build'));
 assert.equal(await page.evaluate(()=>window.calls.find(x=>x.name==='panel_build_control'&&x.args.operation==='build').args.parameters.testPlan),'');
 await buildCard.getByRole('tab').last().click();await buildCard.locator('select[data-build-field="testTarget"]').selectOption('FixtureTests');
 await buildCard.locator('[data-build-action="tests"]').click();
 const testCall=await page.evaluate(()=>window.calls.find(x=>x.name==='panel_build_control'&&x.args.operation==='tests'));
 assert.equal(testCall.args.parameters.testPlan,'Smoke');assert.equal(testCall.args.parameters.testTarget,'FixtureTests');assert.deepEqual(testCall.args.parameters.testIdentifiers,[]);
 // A catalogue reply from the previous checkout must not re-enable a build.
 await page.evaluate(()=>window.deferCatalogue=true);
 await buildCard.locator('[data-catalogue-refresh]').click();await page.waitForFunction(()=>!!window.resolveCatalogue);
 await page.evaluate(()=>{window.previousCatalogueReply=window.resolveCatalogue;window.state.context={...window.state.context,sha:'newer'};window.fixtureApp.ontoolresult({structuredContent:window.state});});
 await page.waitForFunction(()=>window.calls.some(x=>x.name==='start_build_configuration'&&x.args.context.sha==='newer'));
 await page.evaluate(()=>window.previousCatalogueReply());
 assert(!await buildCard.locator('[data-build-action="tests"]').isEnabled(),'late catalogue cannot enable the new context');
 await page.evaluate(()=>{window.deferCatalogue=false;window.resolveCatalogue();});
 await page.waitForFunction(()=>!document.querySelector('[data-catalogue-refresh]')?.disabled);
 // Manual refresh invalidates environment readiness and ignores older in-flight replies.
 await page.locator('[data-block="builds"] .block-title').click();
 await page.evaluate(()=>window.deferConfiguration=true);
 await page.getByRole('button',{name:'SwiftFormat Форматирование Swift-кода',exact:true}).click();
 await page.waitForFunction(()=>!!window.resolveConfiguration);
 await page.evaluate(()=>{window.deferConfiguration=false;window.missing=[];});
 await panelCommand(page,'Обновить');
 await page.getByRole('button',{name:'Запустить',exact:true}).waitFor();
 await page.waitForFunction(()=>[...document.querySelectorAll('button')].some(n=>n.textContent==='Запустить'&&!n.disabled));
 await page.evaluate(()=>window.resolveConfiguration());
 await page.waitForTimeout(50);
 assert(await page.getByRole('button',{name:'Запустить',exact:true}).isEnabled(),'old missing-tool result cannot overwrite refreshed readiness');
 assert.equal(await page.evaluate(()=>window.calls.filter(x=>x.name==='panel_get_tool_configuration').length),2);
 // The legacy picker also opens once and replaces, rather than duplicates, its controls.
 await page.evaluate(()=>{window.state.appearance='legacy';window.fixtureApp.ontoolresult({structuredContent:window.state});});
 await page.locator('.branch-current').click();await page.getByRole('combobox',{name:'Локальная ветка',exact:true}).waitFor();
 await page.locator('.branch-current').click();await page.waitForFunction(()=>window.calls.filter(x=>x.name==='panel_branches').length===4);
 assert.equal(await page.locator('[data-branch-picker]').count(),1);
 assert(await page.locator('[data-branch-picker]').isVisible());
 assert(await page.locator('[data-branch-picker] button').isDisabled());
 // Switching from inline Bootstrap analysis to a build keeps the diagnostic visible.
 await page.goto(base+'/?preview=1');
 await page.getByRole('button',{name:'Передать ошибку агенту',exact:true}).click();
 assert.equal(await page.locator('.diagnostic-text:visible').count(),1);
 await page.getByRole('button',{name:'История',exact:true}).click();
 await page.locator('.item').filter({hasText:'Сборка'}).first().click();
 await page.getByRole('button',{name:'Разобрать ошибку',exact:true}).click();
 await page.locator('.diagnostic-text:visible').waitFor();
 assert.match(await page.locator('.diagnostic-text:visible').inputValue(),/Fixture: compilation failed/);
 // Approved N2 keeps labels, warning and terminal inside the narrow Bootstrap card.
 await page.evaluate(()=>{window.mimicBootstrapFixture.empty();window.mimicBootstrapFixture.mode('full');});
 const bootstrap=page.locator('[data-block=bootstrap]');
 for(const width of [320,360,440,520])for(const colorScheme of ['light','dark']){
  await page.setViewportSize({width,height:1100});await page.emulateMedia({colorScheme});
  const ios=await bootstrap.getByRole('button',{name:'iOS',exact:true}).boundingBox(),tv=await bootstrap.getByRole('button',{name:'tvOS',exact:true}).boundingBox();
  if(width<480)assert(tv.y>=ios.y+ios.height,'narrow N2 stacks platforms');else assert.equal(tv.y,ios.y);
  for(const part of await bootstrap.locator('.bootstrap-launchers button,.bootstrap-notice').all())assert(await part.evaluate(n=>n.scrollWidth<=n.clientWidth&&n.scrollHeight<=n.clientHeight),'platform and warning text fit');
  const bounds=await bootstrap.boundingBox(),terminal=await bootstrap.locator('.bootstrap-terminal-region').boundingBox();
  assert(terminal.x+terminal.width<=bounds.x+bounds.width&&terminal.y+terminal.height<=bounds.y+bounds.height);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  if(width<=360)await bootstrap.screenshot({path:`/private/tmp/Mimic-N2-${width}-${colorScheme}.png`});
 }
 assert.deepEqual(errors,[]);
 console.log('PASS: branch picker in both appearances, automatic destinations, native build draft and target scope, stale catalogue, readiness refresh/late reply, Bootstrap → build diagnostics, N2 widths/themes/text containment');
}finally{await browser.close();server.close();}
