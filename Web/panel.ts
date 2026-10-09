// Shared appearance is private presentation metadata; task and workspace identities stay stable.
import {BuildPanel,type BuildRecord,type BuildDraft} from './build-panel';
import {resolveAppearance} from './appearance';
import {BranchSwitchPanel,type BranchOperation} from './branch-switch';
import {PanelChrome} from './panel-chrome';
import {SimulatorPanel,type Frame,type SimulatorState,type SimulatorActivity,type SimulatorSession} from './simulator';
// Created by Василий Маслов on 04.10.2026.
import { App, applyDocumentTheme, applyHostStyleVariables } from '@modelcontextprotocol/ext-apps';
import { OpenAIExtensions } from '@openai/mcp-extensions/app';
import ru from './ru.json';
import {tools,defaultFavorites,toolRoles,toolSymbols,toolForRole,validateFavorites,toolTask,elapsed,statusSymbols,type ToolID,type ToolsPreferences} from './tools';
import {renderCompactRuns,middleText,ciIdentity,type CICompactSummary} from './ci-compact';
import {PanelCIView,type CIInspection} from './ci-details';
import {catalog,standard,validate,change,remove,add,move,resize,replace,type Block,type Layout} from './layout';
import {applyRemoteDefaults} from './remote-parameters';
import {PrivateTerminal,TerminalSelection} from './terminal';
import {BootstrapTerminalPlaceholder} from './bootstrap-terminal-placeholder';
import {CardDragController,isBlockControl} from './drag-controller';

type Context={checkoutId:string;branch:string;sha:string;xcode:string;appleTarget:unknown;profileID:string|null;profileRevision:string|null};
type Action={id:string;title:string;presentation:string;remote:boolean;parameters:{id:string;title:string;kind:string;defaultValue:string;choices?:string[];required:boolean;visibleWhen?:Record<string,string>}[]};
/** Wire object order is unspecified; identity and idempotency fingerprints must be canonical. */
function stableJSON(value:unknown):string{return JSON.stringify(value,(_key,item)=>item&&typeof item==='object'&&!Array.isArray(item)?Object.fromEntries(Object.keys(item).sort().map(key=>[key,item[key]])):item)??'';}
const actionValues=new Map<string,Record<string,string>>();
const remoteFields=new Map<string,Record<string,{defaultValue:string;choices:string[]}>>();
type LocalTask={id:string;toolID?:ToolID|null;isPreview?:boolean;actionID?:string;title:string;status:string;createdAt:string;context:Context;diagnosticAvailable:boolean;canCancel:boolean;needsInput?:boolean;progress?:string|null;startedAt?:string|null;finishedAt?:string|null;error?:string|null;bootstrap?:{platform:'ios'|'tvos';phase:string;fraction:number;stages?:string[];currentStage?:string|null;completedStages?:string[]}};
type Build=LocalTask&{actionKey?:string;tracking:string;phase:string;source:string;duration?:number;parameters:{operation:string;backend:string;scheme:string;configuration:string;destinationID:string;workspaceTab:string};errorCount?:number;warningCount?:number};
type Run={id:string;actionID?:string;branch:string;plan:string;status:string;createdAt:string;updatedAt?:string;error?:string;jenkinsURL?:string;gitlabURL?:string;allureURL?:string;pipelineID?:number;sha?:string;jobs:{name:string;status:string;allowFailure:boolean;url:string}[]};
type UIBinding={role:string;actionID:string;fields:Record<string,string>};
type UIInterface={version:number;bindings:UIBinding[]};
type State={appearance?:unknown;branchRebase?:boolean;branchSwitch?:BranchOperation|null;checkoutLocked?:boolean;toolsPreferences?:ToolsPreferences;ciSummaries?:CICompactSummary[];ciSummary?:CICompactSummary|null;notices?:{id:string;taskID:string;title:string;body:string}[];layout?:Layout;workspace?:{toolSelection?:ToolID|null;toolGenerator?:'ui'|'module'|'feature'|null;expanded?:Block;selection?:string;drafts?:Record<string,Record<string,string>>};needsBinding?:boolean;queue?:LocalTask[];interface?:UIInterface|null;simulator?:SimulatorState;context:Context|null;actions:Action[];tasks:LocalTask[];builds?:Build[];runs:Run[];jenkinsConfigured:boolean;progress?:string};
type Diagnostic={task:LocalTask;text:string;truncated:boolean;outputUnavailable:boolean;analysisPrompt:string};
const t=(key:string)=>(ru as Record<string,string>)[key]??key;
const shell=document.querySelector<HTMLElement>('#app')!;
const root=document.createElement('div');
const simulatorHost=document.createElement('section');
simulatorHost.className='card simulator';
const header=document.createElement('header');
header.append(element('h1',t('title')),button(t('refresh'),()=>void refresh(true),false,'quiet'));
shell.append(header,root);
const app=new App({name:'Mimic',version:'1.2.0'},{});
const extensions=new OpenAIExtensions(app);
const preview=new URL(location.href).searchParams.get('preview')==='1';
let state:State|null=null, selection:{type:'task'|'run'|'build';id:string}|null=null;
let busy=false, error='', stale=false, branches:string[]=[], selectedBranch='', branchQuery='', plan='SMOKE';
let diagnostic:Diagnostic|null=null, fragment='', comment='', notice='';
let diagnosticSource:'history'|'bootstrap'='history';
const pendingIDs=new Map<string,string>();
function element<K extends keyof HTMLElementTagNameMap>(tag:K,text='',className=''):HTMLElementTagNameMap[K]{const node=document.createElement(tag);if(text)node.textContent=text;if(className)node.className=className;return node;}
function button(label:string,action:()=>void,disabled=false,className=''){const b=element('button',label,className);b.type='button';b.disabled=disabled;b.onclick=action;return b;}
function status(value:string){return element('span',t(value),'status '+value);}
function date(value:string){return new Date(value).toLocaleString('ru-RU',{day:'2-digit',month:'short',hour:'2-digit',minute:'2-digit'});}
function link(label:string,url?:string){if(!url)return null;try{if(new URL(url).protocol!=='https:')return null;}catch{return null;}const a=element('a',label);a.href=url;a.target='_blank';a.rel='noopener noreferrer';a.onclick=event=>{if(!preview){event.preventDefault();void app.openLink({url}).catch(showError);}};return a;}
function card(title:string){const box=element('section','','card');box.append(element('h2',title));return box;}
function showError(value:unknown){error=value instanceof Error?value.message:t('error');render();}
class ToolFailure extends Error { constructor(message:string,readonly code:string){super(message);} }
async function tool(name:string,args:Record<string,unknown>={}):Promise<any>{
 if(preview)return fixtureTool(name,args);
 const result=await app.callServerTool({name,arguments:args});
 const text=result.content.find(item=>item.type==='text')?.text??'';
 if(result.isError){const value=result.structuredContent??{message:text};throw new ToolFailure(typeof value.message==='string'?value.message:t('error'),typeof value.code==='string'?value.code:'unavailable');}
 // Every private simulator tool uses the same app-only envelope, including accepted commands.
 if(name.startsWith('simulator_ui_'))return result._meta?.['mimic/simulator'];
 if(name.startsWith('panel_'))return result._meta?.['mimic/private'];
 const value=result.structuredContent??JSON.parse(text||'{}');return ['open_panel','get_state'].includes(name)?{...value,...(result._meta?.['mimic/workspace'] as object??{})}:value;
}
function releaseRejectedRequest(key:string,error:unknown){if(error instanceof ToolFailure&&!['unavailable','unknown'].includes(error.code))pendingIDs.delete(key);}
async function refresh(recheckTools=false){try{const next=await tool('get_state') as State;if(recheckTools){toolConfigurationRevision++;toolConfigurations.clear();}accept(next);stale=false;render();void branchSwitchPanel.poll();}catch{stale=true;render();}}
function accept(next:State){if(!next||!Array.isArray(next.tasks)||!Array.isArray(next.runs))return;const old=stableJSON(state?.context),oldCheckout=state?.context?.checkoutId;state=next;for(const id of actionValues.keys())if(!next.actions.some(a=>a.id===id))actionValues.delete(id);updateSimulator();if(!selectedBranch)selectedBranch=next.context?.branch??'';if(old!==stableJSON(next.context)){if(oldCheckout!==next.context?.checkoutId){bootstrapTerminalTask=null;bootstrapFailedAttempt=null;void bootstrapTerminal?.detach();}bootstrapLaunchError='';if(diagnosticSource==='bootstrap')diagnostic=null;remoteFields.clear();buildCatalogue=null;buildValues.simulatorConfirmed='false';buildValues.workspaceTab='';buildValues.destinationID='';previews.clear();branches=[];selectedBranch=next.context?.branch??'';simulatorPanel.invalidate();void syncContext();}if(selection?.type==='task'&&!next.tasks.some(x=>x.id===selection?.id))selection=null;if(selection?.type==='run'&&!next.runs.some(x=>x.id===selection?.id))selection=null;if(selection?.type==='build'&&!next.builds?.some(x=>x.id===selection?.id))selection=null;notifyChanges(next);}
async function perform(operation:()=>Promise<void>){if(busy)return;busy=true;error='';notice='';render();try{await operation();}catch(e){showError(e);}finally{busy=false;render();}}
function selectItem(type:'task'|'run'|'build',id:string){selection={type,id};historyOpen=true;diagnostic=null;diagnosticSource='history';scheduleWorkspace();notice='';render();void syncContext();}
async function syncContext(){if(!state||preview)return;const selected=selection?.type==='build'?state.builds?.find(x=>x.id===selection?.id):selection?.type==='task'?state.tasks.find(x=>x.id===selection?.id):selection?.type==='run'?state.runs.find(x=>x.id===selection?.id):undefined;const metadata={context:state.context,selection:selection?{type:selection.type,id:selection.id,status:selected?.status}:null};try{if(extensions.modelContext)await extensions.modelContext.update({structuredContent:metadata});else await app.updateModelContext({structuredContent:metadata});}catch{/* Older clients can still use tools; selection never sends diagnostics. */}}
function cleanFragment(value:string,limit:number){const cleaned=value.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g,'').replace(/\b(glpat-[\w-]+|gh[pousr]_[\w]+|sk-[\w-]{12,}|eyJ[\w-]+\.[\w-]+\.[\w-]+)\b/g,'[REDACTED]').replace(/((?:proxy-)?authorization\s*[:=]\s*)[^\n]+/gi,'$1[REDACTED]').replace(/(\b[\w]*(?:TOKEN|PASSWORD|PASSWD|SECRET|API[_-]?KEY)\b["']?\s*[:=]\s*)(?:"[^"\n]*"|'[^'\n]*'|[^\s&,;\n]+)/gi,'$1[REDACTED]');const bytes=new TextEncoder().encode(cleaned);let start=Math.max(0,bytes.length-limit);while(start<bytes.length&&(bytes[start]&0xc0)===0x80)start++;return new TextDecoder().decode(bytes.slice(start));}
function requestID(key:string){let id=pendingIDs.get(key);if(!id){id=crypto.randomUUID();pendingIDs.set(key,id);}return id;}
async function runAction(action:Action,preserveView=false,onRequest?:(id:string)=>void){const family=toolForAction(action),current=family?currentToolTask(family):undefined;if(family&&toolBusy(family))return;await perform(async()=>{const parameters=actionValues.get(action.id)??{};const key=stableJSON([action.id,parameters,state?.context]),id=requestID(key);onRequest?.(id);try{const result=await tool(action.remote?'run_remote_action':family?'panel_run_tool':'run_local_action',{actionID:action.id,parameters,context:state?.context,requestID:id});pendingIDs.delete(key);if(!preserveView)selection={type:action.remote?'run':'task',id:result.id};await refresh();await syncContext();}catch(error){releaseRejectedRequest(key,error);throw error;}});}
function uiBinding(role:string){return state?.interface?.version===1?state.interface.bindings.find(x=>x.role===role):undefined;}
function uiAction(role:string){const binding=uiBinding(role);return state?.actions.find(x=>x.id===binding?.actionID);}
async function runRole(role:string,fields:Record<string,string>={},preserveView=false,onRequest?:(id:string)=>void){const binding=uiBinding(role),action=uiAction(role);if(!binding||!action)return;
 const values=Object.fromEntries(action.parameters.map(field=>[field.id,field.kind==='branch'&&!field.defaultValue?state?.context?.branch??'':field.defaultValue]));
 for(const [field,value] of Object.entries(fields)){const id=binding.fields[field];if(!id)throw new Error(t('noActions'));values[id]=value;}
 actionValues.set(action.id,values);await runAction(action,preserveView,onRequest);
}
async function local(action:string){const role=action.startsWith('bootstrap_')?'bootstrap':action==='full_cleanup'?'fullCleanup':'derivedDataCleanup';await runRole(role,role==='bootstrap'?{platform:action.endsWith('tvos')?'tvos':'ios',device:'true',match:'true',full:'true',dependencies:'true',uiDependencies:'false',setup:'true'}:{});}
async function reviewRole(role:string){const action=uiAction(role);if(!action)return;await perform(async()=>{const result=await tool('get_action_configuration',{actionID:action.id});if(stableJSON(result.context)!==stableJSON(state?.context))throw new Error(t('stale'));remoteFields.set(action.id,result.fields);if(role==='uiTests'){const id=uiBinding(role)?.fields.plan;if(id&&result.fields[id]?.choices?.includes(result.fields[id].defaultValue))plan=result.fields[id].defaultValue;}});}
async function remote(){await runRole('uiTests',{branch:selectedBranch,plan});}
async function search(){await perform(async()=>{const result=await tool('list_remote_branches',{query:branchQuery});branches=result.branches;if(!branches.includes(selectedBranch))selectedBranch=branches[0]??'';});}
async function analyze(id:string,inline=false){if(diagnostic?.task.id===id){diagnosticSource=inline?'bootstrap':'history';render();return;}await perform(async()=>{
 if(inline&&bootstrapFailedAttempt?.id===id){diagnostic={task:bootstrapFailedAttempt,text:bootstrapFailedAttempt.error??'',truncated:false,outputUnavailable:true,analysisPrompt:''};diagnosticSource='bootstrap';fragment=diagnostic.text;comment='';return;}
 const captured=stableJSON(state?.context),result=await tool('get_task_diagnostic',{taskID:id}) as Diagnostic;
 if(captured!==stableJSON(state?.context))return;
 diagnostic=result;diagnosticSource=inline?'bootstrap':'history';fragment=result.text;comment='';
 });}
async function send(){await perform(async()=>{if(!diagnostic||!extensions.message&&!preview)throw new Error(t('unsupported'));const task=diagnostic.task;const numbered=cleanFragment(fragment,64*1024).split('\n').map((line,i)=>`${i+1}: ${line}`).join('\n');const message=`${diagnostic.analysisPrompt.split('<diagnostic-data>')[0]||t('promptIntro')+'\n'+stableJSON(task)}\n<diagnostic-data>\n${numbered}\n</diagnostic-data>\n<user-comment>\n${cleanFragment(comment,8192)}\n</user-comment>`;if(!preview)await extensions.message!.send({role:'user',content:[{type:'text',text:message}]});else fixtureSentMessage=message;notice=t('sent');diagnostic=null;diagnosticNode=null;diagnosticNodeID=null;});}
// MARK: - Persistent configurable workspace
const banner=element('div'),contextBar=element('div','','context-bar'),contextDetail=element('details'),toolbar=element('div','','panel-toolbar'),catalogHost=element('section','','card block-catalog'),gridHost=element('div','','panel-grid'),historyHost=element('section','','card'),detailHost=element('div'),queueHost=element('p','','queue-summary');
root.append(banner,contextBar,contextDetail,toolbar,catalogHost,gridHost,queueHost,historyHost,detailHost);
let selectedTool:ToolID|null=null,toolGenerator:'ui'|'module'|'feature'='ui';
let toolsPreferences:ToolsPreferences={revision:0,favorites:[...defaultFavorites]};
let savedLayout:Layout=standard(),editLayout:Layout|null=null,expanded:Block|null=null,catalogOpen=false,historyOpen=false,settingsOpen=false,workspaceLoaded=false,saveTimer:ReturnType<typeof setTimeout>|undefined;
let layoutOrigin:Layout|null=null;
const ciView=new PanelCIView(tool,t,link);
const buildPanel=new BuildPanel(tool,t,refresh,id=>selectItem('build',id),()=>{if(state?.simulator?.visible)openBlock('simulators');});
function ciSummaries(){return state?.ciSummaries??(state?.ciSummary?[state.ciSummary]:[]);}
function openCI(summary:CICompactSummary){if(editLayout||cardDrag.session||cardDrag.saving)return;ciView.select(summary);if(expanded!=='ci')animateGrid(()=>{expanded='ci';catalogOpen=false;renderGrid();});scheduleWorkspace();}
const blockNodes=new Map<Block,{node:HTMLElement;title:HTMLButtonElement;summary:HTMLElement;content:HTMLElement;editor:HTMLElement}>();
const formNodes=new Map<string,{signature:string;node:HTMLElement;update:()=>void}>();
const previews=new Map<string,{taskID:string;fingerprint:string;plan?:{files:{path:string;exists:boolean}[];digest:string;canGenerate?:boolean}}>();
let buildValues:Record<string,string>={backend:'cli',scheme:'',configuration:'',destinationID:'',workspaceTab:'',testPlan:'',testIdentifiers:'',simulatorConfirmed:'false'};
let buildCatalogue:any=null;
const contextLabel=button('',()=>void loadBranches(),false,'branch-current'),workStatus=button('',()=>{const active=[...state!.tasks.map(t=>({...t,type:'task' as const})),...(state!.builds??[]).map(t=>({...t,type:'build' as const}))].find(t=>['running','preparing'].includes(t.status));if(active)selectItem(active.type,active.id);historyOpen=true;render();},false,'quiet');const contextSettings=button('⚙',()=>{settingsOpen=!settingsOpen;render();},false,'quiet');contextSettings.setAttribute('aria-label',t('settings'));
const branchSwitchPanel=new BranchSwitchPanel({tool,t,refresh,canSend:()=>!!extensions.message,send:prompt=>extensions.message!.send({role:'user',content:[{type:'text',text:prompt}],_meta:{'openai/message':{target:'new',send:true}}}),open:url=>app.openLink({url}),error:showError,preview});
contextBar.append(contextLabel,branchSwitchPanel.preference,contextSettings,workStatus);contextBar.after(branchSwitchPanel.status);
const chrome=new PanelChrome({t,preference:branchSwitchPanel.preference,branches:()=>void loadBranches(),switchBranch:branch=>void switchBranch(branch),refresh:()=>void refresh(true),newAction:()=>{catalogOpen=!catalogOpen;render();},history:()=>{historyOpen=!historyOpen;render();},edit:beginEdit,setup:operation=>void setup(operation),bind:()=>void perform(async()=>{if(!preview)await extensions.message!.send({role:'user',content:[{type:'text',text:t('binding.prompt')}]});notice=t('sent');}),select:activity=>{selectItem(activity.type,activity.id);detailHost.scrollIntoView({block:'start'});}});
shell.prepend(chrome.host);
let detailSignature='';let detailsTerminal:PrivateTerminal|null=null;
function currentLayout(){return cardDrag.layout??editLayout??savedLayout;}
function blockTitle(block:Block){return t('block.'+block);}
function scheduleWorkspace(){if(preview||!workspaceLoaded)return;clearTimeout(saveTimer);saveTimer=setTimeout(()=>{void tool('panel_save_workspace',{workspace:{expanded,toolSelection:selectedTool,toolGenerator,selection:selection?selection.type+':'+selection.id:null,drafts:{...Object.fromEntries(actionValues),builds:buildValues}}}).catch(showError);},350);}
let panelAppearance:'tileGrid'|'legacy'|undefined;
function installWorkspace(next:State){
 const appearance=resolveAppearance(next.appearance,panelAppearance);
 if(appearance!==panelAppearance){cardDrag.cancel();panelAppearance=appearance;document.documentElement.dataset.appearance=appearance;}
 if(appearance==='legacy'&&branchSwitchPanel.preference.parentElement!==contextBar)contextBar.insertBefore(branchSwitchPanel.preference,contextSettings);

 if(next.toolsPreferences&&next.toolsPreferences.revision>=toolsPreferences.revision)try{toolsPreferences=validateFavorites(next.toolsPreferences);}catch{/* Retain the last valid selection. */}
 if(!editLayout&&!cardDrag.session&&!cardDrag.saving&&next.layout&&next.layout.revision>=savedLayout.revision){try{savedLayout=validate(next.layout);}catch{/* Keep the last valid layout. */}}
 if(!workspaceLoaded&&next.context&&next.workspace!==undefined){workspaceLoaded=true;for(const form of formNodes.values())form.signature='';const workspace=next.workspace;expanded=workspace?.expanded??null;selectedTool=workspace?.toolSelection??null;toolGenerator=workspace?.toolGenerator??'ui';for(const [id,values]of Object.entries(workspace?.drafts??{})){if(id==='builds')buildValues={...buildValues,...values,simulatorConfirmed:'false'};else if(next.actions.some(a=>a.id===id))actionValues.set(id,Object.fromEntries(Object.entries(values).filter(([field])=>next.actions.find(a=>a.id===id)!.parameters.some(p=>p.id===field))));}if(workspace?.selection){const [type,...parts]=workspace.selection.split(':');if(['task','run','build'].includes(type))selection={type:type as 'task'|'run'|'build',id:parts.join(':')};}}
}
function edit(operation:(layout:Layout)=>void){if(!editLayout)return;try{animateGrid(()=>{editLayout=change(editLayout!,operation);renderGrid();});}catch(e){showError(e instanceof Error?new Error(t(e.message)):e);}}
function openBlock(block:Block){if(editLayout||cardDrag.session||cardDrag.saving)return;if(block==='utils')selectedTool=null;if(block==='generateUI')toolGenerator='ui';if(block==='generateSicilia')toolGenerator='module';if(block==='generateGalera')toolGenerator='feature';if(block==='ci'&&expanded!=='ci'&&ciSummaries()[0])ciView.select(ciSummaries()[0]);animateGrid(()=>{expanded=expanded===block?null:block;catalogOpen=false;renderGrid();});scheduleWorkspace();}
function beginEdit(){if(cardDrag.session||cardDrag.saving)return;for(const view of blockNodes.values())view.editor.dataset.layout='';layoutOrigin=structuredClone(savedLayout);editLayout=structuredClone(savedLayout);expanded=null;catalogOpen=false;render();}
async function finishEdit(){if(!editLayout)return;await perform(async()=>{const layout=await tool('panel_save_layout',{layout:editLayout,expectedRevision:layoutOrigin!.revision});savedLayout=validate(layout);editLayout=null;layoutOrigin=null;scheduleWorkspace();});}
function cancelEdit(){cardDrag.cancel();editLayout=null;layoutOrigin=null;render();}
function editMenu(block:Block){const host=element('details','','placement-menu'),summary=element('summary',t('layout.options'));host.append(summary);const list=element('div','','placement-actions');
 const size=currentLayout().rows.find(r=>r.slots.includes(block))!.slots.length;
 list.append(button(t(size===1?'layout.mini':'layout.full'),()=>edit(l=>resize(l,block,size===1?'mini':'full'))));
 const rows=currentLayout().rows,index=rows.findIndex(r=>r.slots.includes(block));
 list.append(button(t('layout.up'),()=>edit(l=>move(l,block,l.rows[index-1]?.id)),index===0),button(t('layout.down'),()=>edit(l=>move(l,block,l.rows[index+2]?.id)),index===rows.length-1));
 const replacement=element('select');replacement.setAttribute('aria-label',t('layout.replace'));replacement.append(new Option(t('layout.replace'),''));for(const kind of availableBlocks().filter(b=>!currentLayout().rows.some(r=>r.slots.includes(b))))replacement.append(new Option(blockTitle(kind),kind));replacement.onchange=()=>{if(replacement.value)edit(l=>replace(l,block,replacement.value as Block));};list.append(replacement);
 if(size===2){const join=element('select');join.setAttribute('aria-label',t('layout.join'));join.append(new Option(t('layout.join'),''));for(const row of rows.filter(r=>r.slots.length===2&&r.slots.some(x=>x===null)&&!r.slots.includes(block))){join.append(new Option(row.slots.map(b=>b?blockTitle(b):t('layout.empty')).join(' · '),row.id));}join.onchange=()=>edit(l=>move(l,block,join.value,rows.find(r=>r.id===join.value)!.slots.indexOf(null)));list.append(join);}
 list.append(button(t('layout.remove'),()=>edit(l=>remove(l,block))));host.append(list);return host;
}
function blockStatus(block:Block){
 const pending=(item:{status:string})=>['queued','preparing','running','triggering','pending'].includes(item.status);
 if(block==='builds'){const item=state?.builds?.find(pending)??state?.builds?.[0];return item?t(item.needsInput?'notification.input':item.status):t('ready');}
 if(block==='simulators')return simulatorPanel.summary();
 const roles=block==='utils'?['generateUI','generateSicilia','generateGalera','localization','protocols','format','fullCleanup','derivedDataCleanup']:block==='ci'?['uiTests','qualityGates','beta']:[block];
 const ids=new Set(state?.interface?.bindings.filter(binding=>roles.includes(binding.role)).map(binding=>binding.actionID));const items=[...(state?.tasks??[]),...(state?.runs??[])].filter(item=>item.actionID&&ids.has(item.actionID)).sort((a,b)=>b.createdAt.localeCompare(a.createdAt));const item=items.find(pending)??items[0];return item?t('needsInput'in item&&item.needsInput?'notification.input':item.status):t('ready');
}
function blockAccent(block:Block){return block==='bootstrap'?'#4F7CAC':block==='builds'?'#7166A5':['ci','uiTests','qualityGates','beta'].includes(block)?'#768D60':block==='simulators'?'#4F8D9E':'#438B82';}
function blockIcon(block:Block){const path=block==='bootstrap'?'<path d="m3 6 9-4 9 4v12l-9 4-9-4Z M3 6l9 4 9-4 M12 10v12 M7 4l10 4"/>':block==='builds'?'<path d="m14 3 7 7-3 3-3-3L5 21l-3-3L13 7l-2-2Z"/>':block==='simulators'?'<rect x="6" y="2" width="12" height="20" rx="2"/><path d="M10 5h4 M11 19h2"/>':['ci','uiTests','qualityGates','beta'].includes(block)?'<path d="m12 2 3 3 4 1 1 4 2 2-2 3-1 4-4 1-3 2-3-2-4-1-1-4-2-3 2-2 1-4 4-1Z M7 12l3 3 6-6"/>':'<path d="M14 3a6 6 0 0 0-7 7L2 17l5 5 7-7a6 6 0 0 0 7-7l-4 4-4-4 4-4Z"/>';return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">'+path+'</svg>';}
function renderGrid(){
 const visualExpanded=cardDrag.session?.gesture.phase==='dragging'||expanded==='simulators'&&state?.simulator?.visible!==true?null:expanded;
 const layout=currentLayout(),rows=structuredClone(layout.rows).map(row=>({...row,slots:row.slots.map(block=>block==='simulators'&&state?.simulator?.visible!==true?null:block)})).filter(row=>row.slots.some(Boolean));gridHost.dataset.layoutRevision=String(layout.revision);if(visualExpanded&&!rows.some(r=>r.slots.includes(visualExpanded)))rows.unshift({id:'transient',slots:[visualExpanded]});
 const narrow=isCompact();gridHost.classList.toggle('single-column',narrow);const visualRow=(index:number,slot=0)=>narrow?rows.slice(0,index).reduce((total,row)=>total+row.slots.length,0)+slot+1:index+1;
 gridHost.style.gridTemplateRows=rows.flatMap(row=>Array(narrow?row.slots.length:1).fill('auto')).join(' ')+(editLayout||cardDrag.session?.gesture.phase==='dragging'?' 32px':'');
 for(const block of catalog){let view=blockNodes.get(block);if(!view){const node=element('section','','card panel-block');node.dataset.block=block;const title=button('',()=>openBlock(block),false,'block-title');const icon=element('span','','block-icon');icon.setAttribute('aria-hidden','true');icon.innerHTML=blockIcon(block);title.append(icon,element('span',blockTitle(block),'block-name'));node.onpointerdown=event=>cardDrag.start(event,block);const summary=element('div','','block-summary');const content=element('div','','block-content'),editor=element('div','','block-editor');node.append(title,summary,editor,content);view={node,title,summary,content,editor};node.onclick=event=>{if(!editLayout&&!cardDrag.session&&!cardDrag.saving&&!isBlockControl(event.target as HTMLElement))openBlock(block);};blockNodes.set(block,view);gridHost.append(node);}
  const rowIndex=rows.findIndex(r=>r.slots.includes(block)),row=rows[rowIndex];const peer=!!row&&!!visualExpanded&&row.slots.includes(visualExpanded)&&visualExpanded!==block;
  if(block==='simulators')simulatorPanel.setVisible(rowIndex>=0&&!peer&&visualExpanded===block&&!editLayout);view.node.hidden=rowIndex<0||peer;view.node.inert=peer||rowIndex<0;view.node.setAttribute('aria-hidden',String(peer||rowIndex<0));if(!row)continue;
  const isExpanded=visualExpanded===block&&!editLayout;const showFullBootstrap=block==='bootstrap'&&row.slots.length===1&&!editLayout;view.node.style.gridRow=isExpanded&&narrow&&row.slots.length===2?`${visualRow(rowIndex)} / span 2`:String(visualRow(rowIndex,row.slots.indexOf(block)));view.node.style.gridColumn=narrow||isExpanded||row.slots.length===1?'1 / -1':String(row.slots.indexOf(block)+1);view.node.classList.toggle('full-bootstrap',showFullBootstrap);view.node.style.setProperty('--block-accent',blockAccent(block));view.node.classList.toggle('expanded',isExpanded);view.node.classList.toggle('mini',row.slots.length===2&&!isExpanded);
  if(block==='simulators'){simulatorPanel.setCardHeader(isExpanded?view.title:null,()=>openBlock(block));}
  view.title.setAttribute('aria-expanded',String(isExpanded));view.title.disabled=!!editLayout;view.content.hidden=block==='bootstrap'?!!editLayout:!isExpanded&&!showFullBootstrap;view.content.inert=view.content.hidden;view.summary.hidden=block==='bootstrap'||isExpanded||showFullBootstrap||!!editLayout;view.editor.hidden=!editLayout;
  if(block==='builds'){buildPanel.update(view.summary,row.slots.length===1&&!narrow?'full':'mini',state?.context??null,(state?.builds??[]) as BuildRecord[],!!editLayout);
  }else if(block==='ci'){
   const summaries=ciSummaries();
   ciView.update(summaries,state?.context?.checkoutId,isExpanded);
   renderCompactRuns(view.summary,summaries.slice(0,row.slots.length===1&&!narrow?2:1),t,openCI);
   let project=view.title.querySelector<HTMLElement>('.ci-project');if(!project){project=element('span','','ci-project');view.title.append(project);}
   const checkout=state?.context?.checkoutId??summaries[0]?.checkout;
   project.hidden=!checkout;if(checkout){middleText(project,'· '+checkout.split('/').filter(Boolean).at(-1));project.title=checkout;}
  }else if(block==='utils'){renderToolsCompact(view.summary,row.slots.length===1&&!narrow);
  }else{view.summary.textContent=blockStatus(block);view.summary.title=view.summary.textContent;}view.title.title=blockTitle(block)+'\n'+t('layout.drag.hint');
  if(editLayout&&view.editor.dataset.layout!==stableJSON(layout)){view.editor.dataset.layout=stableJSON(layout);const grip=button(t('layout.drag'),()=>{},false,'drag-handle');grip.setAttribute('aria-label',t('layout.drag')+' '+blockTitle(block));grip.onkeydown=event=>{if(event.key==='ArrowUp'||event.key==='ArrowDown'){event.preventDefault();const index=editLayout!.rows.findIndex(r=>r.slots.includes(block));if(event.key==='ArrowUp'&&index>0)edit(l=>move(l,block,l.rows[index-1].id));if(event.key==='ArrowDown')edit(l=>move(l,block,l.rows[index+2]?.id));}};view.editor.replaceChildren(grip,editMenu(block));}
  if(block==='bootstrap'){ensureBootstrapContent(view.content);updateBootstrap(isExpanded? 'expanded':row.slots.length===1?'full':'mini',!!editLayout||view.node.hidden);}else if(isExpanded||showFullBootstrap)ensureBlockContent(block,view.content);
 }
 const hasTargets=!!editLayout||cardDrag.session?.gesture.phase==='dragging';const placeholders=hasTargets?stableJSON(layout)+narrow+!!editLayout:'';if(gridHost.dataset.placeholders!==placeholders){gridHost.dataset.placeholders=placeholders;gridHost.querySelectorAll('.empty-slot,.grid-end').forEach(n=>n.remove());
 if(hasTargets){for(const [index,row]of rows.entries())if(row.slots.length===2)for(const slot of [0,1])if(row.slots[slot]===null){const empty=element('div','','empty-slot');empty.dataset.row=row.id;empty.dataset.slot=String(slot);empty.style.gridRow=String(visualRow(index,slot));empty.style.gridColumn=narrow?'1 / -1':String(slot+1);empty.classList.toggle('drag-slot',!editLayout);const choose=element('select');choose.setAttribute('aria-label',t('layout.add'));choose.append(new Option(t('layout.add'),''));for(const kind of availableBlocks().filter(b=>!layout.rows.some(r=>r.slots.includes(b))))choose.append(new Option(blockTitle(kind),kind));choose.onchange=()=>edit(l=>{add(l,choose.value as Block,'mini');move(l,choose.value as Block,row.id,slot);});if(editLayout)empty.append(choose);gridHost.append(empty);}
  const end=element('div',t('layout.end'),'grid-end');end.style.gridColumn='1 / -1';end.style.gridRow=String(visualRow(rows.length));gridHost.append(end);
 }
 }
 for(const form of formNodes.values())form.update();
}
let keyboardMotion=false;
window.addEventListener('keydown',()=>{keyboardMotion=true;gridHost.classList.add('keyboard-motion');for(const view of blockNodes.values())view.node.style.transform='';},true);window.addEventListener('pointerdown',()=>{keyboardMotion=false;gridHost.classList.remove('keyboard-motion');},true);
/** Current visual positions retarget an unfinished transition; keyboard and Reduce Motion change instantly. */
function animateGrid(mutation:()=>void){
 const before=new Map(Array.from(blockNodes,([kind,v])=>[kind,v.node.hidden?null:v.node.getBoundingClientRect()]));mutation();
 if(keyboardMotion||matchMedia('(prefers-reduced-motion: reduce)').matches)return;
 for(const [kind,v]of blockNodes){const old=before.get(kind);if(!old||v.node.hidden||v.node.classList.contains('dragging'))continue;const next=v.node.getBoundingClientRect(),dx=Math.abs(old.width-next.width)>next.width*.1?0:old.x-next.x,dy=old.y-next.y;if(Math.abs(dx)+Math.abs(dy)<1)continue;
  v.node.style.transition='none';v.node.style.transform=`translate(${dx}px,${dy}px)`;v.node.getBoundingClientRect();v.node.style.transition='';v.node.style.transform='';
 }
}
// MARK: - Direct card rearrangement
const compactMedia=matchMedia('(max-width:479px)');
let largeText=false;
function isCompact(){return compactMedia.matches||largeText;}
const textProbe=element('span');textProbe.setAttribute('aria-hidden','true');textProbe.style.cssText='position:absolute;pointer-events:none;visibility:hidden;height:1rem;width:1rem;inset:0';document.body.append(textProbe);
new ResizeObserver(()=>{const textHeight=textProbe.getBoundingClientRect().height;document.documentElement.style.setProperty('--bootstrap-text-scale',String(Math.max(1,textHeight/13)));const next=textHeight>18;if(next!==largeText){largeText=next;document.documentElement.dataset.largeText=String(next);cardDrag.cancel();renderGrid();}}).observe(textProbe);
const cardDrag=new CardDragController({
 grid:gridHost,toolbar,nodes:blockNodes,getLayout:currentLayout,editing:()=>!!editLayout,blocked:()=>busy,
 render:renderGrid,animate:animateGrid,label:size=>t('layout.drag.'+size),
 commit:async(next,origin,editing)=>{
  if(editing){editLayout=next;return;}
  savedLayout=next;
  try{const result=validate(await tool('panel_save_layout',{layout:next,expectedRevision:origin.revision}));savedLayout=result;if(state)state.layout=result;}
  catch(failure){savedLayout=origin;if(failure instanceof ToolFailure&&failure.code==='layoutConflict'){try{const latest=await tool('get_state') as State;if(latest.layout)savedLayout=validate(latest.layout);accept(latest);}catch{/* Keep the valid pre-drag value when offline. */}error=t('layout.drag.conflict');}else error=t('layout.drag.failed');if(state)state.layout=savedLayout;}
  finally{render();}
 }
});
compactMedia.addEventListener('change',()=>{cardDrag.cancel();renderGrid();});
window.addEventListener('keydown',event=>{if(event.key==='Escape'){if(cardDrag.session){cardDrag.cancel();event.preventDefault();event.stopImmediatePropagation();}else if(editLayout)cancelEdit();else if(expanded){expanded=null;renderGrid();scheduleWorkspace();}}});
// MARK: - Bootstrap card
let bootstrapView:{host:HTMLElement;controls:HTMLElement;buttons:HTMLButtonElement[];launchers:HTMLElement;platform:HTMLElement;notice:HTMLElement;stages:HTMLElement;description:HTMLElement;result:HTMLElement;footer:HTMLElement;technical:HTMLDetailsElement;state:HTMLElement;time:HTMLElement;progress:HTMLProgressElement;actions:HTMLElement;error:HTMLElement;region:HTMLElement;overlay:HTMLButtonElement;diagnostic:HTMLElement}|null=null;
let bootstrapTerminal:PrivateTerminal|null=null;
const bootstrapPlaceholderLabels={example:t('bootstrap.terminal.example'),queued:t('bootstrap.terminal.queued'),waiting:t('bootstrap.terminal.waiting'),unavailable:t('bootstrap.terminal.unavailable')};
let bootstrapIdlePlaceholder:BootstrapTerminalPlaceholder|null=null;
let bootstrapTerminalTask:string|null=null;
let bootstrapMode='full',bootstrapHidden=false,bootstrapLaunching=false,bootstrapLaunchError='',bootstrapLaunchPlatform:'ios'|'tvos'='ios';
let bootstrapFailedAttempt:LocalTask|null=null;
let diagnosticNode:HTMLElement|null=null,diagnosticNodeID:string|null=null;
function diagnosticEditor(){
 if(diagnosticNode&&diagnosticNodeID===diagnostic?.task.id)return diagnosticNode;
 const box=element('section','','bootstrap-diagnostic'),area=element('textarea','','diagnostic-text'),note=element('textarea');
 area.value=fragment;area.setAttribute('aria-label',t('diagnostic'));area.oninput=()=>fragment=area.value;
 note.value=comment;note.placeholder=t('comment');note.setAttribute('aria-label',t('comment'));note.oninput=()=>comment=note.value;
 const submit=button(t('send'),()=>void send(),busy||!preview&&!extensions.message,'primary');submit.dataset.action='diagnostic-send';
 box.append(element('p',t('review')),area,note,button(t('task.output.copy'),()=>void navigator.clipboard.writeText(area.value)),submit,button(t('close'),()=>{diagnostic=null;diagnosticNode=null;render();}));
 diagnosticNode=box;diagnosticNodeID=diagnostic?.task.id??null;return box;
}
function ensureBootstrapContent(host:HTMLElement){
 if(bootstrapView){if(bootstrapView.host!==host){host.append(...Array.from(bootstrapView.host.children));bootstrapView.host=host;}return;}
 host.classList.add('bootstrap-content');const controls=element('div','','bootstrap-controls'),launchers=element('div','','bootstrap-launchers');
 const buttons=(['ios','tvos'] as const).map(platform=>button(platform==='ios'?'iOS':'tvOS',()=>void launchBootstrap(platform),false,'primary'));
 for(const [i,b]of buttons.entries()){b.dataset.platform=i===0?'ios':'tvos';b.title=t(i===0?'bootstrap_ios':'bootstrap_tvos');const icon=element('span','','bootstrap-platform-icon');icon.setAttribute('aria-hidden','true');icon.innerHTML=i===0?'<svg viewBox="0 0 16 16"><rect x="4.5" y="1.5" width="7" height="13" rx="1.5"/><path d="M7 3h2M7.5 12.5h1"/></svg>':'<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="9" rx="1.5"/><path d="M5 14h6M8 11.5V14"/></svg>';b.prepend(icon);launchers.append(b);}
 const platform=element('span','','bootstrap-platform'),notice=element('p','','bootstrap-notice'),stages=element('div','','bootstrap-stages'),description=element('p',t('bootstrap.preparation.description'),'bootstrap-description');
 const stateLabel=element('p','','bootstrap-state'),time=element('span','','bootstrap-time'),progress=element('progress','','bootstrap-progress');progress.max=1;
 const actions=element('div','','bootstrap-actions'),failure=element('p','','error bootstrap-error');
 notice.title=t('bootstrap.xcode.notice');
 const noticeIcon=element('span','','bootstrap-notice-icon');noticeIcon.setAttribute('aria-hidden','true');noticeIcon.innerHTML='<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6"/><path d="M8 4.5v4M8 11h.01"/></svg>';notice.append(noticeIcon,element('span',t('bootstrap.xcode.launch.notice')));
 const result=element('div','','bootstrap-result'),footer=element('div','','bootstrap-details-footer'),technical=element('details','','bootstrap-technical');technical.append(element('summary',t('task.technical')),element('p','','mono'));
 result.append(stateLabel,time,progress);controls.append(launchers,platform,actions,result,notice,stages,failure);
 const preparation=element('details','','bootstrap-preparation-reference');preparation.append(element('summary',t('bootstrap.preparation.title')),description);
 const region=element('div','','bootstrap-terminal-region'),overlay=button(t('bootstrap.error.agent'),()=>{const task=currentBootstrap();if(task){if(expanded!=='bootstrap')openBlock('bootstrap');void analyze(task.id,true);}},false,'bootstrap-agent-overlay');
 const idle=element('div','','bootstrap-terminal-idle');new TerminalSelection(idle);bootstrapIdlePlaceholder=new BootstrapTerminalPlaceholder(bootstrapPlaceholderLabels);idle.append(bootstrapIdlePlaceholder.host);region.append(idle,overlay);
 const diagnosticHost=element('div','','bootstrap-diagnostic-host');footer.append(technical);host.append(controls,region,footer,preparation,diagnosticHost);
 bootstrapView={host,controls,buttons,launchers,platform,notice,stages,description:preparation,result,footer,technical,state:stateLabel,time,progress,actions,error:failure,region,overlay,diagnostic:diagnosticHost};
}
async function launchBootstrap(platform:'ios'|'tvos'){
 const context=state?.context,action=uiAction('bootstrap');if(busy||stale||!context||!action||currentBootstrap()?.canCancel)return;
 bootstrapLaunchPlatform=platform;bootstrapLaunching=true;bootstrapLaunchError='';bootstrapFailedAttempt=null;let attempt:LocalTask|null=null;
 try{await runRole('bootstrap',{platform,device:'true',match:'true',full:'true',dependencies:'true',uiDependencies:'false',setup:'true'},true,id=>{attempt={id,actionID:action.id,title:t(platform==='ios'?'bootstrap_ios':'bootstrap_tvos'),status:'failed',createdAt:new Date().toISOString(),context:structuredClone(context),diagnosticAvailable:true,canCancel:false,bootstrap:{platform,phase:'failed',fraction:0}};});}
 finally{bootstrapLaunching=false;bootstrapLaunchError=cleanFragment(error,8192);if(attempt&&error)bootstrapFailedAttempt={...(attempt as LocalTask),error:bootstrapLaunchError};updateBootstrap();}
}
function currentBootstrap(){if(!state?.context)return undefined;if(bootstrapFailedAttempt?.context.checkoutId===state.context.checkoutId)return bootstrapFailedAttempt;return state?.tasks.find(task=>task.bootstrap&&['queued','running'].includes(task.status))??state?.tasks.find(task=>task.bootstrap);}
function bootstrapDarkTheme(){const theme=document.documentElement.dataset.theme;return theme==='dark'||theme!=='light'&&matchMedia('(prefers-color-scheme: dark)').matches;}
function updateBootstrap(mode=bootstrapMode,hidden=bootstrapHidden){
 bootstrapMode=mode;bootstrapHidden=hidden;const view=bootstrapView;if(!view)return;
 const task=currentBootstrap(),live=!!task&&['queued','running'].includes(task.status),active=live||bootstrapLaunching;
 for(const b of view.buttons)b.disabled=busy||stale||!state?.context||!uiAction('bootstrap')||active;
 view.launchers.hidden=active;view.platform.hidden=!active;view.platform.textContent=(bootstrapLaunching?bootstrapLaunchPlatform:task?.bootstrap?.platform)==='tvos'?'tvOS':'iOS';
 view.notice.hidden=active||mode==='expanded';view.description.hidden=mode!=='expanded';view.stages.hidden=mode!=='expanded'||!live||task?.status!=='running';
 view.footer.hidden=mode!=='expanded';view.technical.hidden=!task;
 view.technical.querySelector('p')!.textContent=task?[task.context.checkoutId,task.context.branch,task.context.sha,task.context.xcode].join('\n'):'';
 const actionsHost=mode==='expanded'?view.footer:view.controls;
 if(view.launchers.parentElement!==actionsHost){if(mode==='expanded')actionsHost.prepend(view.launchers);else actionsHost.prepend(view.launchers);}
 if(view.actions.parentElement!==actionsHost){if(mode==='expanded')actionsHost.prepend(view.actions);else actionsHost.insertBefore(view.actions,view.result);}
 const overlayHost=mode==='expanded'?view.footer:view.region;
 if(view.overlay.parentElement!==overlayHost){if(mode==='expanded')overlayHost.insertBefore(view.overlay,view.technical);else overlayHost.append(view.overlay);}
 view.region.hidden=mode==='mini';view.region.inert=mode==='mini'||hidden;
 const phaseKey='bootstrap.phase.'+task?.bootstrap?.phase;
 view.state.textContent=bootstrapLaunching?t('bootstrap.phase.checking'):task?(task.status==='running'&&task.progress?task.progress:phaseKey in ru?t(phaseKey):t(task.status)):'';
 view.state.className='bootstrap-state status '+(task?.status??'idle');view.state.classList.toggle('bootstrap-live-state',active);
 view.state.hidden=!view.state.textContent;view.state.title=view.state.textContent;
 const seconds=task?.startedAt?Math.max(0,Math.floor(((task.finishedAt?Date.parse(task.finishedAt):Date.now())-Date.parse(task.startedAt))/1000)):0;
 const duration=String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');
 view.time.textContent=task?(active?'':(task.bootstrap!.platform==='tvos'?'tvOS':'iOS'))+(task.startedAt?(active?'':' · ')+duration:''):'';view.time.hidden=!view.time.textContent||task?.bootstrap?.phase==='blocked';
 view.progress.value=task?.bootstrap?.fraction??0;view.progress.hidden=!active||task?.bootstrap?.phase==='blocked';
 view.error.textContent=bootstrapLaunchError||task?.error||'';view.error.hidden=mode!=='expanded'||!view.error.textContent;
 const stages=task?.bootstrap?.stages??['dependencies','uiTests','setup'],completed=task?.bootstrap?.completedStages??[];
 view.stages.replaceChildren(...stages.map(stage=>{const done=completed.includes(stage),current=live&&task?.status==='running'&&task.bootstrap?.currentStage===stage,node=element('span',(done?'✓ ':current?'◉ ':'○ ')+t('stage.short.'+stage));node.dataset.state=done?'complete':current?'running':'pending';return node;}));
 const actionSignature=stableJSON([task?.id,task?.status,task?.bootstrap?.phase,busy,mode,bootstrapLaunching]);
 if(view.actions.dataset.signature!==actionSignature){view.actions.dataset.signature=actionSignature;view.actions.replaceChildren();
  if(task?.bootstrap?.phase==='blocked')view.actions.append(button(t('bootstrap.retry'),()=>void perform(async()=>{await tool('panel_bootstrap_control',{taskID:task.id,operation:'retry'});await refresh();}),busy));
  if(active)view.actions.append(button(t(task?.status==='running'?'stop':'bootstrap.cancel'),()=>void perform(async()=>{if(task){await tool('cancel_local_task',{taskID:task.id});await refresh();}}),busy||!task?.canCancel));
  if(task?.bootstrap?.phase==='blocked'&&mode==='expanded')view.actions.append(button(t('bootstrap.activateXcode'),()=>void perform(async()=>{await tool('panel_bootstrap_control',{taskID:task.id,operation:'activateXcode'});await refresh();}),busy));
 }
 view.actions.hidden=!active;
 view.overlay.hidden=!task||!['failed','interrupted'].includes(task.status);view.overlay.disabled=busy;
 view.region.classList.toggle('has-error',!view.overlay.hidden&&mode!=='expanded');
 const failedAdmission=!!task&&task.id===bootstrapFailedAttempt?.id;
 if(task&&!failedAdmission){
  if(!bootstrapTerminal){bootstrapTerminal=new PrivateTerminal(tool,showError,{waiting:t('bootstrap.terminal.waiting'),unavailable:t('noOutput')});view.region.prepend(bootstrapTerminal.host);}
  bootstrapTerminal.host.hidden=false;view.region.querySelector<HTMLElement>('.bootstrap-terminal-idle')!.hidden=true;
  bootstrapTerminal.setTaskStatus(task.status);bootstrapTerminal.setBootstrapPlaceholder(bootstrapPlaceholderLabels,task.bootstrap!.platform);
  if(bootstrapTerminalTask!==task.id){bootstrapTerminalTask=task.id;void bootstrapTerminal.attach(task.id).catch(showError);}
  bootstrapTerminal.setBootstrapPresentation(mode==='expanded'?12:10,bootstrapDarkTheme(),matchMedia('(prefers-contrast: more)').matches,panelAppearance);
  bootstrapTerminal.setVisibility(mode!=='mini'&&!hidden);bootstrapTerminal.setTaskStatus(task.status);
 }else {
  if(bootstrapTerminalTask){bootstrapTerminalTask=null;void bootstrapTerminal?.detach();}
  if(bootstrapTerminal)bootstrapTerminal.host.hidden=true;
  view.region.querySelector<HTMLElement>('.bootstrap-terminal-idle')!.hidden=false;
  bootstrapIdlePlaceholder?.update(failedAdmission?'unavailable':'idle',task?.bootstrap?.platform??bootstrapLaunchPlatform);
 }
 if(diagnostic&&diagnosticSource==='bootstrap'&&diagnostic.task.id===task?.id){const editor=diagnosticEditor();if(editor.parentElement!==view.diagnostic)view.diagnostic.append(editor);view.diagnostic.hidden=mode!=='expanded';}
 else{view.diagnostic.replaceChildren();view.diagnostic.hidden=true;}
 const sendButton=diagnosticNode?.querySelector<HTMLButtonElement>('[data-action=diagnostic-send]');if(sendButton)sendButton.disabled=busy||!preview&&!extensions.message;
}
setInterval(()=>{
 const view=blockNodes.get('ci');if(!view)return;
 if(!view.summary.hidden){const row=currentLayout().rows.find(row=>row.slots.includes('ci'));renderCompactRuns(view.summary,ciSummaries().slice(0,row?.slots.length===1&&!isCompact()?2:1),t,openCI);}
 ciView.tick();
},1000);
const bootstrapClock=setInterval(()=>{buildPanel.tick();if(currentBootstrap()?.status==='running')updateBootstrap();if(historyOpen&&selection?.type==='task'&&state?.tasks.find(task=>task.id===selection?.id)?.bootstrap){renderHistory();renderDetails();}const view=blockNodes.get('utils');if(view&&!view.summary.hidden)renderToolsCompact(view.summary,currentLayout().rows.find(r=>r.slots.includes('utils'))?.slots.length===1&&!isCompact());for(const [id,form]of formNodes){const action=state?.actions.find(a=>a.id===id);if(action&&toolForAction(action)&&form.node.isConnected)form.update();}},1000);

// MARK: - Shared project tools
function toolForAction(action:Action){const role=state?.interface?.bindings.find(binding=>binding.actionID===action.id)?.role;return role?toolForRole(role):undefined;}
function toolRecords(){return [...new Map([...(state?.queue??[]),...(state?.tasks??[])].map(task=>[task.id,task])).values()];}
function currentToolTask(id:ToolID){return toolTask(toolRecords(),id,state?.context?.checkoutId);}
function toolBusy(id:ToolID){return toolRecords().some(task=>task.context?.checkoutId===state?.context?.checkoutId&&task.toolID===id&&['queued','running'].includes(task.status));}
function openProjectTool(id:ToolID){if(editLayout||cardDrag.session||cardDrag.saving)return;selectedTool=id;expanded='utils';catalogOpen=false;renderGrid();scheduleWorkspace();}
function taskDescription(task:LocalTask){return[t(task.status),elapsed(task)].filter(Boolean).join(' · ');}
async function saveToolFavorites(favorites:ToolID[]){await perform(async()=>{try{toolsPreferences=validateFavorites(await tool('panel_save_tools_preferences',{favorites,expectedRevision:toolsPreferences.revision}));if(!favorites.length)notice=t('tools.favorites.restored');await refresh();}catch(error){await refresh();if(error instanceof ToolFailure&&error.code==='toolsConflict')throw new Error(t('tools.favorites.conflict'));throw error;}});}
function toggleTool(id:ToolID){const current=toolsPreferences.favorites;void saveToolFavorites(current.includes(id)?current.filter(value=>value!==id):[...current,id]);}
function moveTool(id:ToolID,offset:number){const favorites=[...toolsPreferences.favorites],index=favorites.indexOf(id);if(index<0||index+offset<0||index+offset>=favorites.length)return;[favorites[index],favorites[index+offset]]=[favorites[index+offset],favorites[index]];void saveToolFavorites(favorites);}
function renderToolsCompact(host:HTMLElement,full:boolean){
 host.classList.add('tools-compact');host.classList.toggle('tools-wide',full);
 const ids=new Set(toolsPreferences.favorites);for(const child of Array.from(host.children))if(!ids.has((child as HTMLElement).dataset.tool as ToolID))child.remove();
 for(const [index,id]of toolsPreferences.favorites.entries()){
  let row=host.querySelector<HTMLButtonElement>('[data-tool="'+id+'"]');if(!row){row=button('',()=>openProjectTool(id),false,'tools-favorite');row.dataset.tool=id;row.append(element('span',['generation','localization','format'].includes(id)?'':toolSymbols[id],'tools-icon'),element('span',t('tool.name.'+id),'tools-name'),element('span','','tools-annotation'),element('span','','tools-state'));}
  const task=currentToolTask(id),description=t('tools.description.'+id);
  const annotation=row.querySelector<HTMLElement>('.tools-annotation')!;annotation.textContent=full?(task?taskDescription(task):description):'';annotation.classList.toggle('tools-task-annotation',!!task);
  const badge=row.querySelector<HTMLElement>('.tools-state')!;badge.textContent=task?statusSymbols[task.status]??'':'';badge.dataset.status=task?.status??'';
  row.title=[t('tool.name.'+id),description,task?taskDescription(task):''].filter(Boolean).join('\n');row.setAttribute('aria-label',row.title);
  if(host.children[index]!==row)host.insertBefore(row,host.children[index]??null);
 }
}
function ensureToolsContent(host:HTMLElement){
 if(selectedTool){ensureToolForm(selectedTool,host,true);return;}
 if(host.dataset.toolsPage!=='catalog'){host.replaceChildren();host.dataset.toolsPage='catalog';for(const id of tools){if(id==='fullCleanup')host.append(element('hr'));const row=element('div','','tools-catalog-row');row.dataset.tool=id;
  const open=button('',()=>openProjectTool(id),false,'tools-catalog-open');open.append(element('span',toolSymbols[id],'tools-icon'));const caption=element('span','','tools-catalog-caption');caption.append(element('strong',t('tool.name.'+id)),element('span',t('tools.description.'+id),'muted'));open.append(caption);row.append(open);
  const up=button('↑',()=>moveTool(id,-1),false,'quiet tools-move'),down=button('↓',()=>moveTool(id,1),false,'quiet tools-move'),pin=button('☆',()=>toggleTool(id),false,'quiet tools-pin');up.dataset.direction='up';down.dataset.direction='down';up.title=t('tools.move.up');down.title=t('tools.move.down');pin.dataset.pin=id;row.append(up,down,pin);host.append(row);
 }}
 for(const id of tools){const row=host.querySelector<HTMLElement>('[data-tool="'+id+'"]')!,index=toolsPreferences.favorites.indexOf(id);const up=row.querySelector<HTMLButtonElement>('[data-direction="up"]')!,down=row.querySelector<HTMLButtonElement>('[data-direction="down"]')!,pin=row.querySelector<HTMLButtonElement>('[data-pin]')!;
  up.hidden=down.hidden=index<0;up.disabled=busy||index<=0;down.disabled=busy||index<0||index>=toolsPreferences.favorites.length-1;pin.disabled=busy||index<0&&toolsPreferences.favorites.length===3;pin.textContent=index<0?'☆':'★';pin.title=t(index<0?'tools.pin':'tools.unpin');pin.setAttribute('aria-label',pin.title+' · '+t('tool.name.'+id));pin.setAttribute('aria-pressed',String(index>=0));
 }
}
function generatorRole(){return toolGenerator==='ui'?'generateUI':toolGenerator==='module'?'generateSicilia':'generateGalera';}
function ensureToolForm(id:ToolID,host:HTMLElement,back:boolean){
 const role=(id==='generation'?generatorRole():toolRoles[id][0]) as Block;
 const signature=stableJSON([id,role,back,state?.context?.checkoutId,state?.context?.profileRevision,state?.interface]);
 if(host.dataset.toolsPage!==signature){host.dataset.toolsPage=signature;host.replaceChildren();if(back){const previous=button('‹ '+t('tools.back'),()=>{selectedTool=null;renderGrid();scheduleWorkspace();},false,'quiet tools-back');host.append(previous);}
  host.append(element('h3',t('tool.name.'+id)));
  if(id==='generation'){const tabs=element('div','','tools-tabs');tabs.setAttribute('role','tablist');tabs.setAttribute('aria-label',t('generator.type'));for(const [kind,label]of [['ui','tools.generator.ui'],['module','tools.generator.module'],['feature','tools.generator.feature']] as const){const tab=button(t(label),()=>{toolGenerator=kind;ensureToolForm(id,host,back);scheduleWorkspace();},false,'quiet');tab.setAttribute('role','tab');tab.setAttribute('aria-selected',String(kind===toolGenerator));tabs.append(tab);}host.append(tabs);}
  host.append(element('div','','tools-form-host'));
 }
 const formHost=host.querySelector<HTMLElement>('.tools-form-host')!,action=uiAction(role);
 if(action)ensureActionForm(action,role,formHost);
 else if(!formHost.querySelector('.tools-unavailable')){formHost.replaceChildren(element('p',t('tools.unavailable'),'tools-unavailable error'),button(t('tools.settings'),()=>{settingsOpen=true;render();},false,'quiet'));}
}
const toolConfigurations=new Map<string,{missing:string[];command:string|null;effectsKey?:string}|null>();
let toolConfigurationRevision=0;
/** Only the private owner can supply commands; never execute them from the web view. */
function toolConfiguration(action:Action){
 if(!state?.context)return{missing:[t('needsBinding')],command:null};
 const parameters={...(actionValues.get(action.id)??{})},context=state.context,key=stableJSON([action.id,parameters,context]);
 if(!toolConfigurations.has(key)){
  if(toolConfigurations.size>50)toolConfigurations.delete(toolConfigurations.keys().next().value!);
  const revision=toolConfigurationRevision;toolConfigurations.set(key,null);
  void tool('panel_get_tool_configuration',{actionID:action.id,parameters,context}).then(value=>{if(revision!==toolConfigurationRevision)return;toolConfigurations.set(key,value);if(stableJSON(state?.context)===stableJSON(context))render();}).catch(error=>{if(revision!==toolConfigurationRevision)return;toolConfigurations.set(key,{missing:[error instanceof Error?error.message:t('error')],command:null});if(stableJSON(state?.context)===stableJSON(context))render();});
 }
 return toolConfigurations.get(key);
}
function renderToolTask(host:HTMLElement,id:ToolID){
 const task=currentToolTask(id);if(!task){host.replaceChildren();host.dataset.task='';return;}
 const signature=task.id+task.status+busy;if(host.dataset.task!==signature){host.dataset.task=signature;host.replaceChildren(element('p','','tools-task-status'));
  if(['queued','running'].includes(task.status)){if(task.status==='queued')host.append(element('p',t('tools.queue.explanation'),'muted'));const cancel=button(t('cancel'),()=>void perform(async()=>{await tool('cancel_local_task',{taskID:task.id});await refresh();}),busy||!task.canCancel,'quiet');cancel.dataset.action='tool-cancel';host.append(cancel);}
  const open=button(t('tools.task.open'),()=>selectItem('task',task.id),false,'quiet');open.dataset.action='tool-task-open';host.append(open);
 }
 host.querySelector('.tools-task-status')!.textContent=taskDescription(task);
}

function ensureBlockContent(block:Block,host:HTMLElement){if(block==='utils'){ensureToolsContent(host);return;}if(block==='bootstrap'){ensureBootstrapContent(host);return;}if(block==='simulators'){if(simulatorHost.parentElement!==host)host.append(simulatorHost);return;}if(block==='builds'){buildPanel.update(host,'extended',state?.context??null,(state?.builds??[]) as BuildRecord[]);return;}
 if(block==='ci'){if(!host.querySelector('.tool-choice')){const choices=['uiTests','qualityGates','beta'];for(const kind of choices)host.append(button(blockTitle(kind as Block),()=>openBlock(kind as Block),!uiAction(kind),'tool-choice'));}if(block==='ci'&&ciView.host.parentElement!==host)host.prepend(ciView.host);return;}
 const family=toolForRole(block);if(family){ensureToolForm(family,host,false);return;}
 const action=uiAction(block);if(!action){host.replaceChildren(element('p',t('noActions')));return;}ensureActionForm(action,block,host);
}
function ensureActionForm(action:Action,block:Block,host:HTMLElement){
 const signature=stableJSON([action,uiBinding(block),state?.context?.checkoutId,state?.context?.profileRevision]);let form=formNodes.get(action.id);if(form?.signature===signature){if(form.node.parentElement!==host)host.replaceChildren(form.node);return;}
 const box=element('form','','action-form');box.onsubmit=event=>{event.preventDefault();if(action.presentation==='generator')void generateAction(action);else void runAction(action,!!toolForRole(block));};const values={...Object.fromEntries(action.parameters.map(p=>[p.id,p.kind==='branch'&&!p.defaultValue?state?.context?.branch??'':p.defaultValue])),...Object.fromEntries(Object.entries(actionValues.get(action.id)??{}).filter(([id])=>action.parameters.some(p=>p.id===id)))};actionValues.set(action.id,values);
 const controls=new Map<string,{wrapper:HTMLElement;input:HTMLInputElement|HTMLSelectElement;choices:string[]}>();
 const family=toolForRole(block);if(family){box.append(element('p',t('tools.description.'+family),'muted'),element('p',(state?.context?.checkoutId.split('/').filter(Boolean).at(-1)??'')+' · '+(state?.context?.branch??''),'tools-context'));if(family!=='generation')box.append(element('p',t('tools.effects.'+family),'tools-effects'));else box.append(element('p',t('generator.'+({generateUI:'ui',generateSicilia:'module',generateGalera:'feature'} as Record<string,string>)[block]+'.description'),'muted'));}
 for(const parameter of action.parameters){const choices=parameter.kind==='platform'?['ios','tvos']:parameter.choices??[];let input:HTMLInputElement|HTMLSelectElement=choices.length?element('select'):element('input');if(input instanceof HTMLSelectElement)for(const choice of choices)input.append(new Option(choice,choice));else{input.type=parameter.kind==='boolean'?'checkbox':'text';if(input.type==='checkbox')input.checked=values[parameter.id]==='true';}input.value=values[parameter.id];input.id='field-'+action.id+'-'+parameter.id;const label=element('label',parameter.title);label.htmlFor=input.id;const wrapper=element('div','','field');if(parameter.kind==='boolean'){wrapper.classList.add('toggle');wrapper.append(input,label);}else wrapper.append(label,input);
  input.oninput=()=>{values[parameter.id]=parameter.kind==='boolean'?String((input as HTMLInputElement).checked):input.value;previews.delete(action.id);update();scheduleWorkspace();};
  if(parameter.kind==='branch'&&action.remote){const searchBranches=button(t('search'),()=>void perform(async()=>{const result=await tool('list_remote_branches',{query:input.value});const list=element('datalist');list.id=input.id+'-choices';list.append(...result.branches.map((branch:string)=>new Option(branch,branch)));wrapper.querySelector('datalist')?.remove();wrapper.append(list);input.setAttribute('list',list.id);}),false,'quiet');wrapper.append(searchBranches);}
  if(family==='generation'&&uiBinding(block)?.fields.name===parameter.id){input.setAttribute('placeholder',t('generator.name.placeholder'));wrapper.append(element('p',t('generator.name.hint'),'muted'));input.setAttribute('aria-describedby',input.id+'-hint');wrapper.lastElementChild!.id=input.id+'-hint';}
  controls.set(parameter.id,{wrapper,input,choices});box.append(wrapper);
 }
 const configuration=button(t('remoteReview'),()=>void configureAction(action,update),false,'quiet');if(action.remote)box.append(configuration);
 const localTool=toolForRole(block),previewBox=element('div','','preview-files'),launch=button(t('run'),()=>void runAction(action,!!localTool),false,'primary');const previewButton=button(t('generator.preview'),()=>void previewGenerator(action),false,'quiet');
 if(action.presentation==='generator'){launch.textContent=t('generator.generate');launch.onclick=()=>void generateAction(action);box.append(previewButton,previewBox);}
 const readiness=element('div','','tools-readiness'),technical=element('details','','tools-technical'),technicalTitle=element('summary',t('command.details')),commandText=element('pre','','mono');technical.append(technicalTitle,commandText);if(localTool)box.append(readiness,technical);
 const taskHost=element('div','','tools-task');if(localTool)box.append(taskHost);
 const delegateButton=button(t('delegate'),()=>void delegate(action));const row=element('div','','form-bottom');row.append(launch,delegateButton);box.append(row);
 function update(){for(const p of action.parameters){const control=controls.get(p.id)!;control.wrapper.hidden=p.visibleWhen?Object.entries(p.visibleWhen).some(([key,value])=>values[key]!==value):false;const server=remoteFields.get(action.id)?.[p.id];if(p.kind==='choice'&&server?.choices.length&&!(control.input instanceof HTMLSelectElement)){const select=element('select');select.id=control.input.id;select.oninput=()=>{values[p.id]=select.value;previews.delete(action.id);update();scheduleWorkspace();};control.input.replaceWith(select);control.input=select;control.choices=[];}if(server&&control.input instanceof HTMLSelectElement&&stableJSON(server.choices)!==stableJSON(control.choices)){control.choices=server.choices;control.input.replaceChildren(...server.choices.map(x=>new Option(x,x)));control.input.value=values[p.id];}control.input.disabled=busy;}
  configuration.disabled=busy||stale||!state?.jenkinsConfigured;configuration.textContent=t(remoteFields.has(action.id)?'remoteRefresh':'remoteReview');
  let valid=!!state?.context&&!stale&&!busy&&action.parameters.every(p=>p.visibleWhen&&Object.entries(p.visibleWhen).some(([k,v])=>values[k]!==v)||!p.required||!!values[p.id]);if(action.remote)valid=valid&&remoteFields.has(action.id)&&!!state?.jenkinsConfigured;
  if(localTool){const configuration=toolConfiguration(action),signature=stableJSON(configuration);if(readiness.dataset.signature!==signature){readiness.dataset.signature=signature;readiness.replaceChildren();if(!configuration)readiness.append(element('p',t('loading'),'muted'));else if(configuration.missing.length)readiness.append(element('p',t('tools.unavailable')+' '+configuration.missing.join(', '),'error'),button(t('tools.settings'),()=>{settingsOpen=true;render();},false,'quiet'));}if(!configuration||configuration.missing.length)valid=false;commandText.textContent=configuration?.command??t('tools.command.unavailable');const effects=box.querySelector('.tools-effects');if(effects&&configuration?.effectsKey)effects.textContent=t(configuration.effectsKey);
   const current=currentToolTask(localTool);if(toolBusy(localTool))valid=false;renderToolTask(taskHost,localTool);
  }
  const reviewedPreview=previews.get(action.id);if(action.presentation==='generator'){const nameField=uiBinding(block)?.fields.name,nameValid=!nameField||/^[A-Z][A-Za-z]{0,49}$/.test(values[nameField]??'');valid=valid&&nameValid&&!!reviewedPreview?.plan&&reviewedPreview.fingerprint===stableJSON([values,state?.context])&&reviewedPreview.plan.files.length>0&&reviewedPreview.plan.files.every(f=>!f.exists);const signature=stableJSON(reviewedPreview?.plan??!!reviewedPreview);if(previewBox.dataset.signature!==signature){previewBox.dataset.signature=signature;previewBox.replaceChildren();if(reviewedPreview?.plan){previewBox.append(element('p',String(reviewedPreview.plan.files.length)+' '+t('generator.files')));for(const file of reviewedPreview.plan.files){const row=element('div','','tools-preview-file');row.append(element('span',(file.exists?'! ':'+ ')+file.path,'mono'));if(file.exists)row.append(element('p',t('generator.file.exists'),'error'));previewBox.append(row);}}else if(reviewedPreview)previewBox.append(element('p',t('generator.waiting'),'muted'));}previewButton.disabled=!nameValid||busy||stale||!state?.context||!!localTool&&(toolBusy(localTool)||!toolConfiguration(action)||!!toolConfiguration(action)?.missing.length)||!action.parameters.every(p=>!p.required||!!values[p.id]);}
  launch.disabled=!valid;delegateButton.disabled=!state?.context||busy||!preview&&!extensions.message;
 }
 form={signature,node:box,update};formNodes.set(action.id,form);host.replaceChildren(box);update();
}
async function configureAction(action:Action,update:()=>void){await perform(async()=>{const result=await tool('get_action_configuration',{actionID:action.id});if(stableJSON(result.context)!==stableJSON(state?.context))throw new Error(t('stale'));remoteFields.set(action.id,result.fields);const values=actionValues.get(action.id)!;for(const id of applyRemoteDefaults(action.parameters,values,result.fields)){const input=formNodes.get(action.id)?.node.querySelector<HTMLInputElement|HTMLSelectElement>('#field-'+action.id+'-'+id);if(input){input.value=values[id];if(input instanceof HTMLInputElement&&input.type==='checkbox')input.checked=values[id]==='true';}}update();scheduleWorkspace();});}
async function delegate(action:Action){await perform(async()=>{const parameters=actionValues.get(action.id)??{};let message=t('delegate.prompt')+'\n'+stableJSON({actionID:action.id,parameters,context:state?.context,operation:action.presentation==='generator'?'preview_generator → get_generator_preview → generate_files (expectedDigest)':action.remote?'run_remote_action':'run_local_action'});if(!preview)await extensions.message!.send({role:'user',content:[{type:'text',text:message}]});else fixtureSentMessage=message;notice=t('sent');});}
async function previewGenerator(action:Action){await perform(async()=>{const parameters=actionValues.get(action.id)!;const fingerprint=stableJSON([parameters,state?.context]),key='preview:'+action.id+':'+fingerprint;const result=await tool('panel_preview_generator',{actionID:action.id,parameters,context:state?.context,requestID:requestID(key)});pendingIDs.delete(key);previews.set(action.id,{taskID:result.id,fingerprint});if(!toolForAction(action))selection={type:'task',id:result.id};await refresh();});}
async function generateAction(action:Action){const family=toolForAction(action),current=family?currentToolTask(family):undefined;if(family&&toolBusy(family))return;await perform(async()=>{const reviewed=previews.get(action.id);if(!reviewed?.plan||reviewed.fingerprint!==stableJSON([actionValues.get(action.id),state?.context]))throw new Error(t('generator.review'));const parameters={...actionValues.get(action.id),expectedDigest:reviewed.plan.digest},key=stableJSON([action.id,parameters,state?.context]);try{const result=await tool('panel_generate',{actionID:action.id,parameters,context:state?.context,requestID:requestID(key)});pendingIDs.delete(key);if(!toolForAction(action))selection={type:'task',id:result.id};previews.delete(action.id);await refresh();}catch(e){releaseRejectedRequest(key,e);throw e;}});}
let checkingPreviews=false;
async function updatePreviews(){if(checkingPreviews)return;checkingPreviews=true;try{for(const [id,reviewed]of previews){if(reviewed.plan)continue;const task=state?.tasks.find(t=>t.id===reviewed.taskID);if(task?.status==='succeeded'){const result=await tool('panel_get_preview',{taskID:reviewed.taskID});if(previews.get(id)===reviewed&&result.plan){reviewed.plan=result.plan;formNodes.get(id)?.update();}}else if(task&&['failed','cancelled','interrupted'].includes(task.status)){previews.delete(id);formNodes.get(id)?.update();}}}finally{checkingPreviews=false;}}
async function setup(operation:string){await perform(async()=>{await tool('panel_setup',{operation});await refresh(true);});}
function render(){root.setAttribute('aria-busy',String(busy));banner.textContent=[preview?t('preview'):'',error,stale?t('stale'):'',notice].filter(Boolean).join(' · ');banner.className=error||stale?'error':'banner';if(!state){contextLabel.textContent=t('loading');workStatus.textContent='';return;}installWorkspace(state);
 const active=[...state.tasks.map(t=>({...t,type:'task' as const})),...(state.builds??[]).map(item=>({...item,title:t((item as BuildRecord).actionKey??'operation.'+item.parameters.operation),type:'build' as const}))].find(t=>['running','preparing'].includes(t.status));
 const project=state.context?.checkoutId.split('/').pop()??t('noCheckout'),xcode=state.context?.xcode.split('/').find(p=>p.endsWith('.app'))??t('build.chooseXcode');const contextText=[project,state.context?.branch,xcode].filter(Boolean).join(' · ');
 middleText(contextLabel,contextText);contextLabel.title=contextText;contextLabel.disabled=busy||!!state.checkoutLocked;branchSwitchPanel.update(state,busy);workStatus.textContent=active?t(active.needsInput?'notification.input':active.status):state.progress??t('ready');
 const records=[...state.tasks.map(item=>({...item,type:'task' as const})),...(state.builds??[]).map(item=>({...item,type:'build' as const})),...state.runs.map(item=>({...item,type:'run' as const,title:item.branch}))].sort((a,b)=>b.createdAt.localeCompare(a.createdAt));
 const activity=records.find(item=>'needsInput'in item&&item.needsInput)??records.find(item=>['running','preparing','queued','triggering','pending'].includes(item.status))??(records[0]&&['failed','interrupted','unknown','submissionFailed'].includes(records[0].status)?records[0]:null);
 chrome.update({tiled:panelAppearance==='tileGrid',context:state.context,busy,locked:!!state.checkoutLocked,stale,editing:!!editLayout,rebase:!!state.branchRebase,catalogOpen,historyOpen,activity,progress:state.progress,needsBinding:state.needsBinding});
 toolbar.classList.toggle('layout-editing',!!editLayout);
 if(contextDetail.dataset.text!==stableJSON(state.context)+settingsOpen){contextDetail.dataset.text=stableJSON(state.context)+settingsOpen;contextDetail.replaceChildren(element('summary',t('context.details')),element('p',[state.context?.checkoutId,state.context?.sha,state.context?.xcode,state.context?.profileRevision].filter(Boolean).join('\n'),'mono'));if(state.needsBinding)contextDetail.append(button(t('binding.request'),()=>void perform(async()=>{if(!preview)await extensions.message!.send({role:'user',content:[{type:'text',text:t('binding.prompt')}]});notice=t('sent');})));if(settingsOpen||!state.context||!state.actions.length){const row=element('div','','row');for(const operation of ['profile','xcode','target','credentials','notifications','appearance'])row.append(button(t('setup.'+operation),()=>void setup(operation),busy||!['profile','notifications','appearance'].includes(operation)&&!state.context));row.append(button(t('branch.local'),()=>void loadBranches(),busy||!state.context));contextDetail.append(row);contextDetail.open=true;}}
 const toolbarSignature=String(!!editLayout)+busy;if(toolbar.dataset.signature!==toolbarSignature){toolbar.dataset.signature=toolbarSignature;toolbar.replaceChildren(...(editLayout?[button(t('layout.add'),()=>{catalogOpen=!catalogOpen;renderCatalog();}),button(t('layout.reset'),()=>{editLayout=standard();renderGrid();}),button(t('layout.cancel'),cancelEdit),button(t('layout.done'),()=>void finishEdit(),busy,'primary')]:[button(t('newAction'),()=>{catalogOpen=!catalogOpen;renderCatalog();}),button(t('history'),()=>{historyOpen=!historyOpen;renderHistory();renderDetails();}),button(t('settings'),()=>{settingsOpen=!settingsOpen;render();}),button(t('layout.edit'),beginEdit)]));}
 renderCatalog();renderGrid();renderHistory();renderDetails();contextDetail.querySelectorAll<HTMLButtonElement>('[data-action=branch-switch]').forEach(button=>button.disabled=busy||!!state?.checkoutLocked||!button.parentElement?.querySelector('select')?.value);const waiting=state.queue?.filter(t=>t.context?.checkoutId!==state?.context?.checkoutId)??[];queueHost.textContent=waiting.length?t('queue.other')+' '+waiting.length:'';renderSimulatorRecovery();void updatePreviews();
}
async function switchBranch(branch:string){if(!branch||!state?.context||state.checkoutLocked||stale)return;await perform(async()=>{const key=stableJSON(['branch',branch,state?.context]);try{await tool('panel_switch_branch',{branch,context:state?.context,requestID:requestID(key)});pendingIDs.delete(key);await refresh();}catch(error){releaseRejectedRequest(key,error);throw error;}});}
async function loadBranches(){if(!state?.context||state.checkoutLocked)return;const tiled=panelAppearance==='tileGrid';if(tiled&&!chrome.toggleBranches())return;await perform(async()=>{const context=stableJSON(state?.context),result=await tool('panel_branches');if(context!==stableJSON(state?.context))return;if(tiled){chrome.setBranches(result.branches);return;}contextDetail.querySelector('[data-branch-picker]')?.remove();const picker=element('div','','row');picker.dataset.branchPicker='';const select=element('select');select.setAttribute('aria-label',t('branch.local'));select.append(new Option(t('branch.local'),''),...result.branches.map((branch:string)=>new Option(branch,branch)));const change=button(t('branch.switch'),()=>void switchBranch(select.value),true,'quiet');change.dataset.action='branch-switch';select.onchange=()=>{change.disabled=busy||!select.value||!!state?.checkoutLocked;};picker.append(select,change);contextDetail.append(picker);contextDetail.open=true;});}
function renderCatalog(){catalogHost.hidden=!catalogOpen;if(!catalogOpen)return;const signature=stableJSON([!!editLayout,currentLayout().rows,state?.actions.map(a=>a.id),state?.simulator?.visible]);if(catalogHost.dataset.signature===signature)return;catalogHost.dataset.signature=signature;catalogHost.replaceChildren(element('h2',t('catalog')));for(const block of availableBlocks()){if(editLayout&&editLayout.rows.some(r=>r.slots.includes(block)))continue;catalogHost.append(button(blockTitle(block),()=>{if(editLayout)edit(l=>add(l,block));else openBlock(block);},false,'tool-choice'));}}
// MARK: - Inline Bootstrap history, with a terminal independent of the card
const historyRows=new Map<string,HTMLButtonElement>();
const bootstrapHistoryRows=new Map<string,HTMLElement>();
let bootstrapHistoryTerminal:PrivateTerminal|null=null;
let bootstrapHistoryID:string|null=null;
let bootstrapHistoryDetail:HTMLElement|null=null;
function bootstrapDuration(task:LocalTask){return task.startedAt?elapsed(task):'';}
function renderHistory(){
 historyHost.hidden=!historyOpen;
 if(!historyOpen){bootstrapHistoryTerminal?.setVisibility(false);return;}
 const records=[...state!.tasks.map(t=>({...t,type:'task' as const})),...(state!.builds??[]).map(t=>({...t,type:'build' as const})),...state!.runs.map(t=>({...t,title:t.branch,type:'run' as const}))].sort((a,b)=>b.createdAt.localeCompare(a.createdAt)).slice(0,100);
 if(!historyHost.querySelector('h2'))historyHost.prepend(element('h2',t('history')));
 historyHost.querySelector('.empty')?.remove();
 const ids=new Set(records.map(r=>r.type+':'+r.id));
 for(const [id,node]of historyRows)if(!ids.has(id)){(bootstrapHistoryRows.get(id)??node).remove();historyRows.delete(id);bootstrapHistoryRows.delete(id);}
 if(!records.length)historyHost.append(element('p',t('emptyTasks'),'empty'));
 for(const [index,item]of records.entries()){
  const id=item.type+':'+item.id,isBootstrap=item.type==='task'&&!!item.bootstrap;
  let row=historyRows.get(id);
  if(!row){
   row=button('',()=>{if(isBootstrap&&selection?.id===item.id){selection=null;diagnostic=null;render();scheduleWorkspace();void syncContext();}else selectItem(item.type,item.id);},false,'item');
   row.append(element('span','','item-title'),status(item.status));historyRows.set(id,row);
   if(isBootstrap){const wrapper=element('div','','bootstrap-history-row');wrapper.append(row);bootstrapHistoryRows.set(id,wrapper);row.append(element('span','','item-sub'),element('span','','item-timing'),element('span','›','item-chevron'));}
  }
  row.querySelector('.item-title')!.textContent=item.title;
  const label=row.querySelector('.status')!;label.textContent=t(item.status);label.className='status '+item.status;
  const selected=selection?.id===item.id;row.setAttribute('aria-pressed',String(selected));
  if(isBootstrap){
   row.setAttribute('aria-expanded',String(selected));row.setAttribute('aria-controls','bootstrap-history-'+item.id);
   row.querySelector('.item-sub')!.textContent=item.context.checkoutId.split('/').filter(Boolean).at(-1)+' · '+item.context.branch;
   row.querySelector('.item-sub')!.setAttribute('title',item.context.checkoutId+' · '+item.context.branch);
   row.querySelector('.item-timing')!.textContent=[bootstrapDuration(item),date(item.createdAt)].filter(Boolean).join(' · ');
   row.querySelector('.item-chevron')!.textContent=selected?'⌄':'›';
  }
  const node=bootstrapHistoryRows.get(id)??row;
  if(historyHost.children[index+1]!==node)historyHost.insertBefore(node,historyHost.children[index+1]??null);
 }
}
function renderBootstrapHistory(task:LocalTask){
 const wrapper=bootstrapHistoryRows.get('task:'+task.id);
 if(!wrapper){bootstrapHistoryTerminal?.setVisibility(false);return;}
 if(bootstrapHistoryID!==task.id||!bootstrapHistoryDetail){
  if(bootstrapHistoryTerminal)void bootstrapHistoryTerminal.dispose();
  bootstrapHistoryDetail?.remove();bootstrapHistoryID=task.id;
  const detail=element('section','','bootstrap-history-details');detail.id='bootstrap-history-'+task.id;detail.setAttribute('aria-label',t('task.details'));
  const step=element('p','','bootstrap-history-step'),progress=element('progress','','bootstrap-progress');progress.max=1;
  const stages=element('div','','bootstrap-stages'),failure=element('p','','bootstrap-error error');
  const terminal=new PrivateTerminal(tool,showError,{waiting:t('bootstrap.terminal.waiting'),unavailable:t('noOutput')});bootstrapHistoryTerminal=terminal;
  const footer=element('div','','bootstrap-details-footer'),actions=element('div','','bootstrap-history-actions');
  const cancel=button(t('cancel'),()=>void perform(async()=>{await tool('cancel_local_task',{taskID:task.id});await refresh();}));cancel.dataset.action='cancel';
  const analyzeButton=button(t('analyze'),()=>void analyze(task.id));analyzeButton.dataset.action='analyze';
  const secret=button(t('terminal.secret'),()=>void perform(async()=>{await tool('panel_secret_input',{taskID:task.id});}));secret.dataset.action='secret';
  const retry=button(t('bootstrap.retry'),()=>void perform(async()=>{await tool('panel_bootstrap_control',{taskID:task.id,operation:'retry'});await refresh();}));retry.dataset.action='retry';
  const activate=button(t('bootstrap.activateXcode'),()=>void perform(async()=>{await tool('panel_bootstrap_control',{taskID:task.id,operation:'activateXcode'});await refresh();}));activate.dataset.action='activate';
  actions.append(cancel,retry,activate,analyzeButton,secret);
  const technical=element('details','','bootstrap-technical');technical.append(element('summary',t('task.technical')),element('p','','mono'));
  footer.append(actions,technical);detail.append(step,progress,stages,failure,terminal.host,footer,element('div','','bootstrap-history-diagnostic'));bootstrapHistoryDetail=detail;
  void terminal.attach(task.id).catch(showError);
 }
 const detail=bootstrapHistoryDetail,terminal=bootstrapHistoryTerminal!,live=['queued','running'].includes(task.status),running=task.status==='running',blocked=task.bootstrap?.phase==='blocked';
 if(detail.parentElement!==wrapper)wrapper.append(detail);detail.hidden=false;
 const step=detail.querySelector<HTMLElement>('.bootstrap-history-step')!;
 step.textContent=running?task.progress??t('bootstrap.phase.running'):task.status==='queued'?t('bootstrap.phase.'+task.bootstrap?.phase):'';step.hidden=!step.textContent;
 const progress=detail.querySelector<HTMLProgressElement>('progress')!;progress.value=task.bootstrap?.fraction??0;progress.hidden=!running;
 const stages=detail.querySelector<HTMLElement>('.bootstrap-stages')!;stages.hidden=!running;
 const stageSignature=stableJSON(task.bootstrap);if(stages.dataset.signature!==stageSignature){stages.dataset.signature=stageSignature;stages.replaceChildren(...(task.bootstrap?.stages??[]).map(stage=>element('span',(task.bootstrap?.completedStages?.includes(stage)?'✓ ':task.bootstrap?.currentStage===stage?'◉ ':'○ ')+t('stage.short.'+stage))));}
 const failure=detail.querySelector<HTMLElement>('.bootstrap-error')!;failure.textContent=cleanFragment(task.error??'',8192);failure.title=failure.textContent;failure.hidden=!failure.textContent;
 for(const name of ['cancel','analyze','secret','retry','activate']){const node=detail.querySelector<HTMLButtonElement>('[data-action='+name+']')!;node.hidden=name==='cancel'?!live:name==='secret'?!running:name==='retry'||name==='activate'?!blocked:!['failed','interrupted'].includes(task.status);node.disabled=busy||(name==='cancel'?!task.canCancel:name==='analyze'?!task.diagnosticAvailable:false);}
 detail.querySelector('.bootstrap-technical p')!.textContent=[task.context.checkoutId,task.context.branch,task.context.sha,task.context.xcode].join('\n');
 terminal.setTaskStatus(task.status);terminal.setBootstrapPlaceholder(bootstrapPlaceholderLabels,task.bootstrap!.platform);terminal.setBootstrapPresentation(12,bootstrapDarkTheme(),matchMedia('(prefers-contrast: more)').matches,panelAppearance);terminal.setVisibility(historyOpen);
 const editorHost=detail.querySelector<HTMLElement>('.bootstrap-history-diagnostic')!;
 if(diagnostic&&diagnosticSource==='history'&&diagnostic.task.id===task.id){const editor=diagnosticEditor();if(editor.parentElement!==editorHost)editorHost.append(editor);}else editorHost.replaceChildren();
}

function renderDetails(){const item=selection?.type==='task'?state?.tasks.find(t=>t.id===selection?.id):selection?.type==='build'?state?.builds?.find(t=>t.id===selection?.id):state?.runs.find(t=>t.id===selection?.id);if(selection?.type==='task'&&item&&'bootstrap'in item&&item.bootstrap){detailSignature='';if(detailHost.childNodes.length)detailHost.replaceChildren();if(detailsTerminal)void detailsTerminal.detach();renderBootstrapHistory(item);return;}
 if(bootstrapHistoryDetail)bootstrapHistoryDetail.hidden=true;bootstrapHistoryTerminal?.setVisibility(false);
 const signature=stableJSON([item?.id,diagnostic?.task.id,notice]);if(signature===detailSignature){const label=detailHost.querySelector('.status');if(label&&item){label.textContent=t(item.status);label.className='status '+item.status;const cancel=detailHost.querySelector<HTMLButtonElement>('[data-action=cancel]'),analyze=detailHost.querySelector<HTMLButtonElement>('[data-action=analyze]'),secret=detailHost.querySelector<HTMLButtonElement>('[data-action=secret]');if(cancel)cancel.disabled=busy||!('canCancel'in item&&item.canCancel);if(analyze)analyze.disabled=busy||!('diagnosticAvailable'in item&&item.diagnosticAvailable);if(secret)secret.disabled=item.status!=='running';}return;}detailSignature=signature;
 const terminalHost=detailsTerminal?.host;if(terminalHost)terminalHost.remove();detailHost.replaceChildren();if(!item){if(detailsTerminal)void detailsTerminal.detach();return;}const selectedBuild=selection?.type==='build'?state?.builds?.find(build=>build.id===selection?.id):undefined;const detail=card(selectedBuild?t(selectedBuild.actionKey??'operation.'+selectedBuild.parameters.operation):'title' in item?item.title:item.branch);const close=button(t('close'),()=>{selection=null;diagnostic=null;renderDetails();scheduleWorkspace();});detail.append(close,status(item.status));if('context'in item){detail.append(element('p',[item.context.branch,item.context.sha].join(' · '),'mono'));const actions=element('div','','row');actions.append(button(t('cancel'),()=>void perform(async()=>{await tool(selection!.type==='build'?'cancel_build_activity':'cancel_local_task',selection!.type==='build'?{activityID:item.id}:{taskID:item.id});await refresh();}),busy||!item.canCancel));actions.lastElementChild!.setAttribute('data-action','cancel');actions.append(button(t('analyze'),()=>selection?.type==='task'?void analyze(item.id):void perform(async()=>{const result=await tool('get_build_diagnostic',{activityID:item.id});diagnosticSource='history';diagnostic={task:result.task,text:result.analysisPrompt.split('<diagnostic-data>')[1]?.split('</diagnostic-data>')[0]?.trim()??'',analysisPrompt:result.analysisPrompt,truncated:result.truncated,outputUnavailable:false};fragment=diagnostic.text;comment='';}),busy||!item.diagnosticAvailable));actions.lastElementChild!.setAttribute('data-action','analyze');actions.append(button(t('terminal.open'),()=>{if(!detailsTerminal)detailsTerminal=new PrivateTerminal(tool,showError,{waiting:t('bootstrap.terminal.waiting'),unavailable:t('noOutput')});detail.append(detailsTerminal.host);void detailsTerminal.attach(item.id).catch(showError);}),button(t('terminal.secret'),()=>void perform(async()=>{await tool('panel_secret_input',{taskID:item.id});}),item.status!=='running'));actions.lastElementChild!.setAttribute('data-action','secret');detail.append(actions);if(terminalHost){detail.append(terminalHost);void detailsTerminal!.attach(item.id).catch(showError);}}else{if(detailsTerminal)void detailsTerminal.detach();for(const a of [link('Jenkins',item.jenkinsURL),link('GitLab',item.gitlabURL),link('Allure',item.allureURL)])if(a)detail.append(a);if(item.error)detail.append(element('p',item.error,'error'));for(const job of item.jobs)detail.append(element('p',job.name+' · '+t(job.status)));}detailHost.append(detail);
 if(diagnostic&&diagnosticSource==='history')detailHost.append(diagnosticEditor());
}

// MARK: - A persistent, independently leased simulator viewer
const simulatorPanel:SimulatorPanel=new SimulatorPanel(simulatorHost,tool,()=>({context:state?.context??null,simulator:state?.simulator,blocked:busy||!!state?.queue?.some(x=>['running','preparing'].includes(x.status)&&!simulatorPanel.ownsManualActivity(x.id))||!!state?.tasks.some(x=>['running','preparing'].includes(x.status))||!!state?.builds?.some(x=>['running','preparing'].includes(x.status))}),refresh);
function updateSimulator(){simulatorPanel.update();}
async function simulatorPrivateRelease(activityID:string){try{await tool('simulator_ui_release_unknown',{activityID});await refresh();}catch(error){showError(error);}}
function availableBlocks(){return catalog.filter(block=>block!=='simulators'||state?.simulator?.visible===true);}
function renderSimulatorRecovery(){for(const activity of state?.simulator?.activities??[]){if(activity.status!=='unknown'||activity.queueReleased)continue;const row=element('div','','queue-recovery');row.append(element('span','Неизвестный результат команды симулятора · '+activity.id.slice(0,8)));const release=button('Проверить и восстановить очередь',()=>{if(release.dataset.confirm!=='true'){release.dataset.confirm='true';release.textContent='Xcode проверен — освободить очередь';return;}void simulatorPrivateRelease(activity.id);});row.append(release);queueHost.append(row);}}
const fixtureSimulatorActions:Record<string,unknown>[]=[];
const fixtureSimulatorInputEvents:Record<string,unknown>[]=[];
const fixtureContext:Context={checkoutId:'/private/tmp/MimicFixture',branch:'feature/mcp',sha:'fixture-sha',xcode:'/Applications/Xcode.app/Contents/Developer',appleTarget:null,profileID:null,profileRevision:null};
let fixtureBuildDraft:BuildDraft={operation:'build',backend:'cli',scheme:'Fixture',configuration:'Debug',destinationID:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',testPlan:'',testIdentifiers:[],workspaceTab:''};
let fixtureBuildTests:{id:string;target:string;className:string;name:string}[]|null=null;
const fixtureBuildCalls:Record<string,unknown>[]=[];
const fixtureState:State={appearance:new URL(location.href).searchParams.get('appearance')==='legacy'?'legacy':'tileGrid',interface:{version:1,bindings:[{role:'bootstrap',actionID:'prepare',fields:Object.fromEntries(['platform','device','match','full','dependencies','uiDependencies','setup'].map(x=>[x,x]))}]},context:fixtureContext,actions:[{id:'prepare',title:'Подготовка',presentation:'preparation',remote:false,parameters:[...['device','match','full','dependencies','uiDependencies','setup'].map(id=>({id,title:id,kind:'boolean',defaultValue:'true',required:true})),{id:'platform',title:'Платформа',kind:'platform',defaultValue:'ios',required:true}]}],tasks:[{id:'fixture-task',actionID:'prepare',bootstrap:{platform:'ios',phase:'failed',fraction:0},title:t('bootstrap_ios'),status:'failed',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:true,canCancel:false}],builds:[{id:'fixture-build',title:t('operation.build'),status:'failed',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:true,canCancel:false,tracking:'unavailable',source:'Terminal',phase:'build.phase.failed',parameters:{operation:'build',backend:'cli',scheme:'Fixture',configuration:'Debug',destinationID:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',workspaceTab:''}}],runs:[],jenkinsConfigured:true,progress:t('failed')};
fixtureState.actions.push({id:'cleanup-all',title:'Cleanup',presentation:'regular',remote:false,parameters:[]},{id:'cleanup-derived',title:'DerivedData',presentation:'regular',remote:false,parameters:[]},{id:'test-job',title:'Tests',presentation:'ci',remote:true,parameters:[{id:'ref',title:'Branch',kind:'branch',defaultValue:'',required:true},{id:'plan',title:'Plan',kind:'choice',defaultValue:'SMOKE',choices:['SMOKE','FUNCTIONAL','STATS','FULL'],required:true}]});
fixtureState.interface!.bindings.push({role:'fullCleanup',actionID:'cleanup-all',fields:{}},{role:'derivedDataCleanup',actionID:'cleanup-derived',fields:{}},{role:'uiTests',actionID:'test-job',fields:{branch:'ref',plan:'plan'}});

// Fixture selection is available only in the explicit developer preview.
if(preview){
 const data=new URL(location.href).searchParams.get('data')??'demo';
 if(data==='worst'){
  fixtureContext.branch='feature/infrastructure/dependency-registry-bootstrap-diagnostics';
  fixtureContext.checkoutId='/private/tmp/MimicFixture/MobilePlatformInfrastructureDevelopmentCheckout';
  fixtureState.tasks[0].title='Bootstrap iOS · Mobile Platform Infrastructure';
  fixtureState.builds![0].parameters.scheme='InfrastructureDependencyRegistryConfiguration';
  fixtureState.runs=[{id:'fixture-run',branch:'feature/infrastructure/dependency-registry-bootstrap-diagnostics',plan:'FUNCTIONAL',status:'waiting_for_resource',createdAt:new Date().toISOString(),pipelineID:2811446,jenkinsURL:'https://jenkins.example/job/fixture/1',gitlabURL:'https://gitlab.example/pipelines/2811446',allureURL:'https://allure.example/launch/456',jobs:[{name:'Mobile Platform Infrastructure · UI tests',status:'manual',allowFailure:false,url:'https://gitlab.example/jobs/1'}]}];
 }else if(data==='empty'){fixtureState.tasks=[];fixtureState.builds=[];fixtureState.runs=[];}
 else if(data==='large'){fixtureState.tasks=Array.from({length:1000},(_,index)=>({...fixtureState.tasks[0],id:'fixture-task-'+index}));}
}
let fixtureSimulator:SimulatorState={session:null,activities:[],busy:false,visible:true,version:'27.0',protocolVersion:2};
fixtureState.simulator=fixtureSimulator;
const fixtureSimulatorOptions=new URL(location.href).searchParams;
const fixtureTablet=fixtureSimulatorOptions.get('simModel')==='ipad';
let fixtureLandscape=fixtureSimulatorOptions.get('simOrientation')==='landscape';
const fixtureDevice={id:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',name:fixtureTablet?'iPad Fixture':'iPhone Fixture',runtime:'iOS 27',state:'Booted',deviceTypeIdentifier:fixtureTablet?'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-4th-generation-8GB':'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro'};
const fixtureDevices=fixtureSimulatorOptions.get('simDevices')==='empty'?[]:fixtureSimulatorOptions.get('simDevices')==='two'?[fixtureDevice,{...fixtureDevice,id:'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC',name:'Second Device'}]:[{...fixtureDevice,state:fixtureSimulatorOptions.get('simDevices')==='recent'?'Shutdown':'Booted'}];
const fixtureSimulatorCalls:string[]=[];
if(fixtureSimulatorOptions.has('simProjectless'))fixtureState.context=null;
let fixtureScreenText='Тестовый экран',fixtureCounter=0;
function fixtureFrame():Frame{const canvas=document.createElement('canvas');canvas.width=fixtureLandscape?(fixtureTablet?1194:874):(fixtureTablet?834:402);canvas.height=fixtureLandscape?(fixtureTablet?834:402):(fixtureTablet?1194:874);const context=canvas.getContext('2d')!;context.fillStyle='#f2f2f7';context.fillRect(0,0,canvas.width,canvas.height);context.fillStyle='#202024';context.font='bold 24px system-ui';context.fillText('Mimic · Simulator',24,120);context.font='18px system-ui';context.fillText(fixtureScreenText,24,235);context.fillText('Счётчик: '+fixtureCounter,24,340);return{sessionID:fixtureSimulator.session!.id,revision:fixtureSimulator.session!.revision!,width:canvas.width,height:canvas.height,image:canvas.toDataURL('image/jpeg').split(',')[1],mimeType:'image/jpeg',targets:[{x:24,y:200,width:350,height:60,hitX:200,hitY:230},{x:24,y:300,width:350,height:60,hitX:200,hitY:330}]};}
async function fixtureTool(name:string,args:Record<string,unknown>):Promise<any>{
 if(name.startsWith('simulator_ui_'))fixtureSimulatorCalls.push(String(args.operation??name));
 if(name==='panel_save_tools_preferences'){if(args.expectedRevision!==toolsPreferences.revision)throw new ToolFailure('Conflict','toolsConflict');const value=validateFavorites({revision:toolsPreferences.revision+1,favorites:args.favorites as ToolID[]});fixtureState.toolsPreferences=value;return value;}
 if(name==='panel_get_tool_configuration')return{missing:fixtureToolsMissing,command:'fixture-tool --project /fixture'};

 if(name==='panel_get_ci_details'){
  const identity=String(args.identity),configured=fixtureCIDetails.get(identity);if(configured){if(configured.delay)await new Promise(resolve=>setTimeout(resolve,configured.delay));return structuredClone(configured.value);}
  const summary=(fixtureState.ciSummaries??[]).find(summary=>ciIdentity(summary)===identity);if(!summary)throw new ToolFailure('Fixture run unavailable','notFound');
  return{summary,loadState:'loaded',jobs:[{id:1,name:'fixture-check',status:summary.status,url:'https://ci.example/jobs/1',allowFailure:false}],bridges:[],sha:'fixture-sha',commitTitle:'Fixture commit',gitlabURL:'https://ci.example/pipelines/'+summary.pipelineID};
 }


 if(name==='panel_get_workspace')return fixtureWorkspace;
 if(name==='panel_save_workspace'){fixtureWorkspace=args.workspace as any;return{saved:true};}
 if(name==='panel_save_layout'){
  const fixtureParams=new URL(location.href).searchParams;
  const delay=Number(fixtureParams.get('dragSaveDelay')??0);if(delay>0)await new Promise(resolve=>setTimeout(resolve,Math.min(delay,1000)));
  if(fixtureParams.get('dragSaveFailure')==='failed')throw new ToolFailure('Fixture save failed','unavailable');
  if(fixtureParams.get('dragSaveFailure')==='conflict'){fixtureLayout={...fixtureLayout,revision:fixtureLayout.revision+1};fixtureState.layout=fixtureLayout;throw new ToolFailure('Fixture conflict','layoutConflict');}
  const next=args.layout as Layout;if(args.expectedRevision!==fixtureLayout.revision)throw new ToolFailure(t('layout.conflict'),'layoutConflict');fixtureLayout={...validate(next),revision:fixtureLayout.revision+1};fixtureState.layout=fixtureLayout;return fixtureLayout;}
 if(name==='panel_setup')return{done:true};
 if(name==='panel_branches')return{branches:['develop','feature/mcp']};
 if(name==='panel_branch_preferences'){fixtureState.branchRebase=!!args.enabled;return{enabled:fixtureState.branchRebase};}
 if(name==='panel_switch_branch'){fixtureContext.branch=String(args.branch);return{done:true};}
 if(name==='panel_build_control'){
  const operation=String(args.operation);
  if(operation==='get')return{context:fixtureContext,developerDirectory:fixtureContext.xcode,draft:structuredClone(fixtureBuildDraft),catalogue:fixtureBuildTests?{tests:fixtureBuildTests}:null};
  if(operation==='save'){fixtureBuildDraft=structuredClone(args.parameters as BuildDraft);return{saved:true};}
  if(operation==='product'){const record=fixtureState.builds!.find(record=>record.id===args.activityID) as any;record.selectedProductID=args.productID;record.stage='installation';record.phase='build.phase.installation';return record;}
  fixtureBuildCalls.push(structuredClone(args));
  const record={id:String(args.requestID),title:operation,status:'queued',createdAt:new Date().toISOString(),context:structuredClone(fixtureContext),diagnosticAvailable:false,canCancel:true,tracking:'live',phase:'build.phase.queued',source:'Codex · вручную',actionKey:'build.action.'+(operation==='catalogue'?'catalogue':operation==='tests'?'testsSelected':operation),parameters:{...(args.parameters as any),operation:operation==='tests'?'test':'build',intent:operation==='run'?'run':operation==='catalogue'?'catalogue':null}};
  fixtureState.builds!.unshift(record);return record;
 }
 if(name==='cancel_build_activity'){const record=fixtureState.builds!.find(record=>record.id===args.activityID);if(record){record.status='cancelled';record.canCancel=false;(record as any).finishedAt=new Date().toISOString();record.phase='build.phase.cancelled';}return record;}
 if(name==='start_build_configuration')return{queryID:'fixture-query',status:'ready',result:await fixtureTool('get_build_configuration',args)};
 if(name==='get_build_configuration_state')return{status:'failed',errorCode:'notFound'};
 if(name==='get_build_configuration')return{context:fixtureContext,cli:{schemes:['Fixture','Another'],configurations:['Debug','Release'],destinations:args.scheme?[{id:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',name:'iPhone Fixture'}]:[],testPlans:['Selected']},backends:['cli','xcodeMCP'],xcode:{workspaces:{fixture:'Fixture.xcworkspace'}}};
 if(name==='build_project'||name==='run_selected_tests'){const record={...fixtureState.builds![0],id:String(args.requestID),status:'queued',parameters:{...(args.parameters as any),operation:name==='build_project'?'build':'test'},canCancel:true};fixtureState.builds!.unshift(record);return{activity:record};}
 if(name==='panel_preview_generator'||name==='panel_generate'){const record={actionID:String(args.actionID),toolID:'generation' as ToolID,isPreview:name==='panel_preview_generator',id:String(args.requestID),title:'Fixture generator',status:'succeeded',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:false,canCancel:false};fixtureState.tasks.unshift(record);return record;}
 if(name==='panel_get_preview')return{status:'succeeded',plan:{files:[{path:'Sources/Fixture.swift',exists:false}],digest:'a'.repeat(64)}};
 if(name==='panel_secret_input')return{done:true};
 if(name==='panel_terminal_open')return await fixtureTerminalOpen(args);
 if(name==='panel_terminal_poll')return await fixtureTerminalPoll(args);
 if(name==='panel_terminal_send')return await fixtureTerminalSend(args);
 if(name==='panel_terminal_close'){fixtureChannels.delete(String(args.channelID));return{closed:true};}
 if(name==='get_simulator_configuration'||name==='simulator_ui_observe'&&args.operation==='simulator_ui_devices')return{context:fixtureContext,version:fixtureSimulator.version??'27.0',visible:fixtureSimulator.visible,workspaceAuthorized:!fixtureSimulatorOptions.has('simUnauthorized'),availability:'requiresNativeAccess',deviceProfiles:{[fixtureDevice.deviceTypeIdentifier]:{model:fixtureTablet?'iPad Pro 11-inch (4th generation)':'iPhone 18 Pro',width:fixtureTablet?834:402,height:fixtureTablet?1194:874,radii:fixtureTablet?[18,18,18,18]:[62,62,62,62]}},capabilities:{keys:['backspace','return'],directInputReady:false,adaptiveVideo:true},devices:fixtureDevices,recentIDs:[fixtureDevice.id]};
 if(name==='simulator_ui_observe'){
 const operation=args.operation;
 if(operation==='simulator_ui_attach'){fixtureSimulator.session={id:'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',deviceID:String(args.deviceID),context:fixtureContext,revision:1,ready:true};fixtureState.simulator=fixtureSimulator;return{activity:null,state:fixtureSimulator};}
 if(operation==='simulator_ui_input')return{sessionID:fixtureSimulator.session?.id,generation:'DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD',width:fixtureFrame().width,height:fixtureFrame().height,orientation:fixtureLandscape?'landscapeLeft':'portrait'};
 if(operation==='simulator_ui_input_event'){fixtureSimulatorInputEvents.push(structuredClone(args.event as Record<string,unknown>));const event=args.event as {phase:string;sequence:number};fixtureSimulator.inputOwner=event.phase==='up'||event.phase==='cancel'?null:String(args.viewerID);fixtureSimulator.busy=!!fixtureSimulator.inputOwner;return{accepted:true,sequence:event.sequence};}
 if(operation==='simulator_ui_input_cancel'){fixtureSimulator.inputOwner=null;fixtureSimulator.busy=false;return null;}
 if(operation==='simulator_ui_viewer_heartbeat')return fixtureSimulator;
 if(operation==='simulator_ui_detach'){fixtureSimulator.session=null;return null;}
 if(operation==='simulator_ui_video_stop'||operation==='simulator_ui_video_size')return null;
 if(operation==='simulator_ui_viewer_action')return fixtureTool('simulator_ui_action',args);
 if(operation==='simulator_ui_video')return{mode:'snapshots',reason:'fixture'};
 if(operation==='simulator_ui_frame'&&fixtureFrameError){fixtureFrameError=false;throw new ToolFailure('Fixture session ended','noSession');}
 return fixtureFrame();
 }
 if(name==='get_simulator_activity')return{activity:fixtureSimulator.activities.find(x=>x.id===args.activityID),state:fixtureSimulator};
 if(['start_simulator_session','perform_simulator_action','simulator_ui_action','refresh_simulator_screen','install_simulator_app','close_simulator_session'].includes(name)){
  fixtureSimulatorActions.push(structuredClone(args));const activity:SimulatorActivity={id:String(args.requestID),kind:name,status:'succeeded',queueReleased:false};fixtureSimulator.activities.push(activity);
  if(name==='start_simulator_session')fixtureSimulator.session={id:'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',deviceID:String(args.deviceID),context:fixtureContext,revision:1,ready:true};
  else if(name==='close_simulator_session')fixtureSimulator.session=null;
  else if(fixtureSimulator.session){fixtureSimulator.session.revision!++;const action=args.action as {type:string;text?:string};if(action?.type==='text')fixtureScreenText=action.text??'';if(action?.type==='tap')fixtureCounter++;if(action?.type==='orientation')fixtureLandscape=(action as any).orientation.startsWith('landscape');}
  fixtureState.simulator=fixtureSimulator;return activity;
 }
if(name==='panel_run_tool')name='run_local_action';
if(name==='get_action_configuration'){const action=fixtureState.actions.find(x=>x.id===args.actionID)!;return{context:Object.fromEntries(Object.entries(fixtureContext).reverse()),fields:Object.fromEntries(action.parameters.map(p=>[p.id,{defaultValue:p.defaultValue,choices:p.kind==='boolean'?['true','false']:p.kind==='choice'?['yes','no']:p.choices??[]}]))};}if(name==='get_build_diagnostic')return{task:fixtureState.builds![0],analysisPrompt:'Fixture context\n<diagnostic-data>\nFixture: compilation failed\n</diagnostic-data>',truncated:false};if(name==='get_task_diagnostic')return{task:fixtureState.tasks.find(task=>task.id===args.taskID)!,text:'Fixture: dependency unavailable\nExit status: 1',truncated:false,outputUnavailable:false,analysisPrompt:''};if(name==='list_remote_branches')return{branches:['develop','feature/mcp','feature/very-long-branch-name-for-layout-testing']};if(name==='run_local_action'){if(args.actionID==='prepare'&&fixtureRejectBootstrap){fixtureRejectBootstrap=false;throw new ToolFailure('Fixture admission refused','context');}if(args.actionID==='prepare')fixtureBootstrapLaunches.push(structuredClone(args));const fixtureAction=fixtureState.actions.find(action=>action.id===args.actionID);const task:LocalTask={toolID:fixtureAction?toolForAction(fixtureAction):undefined,isPreview:false,id:String(args.requestID),actionID:String(args.actionID),...(args.actionID==='prepare'?{bootstrap:{platform:((args.parameters as Record<string,string>)?.platform??'ios') as 'ios'|'tvos',phase:'queued',fraction:0}}:{}),title:t(String(args.actionID)),status:'queued',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:false,canCancel:true};fixtureState.tasks.unshift(task);return task;}if(name==='run_remote_action'){const run:Run={id:String(args.requestID),branch:String(((args.parameters as Record<string,string>)?.ref??fixtureContext.branch)),plan:String((args.parameters as Record<string,string>)?.plan),status:'running',createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),pipelineID:123,sha:'fixture-sha',jenkinsURL:'https://jenkins.example/job/fixture/1',gitlabURL:'https://gitlab.example/pipelines/123',allureURL:'https://allure.example/launch/456',jobs:[{name:'UI tests',status:'running',allowFailure:false,url:'https://gitlab.example/jobs/1'}]};fixtureState.runs.unshift(run);return run;}if(name==='cancel_local_task'){const task=fixtureState.tasks.find(x=>x.id===args.taskID);if(task){task.status='cancelled';task.canCancel=false;}}return fixtureState;}
let fixtureFrameError=false;
if(preview){(window as any).mimicSimulatorFixture={failNextFrame:()=>{fixtureFrameError=true;},actions:()=>fixtureSimulatorActions,inputEvents:()=>fixtureSimulatorInputEvents,calls:()=>fixtureSimulatorCalls,agentCommand:()=>{fixtureSimulator.session!.revision!++;accept(fixtureState);render();},setVisible:(visible:boolean)=>{fixtureSimulator.visible=visible;fixtureSimulator.version=visible?'27.0':'26.0';accept(fixtureState);render();},setBusy:(busy:boolean)=>{fixtureSimulator.busy=busy;accept(fixtureState);render();}};}
if(preview){(window as any).mimicCIFixture={set:(summary:CICompactSummary|null)=>{fixtureState.ciSummary=summary;fixtureState.ciSummaries=summary?[summary]:[];state=fixtureState;render();},setRuns:(summaries:CICompactSummary[])=>{fixtureState.ciSummary=summaries[0];fixtureState.ciSummaries=summaries;state=fixtureState;render();},details:(identity:string,value:CIInspection,delay=0)=>fixtureCIDetails.set(identity,{value,delay}),mode:(mode:'mini'|'full'|'expanded')=>{savedLayout=standard();if(mode==='full')resize(savedLayout,'ci','full');fixtureState.layout=savedLayout;expanded=mode==='expanded'?'ci':null;render();},current:()=>fixtureState.ciSummary};}
const fixtureCIDetails=new Map<string,{value:CIInspection;delay:number}>();
let fixtureToolsMissing:string[]=[];
if(preview)(window as any).mimicToolsFixture={
 mode:(mode:'mini'|'full'|'expanded')=>{savedLayout=standard();if(mode==='full')resize(savedLayout,'utils','full');fixtureState.layout=savedLayout;expanded=mode==='expanded'?'utils':null;selectedTool=null;render();},
 tasks:(tasks:LocalTask[])=>{fixtureState.tasks=tasks;accept(fixtureState);render();},
 appearance:(value:unknown)=>{fixtureState.appearance=value;accept(fixtureState);render();},
 favorites:(favorites:ToolID[])=>{toolsPreferences=validateFavorites({revision:toolsPreferences.revision+1,favorites});fixtureState.toolsPreferences=toolsPreferences;render();},
 unavailable:(missing:string[])=>{fixtureToolsMissing=missing;toolConfigurations.clear();render();},
 current:()=>({expanded,selectedTool,toolGenerator,favorites:toolsPreferences.favorites,selection,drafts:Object.fromEntries(actionValues)}),
 context:()=>fixtureContext,
};
/** Preview-only state changes exercise header admission and status without a live checkout. */
if(preview)(window as any).mimicBuildFixture={
 calls:()=>fixtureBuildCalls,
 mode:(mode:'mini'|'full'|'extended')=>{savedLayout=standard();savedLayout.rows=[{id:'build-fixture',slots:mode==='mini'?['builds','derivedDataCleanup']:['builds']},...(mode==='mini'?[]:[{id:'build-neighbour',slots:['derivedDataCleanup'] as (Block|null)[]}]),{id:'build-bootstrap-neighbour',slots:['bootstrap']}];fixtureState.layout=savedLayout;expanded=mode==='extended'?'builds':null;render();},
 empty:()=>{fixtureState.builds=[];render();},
 task:(status:string,stage='compilation',count:number|null=null)=>{let record=fixtureState.builds![0] as any;if(!record){record={id:crypto.randomUUID(),parameters:{...fixtureBuildDraft,intent:'run'},context:structuredClone(fixtureContext),source:'Codex',createdAt:new Date().toISOString(),actionKey:'build.action.run'};fixtureState.builds!.unshift(record);}record.status=status;record.stage=stage;record.canCancel=['queued','preparing','running'].includes(status);record.startedAt??=new Date(Date.now()-63000).toISOString();record.finishedAt=record.canCancel?null:new Date().toISOString();record.phase='build.phase.'+(status==='running'?stage==='compilation'?'running':stage:status);record.completedStages=count;record.progressTotal=3;record.progressFraction=status==='succeeded'?1:count==null?null:count/3;if(record.parameters.intent==='catalogue'&&status==='succeeded')fixtureBuildTests=['testOne()','testTwo()','testAnother()'].map((name,index)=>({id:'FixtureTests/'+(index===2?'Other':'Checkout')+'/'+name,target:'FixtureTests',className:index===2?'Other':'Checkout',name}));render();},
 products:()=>{const record=fixtureState.builds![0] as any;record.stage='products';record.phase='build.phase.products';record.status='running';record.products=[1,2].map(i=>({path:'/fixture/App'+i+'.app',name:'App'+i,bundleIdentifier:'fixture.app'+i}));render();},
 changeContext:()=>{fixtureContext.sha+='-next';accept(fixtureState);render();},
 draft:()=>fixtureBuildDraft,
};
if(preview)(window as any).mimicChromeFixture={update:(patch:Partial<State>)=>{Object.assign(fixtureState,patch);accept(fixtureState);render();}};
// MARK: - Quiet status notifications
const notificationNode=element('p','','banner');notificationNode.setAttribute('role','status');notificationNode.setAttribute('aria-live','polite');root.prepend(notificationNode);
const observedStatuses=new Map<string,string>();
function notifyChanges(next:State){if(next.notices){for(const item of next.notices)notificationNode.textContent=item.title+' · '+item.body;return;}for(const item of [...next.tasks,...(next.builds??[]),...next.runs]){const previous=observedStatuses.get(item.id);observedStatuses.set(item.id,item.status);if(previous&&previous!==item.status&&['succeeded','success','failed','interrupted','unknown'].includes(item.status)){notificationNode.textContent=('title'in item?item.title:item.branch)+' · '+t(['succeeded','success'].includes(item.status)?'notification.completed':'notification.failed');}}}
// MARK: - Disposable preview contracts; never connected to a real executor
let fixtureLayout=standard();
if(preview&&new URL(location.href).searchParams.get('layout')==='empty')fixtureLayout.rows=[];
if(preview&&new URL(location.href).searchParams.get('layout')==='one')fixtureLayout.rows=fixtureLayout.rows.slice(0,1);
if(preview&&new URL(location.href).searchParams.get('layout')==='all')fixtureLayout.rows=catalog.map(block=>({id:crypto.randomUUID(),slots:[block]}));
let fixtureWorkspace:{expanded?:Block;selection?:string;drafts:Record<string,Record<string,string>>}={drafts:{}};fixtureState.layout=fixtureLayout;fixtureState.workspace=fixtureWorkspace;
for(const role of ['generateUI','generateSicilia','generateGalera','localization','protocols','format','fullCleanup','derivedDataCleanup','qualityGates','beta']){
 const remote=['qualityGates','beta'].includes(role),generator=role.startsWith('generate');
 const parameters:Action['parameters']=generator?[{id:'name',title:t('generator.name'),kind:'text',defaultValue:'Fixture',required:true}]:role==='qualityGates'?[{id:'branch',title:t('branch'),kind:'branch',defaultValue:'develop',required:true},...['swiftLint','unusedCode','tests'].map(id=>({id,title:id,kind:'boolean',defaultValue:'true',required:true}))]:role==='beta'?[{id:'branch',title:t('branch'),kind:'branch',defaultValue:'develop',required:true},...['target','rebase','upload'].map(id=>({id,title:id,kind:'choice',defaultValue:'yes',choices:[],required:true}))]:[];
 fixtureState.actions.push({id:role,title:blockTitle(role as Block),presentation:generator?'generator':remote?'ci':'regular',remote,parameters});fixtureState.interface!.bindings.push({role,actionID:role,fields:Object.fromEntries(parameters.map(p=>[p.id,p.id]))});
}
const fixtureBootstrapLaunches:Record<string,unknown>[]=[],fixtureTranscripts=new Map<string,string>();let fixtureRejectBootstrap=false;
let fixtureSentMessage='',fixtureInputCount=0;
/** Preview-only control of the data boundary, shared by layout/terminal acceptance fixtures. */
if(preview)(window as any).mimicBootstrapFixture={
 launches:fixtureBootstrapLaunches,
 mode(mode:'mini'|'full'|'expanded'){
  savedLayout=standard();if(mode==='mini')resize(savedLayout,'bootstrap','mini');fixtureState.layout=structuredClone(savedLayout);expanded=mode==='expanded'?'bootstrap':null;
  render();
 },
 task(status:string,platform:'ios'|'tvos'='ios',reuse=false,error='',retainHistory=false){
  const previous=fixtureState.tasks.find(task=>task.bootstrap),id=reuse&&previous?previous.id:crypto.randomUUID();
  const task:LocalTask={id,actionID:'prepare',title:t('bootstrap_'+platform),bootstrap:{platform,phase:status,fraction:status==='succeeded'?1:.4,stages:['dependencies','uiTests','setup'],currentStage:status==='running'?'uiTests':null,completedStages:status==='succeeded'?['dependencies','uiTests','setup']:status==='running'?['dependencies']:[]},status,context:fixtureContext,createdAt:new Date().toISOString(),startedAt:new Date(Date.now()-41000).toISOString(),finishedAt:['queued','running','blocked'].includes(status)?null:new Date().toISOString(),canCancel:['queued','running','blocked'].includes(status),diagnosticAvailable:['failed','interrupted'].includes(status),error};
  if(status==='blocked'){task.status='queued';task.bootstrap!.phase='blocked';}
  fixtureState.tasks=fixtureState.tasks.filter(task=>task.id!==id&&(retainHistory||!task.bootstrap));fixtureState.tasks.unshift(task);
  if(!fixtureTranscripts.has(id))fixtureTranscripts.set(id,'Mimic fixture terminal\r\n');accept(fixtureState);render();return id;
 },
 output(taskID:string,text:string){fixtureTranscripts.set(taskID,(fixtureTranscripts.get(taskID)??'')+text);},
 unavailable(taskID:string){fixtureTranscripts.set(taskID,'');},
 refreshContext(){fixtureState.context={...fixtureContext,sha:'updated-fixture-sha'};accept(fixtureState);render();},
 rejectNext(){fixtureRejectBootstrap=true;},
 empty(){fixtureState.tasks=fixtureState.tasks.filter(task=>!task.bootstrap);accept(fixtureState);render();},
 disconnected(value:boolean){stale=value;render();},
 missingContext(value:boolean){fixtureState.context=value?null:fixtureContext;accept(fixtureState);render();},
 get sent(){return fixtureSentMessage;},get inputCount(){return fixtureInputCount;},
};
const fixtureChannels=new Map<string,{id:string;taskID:string;threadID:string;key:CryptoKey;sent:number;received:number;last:string}>();
const fixtureBytes=(value:string)=>Uint8Array.from(atob(value),c=>c.charCodeAt(0)),fixture64=(value:Uint8Array)=>btoa(Array.from(value,b=>String.fromCharCode(b)).join(''));
async function fixtureTerminalOpen(args:Record<string,unknown>){const pair=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},false,['deriveBits']),peer=await crypto.subtle.importKey('raw',fixtureBytes(String(args.publicKey)),{name:'ECDH',namedCurve:'P-256'},false,[]),secret=await crypto.subtle.deriveBits({name:'ECDH',public:peer},pair.privateKey,256),material=await crypto.subtle.importKey('raw',secret,'HKDF',false,['deriveKey']),id=crypto.randomUUID().toUpperCase(),taskID=String(args.taskID),threadID='fixture-thread',key=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:new TextEncoder().encode(id),info:new TextEncoder().encode('mimic-panel-terminal-v1')},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);fixtureChannels.set(id,{id,taskID,threadID,key,sent:0,received:0,last:''});return{channelID:id,taskID,threadID,publicKey:fixture64(new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey)))};}
async function fixtureTerminalPoll(args:Record<string,unknown>){
 const c=fixtureChannels.get(String(args.channelID))!,task=fixtureState.tasks.find(task=>task.id===c.taskID),snapshot=fixtureTranscripts.get(c.taskID)??'Mimic fixture terminal\r\n',reset=!snapshot.startsWith(c.last),output=reset?snapshot:snapshot.slice(c.last.length);c.last=snapshot;
 const sequence=++c.sent,iv=crypto.getRandomValues(new Uint8Array(12)),aad=new TextEncoder().encode(`${c.id}|${c.taskID}|${c.threadID}|output|${sequence}`),plaintext=new TextEncoder().encode(stableJSON({bytes:fixture64(new TextEncoder().encode(output)),reset,canInput:task?.status==='running',outputAvailable:!!snapshot,finished:!!task&&!['queued','running'].includes(task.status)})),encrypted=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad},c.key,plaintext)),combined=new Uint8Array(12+encrypted.length);combined.set(iv);combined.set(encrypted,12);return{sequence,data:fixture64(combined)};
}
async function fixtureTerminalSend(args:Record<string,unknown>){const c=fixtureChannels.get(String(args.channelID))!,packet=args.packet as {sequence:number;data:string};if(packet.sequence!==c.received+1)throw new Error('sequence');const data=fixtureBytes(packet.data);const plaintext=await crypto.subtle.decrypt({name:'AES-GCM',iv:data.slice(0,12),additionalData:new TextEncoder().encode(`${c.id}|${c.taskID}|${c.threadID}|input|${packet.sequence}`)},c.key,data.slice(12));if(JSON.parse(new TextDecoder().decode(plaintext)).input)fixtureInputCount++;c.received=packet.sequence;return{accepted:true};}


app.onteardown=async()=>{clearInterval(bootstrapClock);cardDrag.cancel();await detailsTerminal?.dispose();await bootstrapTerminal?.dispose();await simulatorPanel.dispose();return {};};
app.ontoolresult=params=>{if(params.structuredContent){accept({...params.structuredContent,...(params._meta?.['mimic/workspace'] as object??{})} as State);render();}};
function hostStyle(context:ReturnType<App['getHostContext']>){if(context?.theme)applyDocumentTheme(context.theme);if(context?.styles?.variables)applyHostStyleVariables(context.styles.variables);updateBootstrap();}
for(const query of ['(prefers-color-scheme: dark)','(prefers-contrast: more)'])matchMedia(query).addEventListener('change',()=>updateBootstrap());
app.onhostcontextchanged=context=>hostStyle(context);
render();
if(preview){accept(fixtureState);render();}else{void app.connect().then(()=>{hostStyle(app.getHostContext());simulatorHost.dataset.hostConnectDomains=JSON.stringify(app.getHostCapabilities()?.sandbox?.csp?.connectDomains??[]);return refresh();}).catch(()=>{error=t('connecting');render();});}
setInterval(()=>{if(!busy&&document.visibilityState==='visible')void refresh();},5000);
