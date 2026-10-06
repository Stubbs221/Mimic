// Created by Василий Маслов on 04.10.2026.
import { App, applyDocumentTheme, applyHostStyleVariables } from '@modelcontextprotocol/ext-apps';
import { OpenAIExtensions } from '@openai/mcp-extensions/app';
import ru from './ru.json';
import {renderCompactRuns,middleText,ciIdentity,type CICompactSummary} from './ci-compact';
import {PanelCIView,type CIInspection} from './ci-details';
import {catalog,standard,validate,change,remove,add,move,resize,replace,insert,type InsertionTarget,type Block,type Layout} from './layout';
import {applyRemoteDefaults} from './remote-parameters';
import {PrivateTerminal} from './terminal';
import {HoldGesture,scrollSpeed,DragResize,resizeZone} from './drag-gesture';

type Context={checkoutId:string;branch:string;sha:string;xcode:string;appleTarget:unknown;profileID:string|null;profileRevision:string|null};
type Action={id:string;title:string;presentation:string;remote:boolean;parameters:{id:string;title:string;kind:string;defaultValue:string;choices?:string[];required:boolean;visibleWhen?:Record<string,string>}[]};
/** Wire object order is unspecified; identity and idempotency fingerprints must be canonical. */
function stableJSON(value:unknown):string{return JSON.stringify(value,(_key,item)=>item&&typeof item==='object'&&!Array.isArray(item)?Object.fromEntries(Object.keys(item).sort().map(key=>[key,item[key]])):item)??'';}
const actionValues=new Map<string,Record<string,string>>();
const remoteFields=new Map<string,Record<string,{defaultValue:string;choices:string[]}>>();
type LocalTask={id:string;actionID?:string;title:string;status:string;createdAt:string;context:Context;diagnosticAvailable:boolean;canCancel:boolean;needsInput?:boolean;progress?:string|null;startedAt?:string|null;finishedAt?:string|null;error?:string|null;bootstrap?:{platform:'ios'|'tvos';phase:string;fraction:number;stages?:string[];currentStage?:string|null;completedStages?:string[]}};
type Build=LocalTask&{tracking:string;phase:string;source:string;duration?:number;parameters:{operation:string;backend:string;scheme:string;configuration:string;destinationID:string;workspaceTab:string};errorCount?:number;warningCount?:number};
type Run={id:string;actionID?:string;branch:string;plan:string;status:string;createdAt:string;updatedAt?:string;error?:string;jenkinsURL?:string;gitlabURL?:string;allureURL?:string;pipelineID?:number;sha?:string;jobs:{name:string;status:string;allowFailure:boolean;url:string}[]};
type SimulatorSession={id:string;deviceID:string;context:Context;revision:number|null;ready:boolean};
type SimulatorActivity={id:string;kind:string;status:string;errorCode?:string;queueReleased:boolean};
type SimulatorState={session:SimulatorSession|null;activities:SimulatorActivity[];busy:boolean};
type UIBinding={role:string;actionID:string;fields:Record<string,string>};
type UIInterface={version:number;bindings:UIBinding[]};
type State={ciSummaries?:CICompactSummary[];ciSummary?:CICompactSummary|null;notices?:{id:string;taskID:string;title:string;body:string}[];layout?:Layout;workspace?:{expanded?:Block;selection?:string;drafts?:Record<string,Record<string,string>>};needsBinding?:boolean;queue?:LocalTask[];interface?:UIInterface|null;simulator?:SimulatorState;context:Context|null;actions:Action[];tasks:LocalTask[];builds?:Build[];runs:Run[];jenkinsConfigured:boolean;progress?:string};
type Diagnostic={task:LocalTask;text:string;truncated:boolean;outputUnavailable:boolean;analysisPrompt:string};
const t=(key:string)=>(ru as Record<string,string>)[key]??key;
const shell=document.querySelector<HTMLElement>('#app')!;
const root=document.createElement('div');
const simulatorHost=document.createElement('section');
simulatorHost.className='card simulator';
const header=document.createElement('header');
header.append(element('h1',t('title')),button(t('refresh'),()=>void refresh(),false,'quiet'));
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
 if(name==='simulator_ui_observe')return result._meta?.['mimic/simulator'];
 if(name.startsWith('panel_'))return result._meta?.['mimic/private'];
 const value=result.structuredContent??JSON.parse(text||'{}');return ['open_panel','get_state'].includes(name)?{...value,...(result._meta?.['mimic/workspace'] as object??{})}:value;
}
function releaseRejectedRequest(key:string,error:unknown){if(error instanceof ToolFailure&&!['unavailable','unknown'].includes(error.code))pendingIDs.delete(key);}
async function refresh(){try{const next=await tool('get_state') as State;accept(next);stale=false;render();}catch{stale=true;render();}}
function accept(next:State){if(!next||!Array.isArray(next.tasks)||!Array.isArray(next.runs))return;const old=stableJSON(state?.context),oldCheckout=state?.context?.checkoutId;state=next;for(const id of actionValues.keys())if(!next.actions.some(a=>a.id===id))actionValues.delete(id);updateSimulator();if(!selectedBranch)selectedBranch=next.context?.branch??'';if(old!==stableJSON(next.context)){if(oldCheckout!==next.context?.checkoutId){bootstrapTerminalTask=null;bootstrapFailedAttempt=null;void bootstrapTerminal?.detach();}bootstrapLaunchError='';if(diagnosticSource==='bootstrap')diagnostic=null;remoteFields.clear();buildCatalogue=null;previews.clear();branches=[];selectedBranch=next.context?.branch??'';simulatorConfig=null;void syncContext();}if(selection?.type==='task'&&!next.tasks.some(x=>x.id===selection?.id))selection=null;if(selection?.type==='run'&&!next.runs.some(x=>x.id===selection?.id))selection=null;if(selection?.type==='build'&&!next.builds?.some(x=>x.id===selection?.id))selection=null;notifyChanges(next);}
async function perform(operation:()=>Promise<void>){if(busy)return;busy=true;error='';notice='';render();try{await operation();}catch(e){showError(e);}finally{busy=false;render();}}
function selectItem(type:'task'|'run'|'build',id:string){selection={type,id};historyOpen=true;diagnostic=null;scheduleWorkspace();notice='';render();void syncContext();}
async function syncContext(){if(!state||preview)return;const selected=selection?.type==='build'?state.builds?.find(x=>x.id===selection?.id):selection?.type==='task'?state.tasks.find(x=>x.id===selection?.id):selection?.type==='run'?state.runs.find(x=>x.id===selection?.id):undefined;const metadata={context:state.context,selection:selection?{type:selection.type,id:selection.id,status:selected?.status}:null};try{if(extensions.modelContext)await extensions.modelContext.update({structuredContent:metadata});else await app.updateModelContext({structuredContent:metadata});}catch{/* Older clients can still use tools; selection never sends diagnostics. */}}
function cleanFragment(value:string,limit:number){const cleaned=value.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g,'').replace(/\b(glpat-[\w-]+|gh[pousr]_[\w]+|sk-[\w-]{12,}|eyJ[\w-]+\.[\w-]+\.[\w-]+)\b/g,'[REDACTED]').replace(/((?:proxy-)?authorization\s*[:=]\s*)[^\n]+/gi,'$1[REDACTED]').replace(/(\b[\w]*(?:TOKEN|PASSWORD|PASSWD|SECRET|API[_-]?KEY)\b["']?\s*[:=]\s*)(?:"[^"\n]*"|'[^'\n]*'|[^\s&,;\n]+)/gi,'$1[REDACTED]');const bytes=new TextEncoder().encode(cleaned);let start=Math.max(0,bytes.length-limit);while(start<bytes.length&&(bytes[start]&0xc0)===0x80)start++;return new TextDecoder().decode(bytes.slice(start));}
function requestID(key:string){let id=pendingIDs.get(key);if(!id){id=crypto.randomUUID();pendingIDs.set(key,id);}return id;}
async function runAction(action:Action,preserveView=false,onRequest?:(id:string)=>void){await perform(async()=>{const parameters=actionValues.get(action.id)??{};const key=stableJSON([action.id,parameters,state?.context]),id=requestID(key);onRequest?.(id);try{const result=await tool(action.remote?'run_remote_action':'run_local_action',{actionID:action.id,parameters,context:state?.context,requestID:id});pendingIDs.delete(key);if(!preserveView)selection={type:action.remote?'run':'task',id:result.id};await refresh();await syncContext();}catch(error){releaseRejectedRequest(key,error);throw error;}});}
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
let savedLayout:Layout=standard(),editLayout:Layout|null=null,expanded:Block|null=null,catalogOpen=false,historyOpen=false,settingsOpen=false,workspaceLoaded=false,saveTimer:ReturnType<typeof setTimeout>|undefined;
let layoutOrigin:Layout|null=null;
const ciView=new PanelCIView(tool,t,link);
function ciSummaries(){return state?.ciSummaries??(state?.ciSummary?[state.ciSummary]:[]);}
function openCI(summary:CICompactSummary){if(editLayout||blockDrag||layoutSaving)return;ciView.select(summary);if(expanded!=='ci')animateGrid(()=>{expanded='ci';catalogOpen=false;renderGrid();});scheduleWorkspace();}
const blockNodes=new Map<Block,{node:HTMLElement;title:HTMLButtonElement;summary:HTMLElement;content:HTMLElement;editor:HTMLElement}>();
const formNodes=new Map<string,{signature:string;node:HTMLElement;update:()=>void}>();
const previews=new Map<string,{taskID:string;fingerprint:string;plan?:{files:{path:string;exists:boolean}[];digest:string;canGenerate?:boolean}}>();
let buildValues:Record<string,string>={backend:'cli',scheme:'',configuration:'',destinationID:'',workspaceTab:'',testPlan:'',testIdentifiers:'',simulatorConfirmed:'false'};
let buildCatalogue:any=null;
const contextLabel=element('span'),workStatus=button('',()=>{const active=[...state!.tasks.map(t=>({...t,type:'task' as const})),...(state!.builds??[]).map(t=>({...t,type:'build' as const}))].find(t=>['running','preparing'].includes(t.status));if(active)selectItem(active.type,active.id);historyOpen=true;render();},false,'quiet');contextBar.append(contextLabel,workStatus);
let detailSignature='';let detailsTerminal:PrivateTerminal|null=null;
function currentLayout(){return dragLayout??editLayout??savedLayout;}
function blockTitle(block:Block){return t('block.'+block);}
function scheduleWorkspace(){if(preview||!workspaceLoaded)return;clearTimeout(saveTimer);saveTimer=setTimeout(()=>{void tool('panel_save_workspace',{workspace:{expanded,selection:selection?selection.type+':'+selection.id:null,drafts:{...Object.fromEntries(actionValues),builds:buildValues}}}).catch(showError);},350);}
function installWorkspace(next:State){
 if(!editLayout&&!blockDrag&&!layoutSaving&&next.layout&&next.layout.revision>=savedLayout.revision){try{savedLayout=validate(next.layout);}catch{/* Keep the last valid layout. */}}
 if(!workspaceLoaded&&next.context&&next.workspace!==undefined){workspaceLoaded=true;for(const form of formNodes.values())form.signature='';const workspace=next.workspace;expanded=workspace?.expanded??null;for(const [id,values]of Object.entries(workspace?.drafts??{})){if(id==='builds')buildValues={...buildValues,...values};else if(next.actions.some(a=>a.id===id))actionValues.set(id,Object.fromEntries(Object.entries(values).filter(([field])=>next.actions.find(a=>a.id===id)!.parameters.some(p=>p.id===field))));}if(workspace?.selection){const [type,...parts]=workspace.selection.split(':');if(['task','run','build'].includes(type))selection={type:type as 'task'|'run'|'build',id:parts.join(':')};}}
}
function edit(operation:(layout:Layout)=>void){if(!editLayout)return;try{animateGrid(()=>{editLayout=change(editLayout!,operation);renderGrid();});}catch(e){showError(e instanceof Error?new Error(t(e.message)):e);}}
function openBlock(block:Block){if(editLayout||blockDrag||layoutSaving)return;if(block==='ci'&&expanded!=='ci'&&ciSummaries()[0])ciView.select(ciSummaries()[0]);animateGrid(()=>{expanded=expanded===block?null:block;catalogOpen=false;renderGrid();});scheduleWorkspace();}
function beginEdit(){if(blockDrag||layoutSaving)return;for(const view of blockNodes.values())view.editor.dataset.layout='';layoutOrigin=structuredClone(savedLayout);editLayout=structuredClone(savedLayout);expanded=null;catalogOpen=false;render();}
async function finishEdit(){if(!editLayout)return;await perform(async()=>{const layout=await tool('panel_save_layout',{layout:editLayout,expectedRevision:layoutOrigin!.revision});savedLayout=validate(layout);editLayout=null;layoutOrigin=null;scheduleWorkspace();});}
function cancelEdit(){cancelBlockDrag();editLayout=null;layoutOrigin=null;render();}
function editMenu(block:Block){const host=element('details','','placement-menu'),summary=element('summary',t('layout.options'));host.append(summary);const list=element('div','','placement-actions');
 const size=currentLayout().rows.find(r=>r.slots.includes(block))!.slots.length;
 list.append(button(t(size===1?'layout.mini':'layout.full'),()=>edit(l=>resize(l,block,size===1?'mini':'full'))));
 const rows=currentLayout().rows,index=rows.findIndex(r=>r.slots.includes(block));
 list.append(button(t('layout.up'),()=>edit(l=>move(l,block,l.rows[index-1]?.id)),index===0),button(t('layout.down'),()=>edit(l=>move(l,block,l.rows[index+2]?.id)),index===rows.length-1));
 const replacement=element('select');replacement.setAttribute('aria-label',t('layout.replace'));replacement.append(new Option(t('layout.replace'),''));for(const kind of catalog.filter(b=>!currentLayout().rows.some(r=>r.slots.includes(b))))replacement.append(new Option(blockTitle(kind),kind));replacement.onchange=()=>{if(replacement.value)edit(l=>replace(l,block,replacement.value as Block));};list.append(replacement);
 if(size===2){const join=element('select');join.setAttribute('aria-label',t('layout.join'));join.append(new Option(t('layout.join'),''));for(const row of rows.filter(r=>r.slots.length===2&&r.slots.some(x=>x===null)&&!r.slots.includes(block))){join.append(new Option(row.slots.map(b=>b?blockTitle(b):t('layout.empty')).join(' · '),row.id));}join.onchange=()=>edit(l=>move(l,block,join.value,rows.find(r=>r.id===join.value)!.slots.indexOf(null)));list.append(join);}
 list.append(button(t('layout.remove'),()=>edit(l=>remove(l,block))));host.append(list);return host;
}
function blockStatus(block:Block){
 const pending=(item:{status:string})=>['queued','preparing','running','triggering','pending'].includes(item.status);
 if(block==='builds'){const item=state?.builds?.find(pending)??state?.builds?.[0];return item?t(item.needsInput?'notification.input':item.status):t('ready');}
 if(block==='simulators'){const item=state?.simulator?.activities.find(pending);return item?t(item.status):state?.simulator?.session?t('sim.active'):t('ready');}
 const roles=block==='utils'?['generateUI','generateSicilia','generateGalera','localization','protocols','format','fullCleanup','derivedDataCleanup']:block==='ci'?['uiTests','qualityGates','beta']:[block];
 const ids=new Set(state?.interface?.bindings.filter(binding=>roles.includes(binding.role)).map(binding=>binding.actionID));const items=[...(state?.tasks??[]),...(state?.runs??[])].filter(item=>item.actionID&&ids.has(item.actionID)).sort((a,b)=>b.createdAt.localeCompare(a.createdAt));const item=items.find(pending)??items[0];return item?t('needsInput'in item&&item.needsInput?'notification.input':item.status):t('ready');
}
function blockAccent(block:Block){return block==='bootstrap'?'#4F7CAC':block==='builds'?'#7166A5':['ci','uiTests','qualityGates','beta'].includes(block)?'#768D60':block==='simulators'?'#4F8D9E':'#438B82';}
function blockIcon(block:Block){const path=block==='bootstrap'?'<path d="m3 6 9-4 9 4v12l-9 4-9-4Z M3 6l9 4 9-4 M12 10v12 M7 4l10 4"/>':block==='builds'?'<path d="m14 3 7 7-3 3-3-3L5 21l-3-3L13 7l-2-2Z"/>':block==='simulators'?'<rect x="6" y="2" width="12" height="20" rx="2"/><path d="M10 5h4 M11 19h2"/>':['ci','uiTests','qualityGates','beta'].includes(block)?'<path d="m12 2 3 3 4 1 1 4 2 2-2 3-1 4-4 1-3 2-3-2-4-1-1-4-2-3 2-2 1-4 4-1Z M7 12l3 3 6-6"/>':'<path d="M14 3a6 6 0 0 0-7 7L2 17l5 5 7-7a6 6 0 0 0 7-7l-4 4-4-4 4-4Z"/>';return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">'+path+'</svg>';}
function renderGrid(){
 const visualExpanded=blockDrag?.gesture.phase==='dragging'?null:expanded;
 const layout=currentLayout(),rows=structuredClone(layout.rows);gridHost.dataset.layoutRevision=String(layout.revision);if(visualExpanded&&!rows.some(r=>r.slots.includes(visualExpanded)))rows.unshift({id:'transient',slots:[visualExpanded]});
 const narrow=compactMedia.matches;const visualRow=(index:number,slot=0)=>narrow?rows.slice(0,index).reduce((total,row)=>total+row.slots.length,0)+slot+1:index+1;
 gridHost.style.gridTemplateRows=rows.flatMap(row=>Array(narrow?row.slots.length:1).fill('auto')).join(' ')+(editLayout||blockDrag?.gesture.phase==='dragging'?' 32px':'');
 for(const block of catalog){let view=blockNodes.get(block);if(!view){const node=element('section','','card panel-block');node.dataset.block=block;const title=button('',()=>openBlock(block),false,'block-title');const icon=element('span','','block-icon');icon.setAttribute('aria-hidden','true');icon.innerHTML=blockIcon(block);title.append(icon,element('span',blockTitle(block),'block-name'));node.title=t('layout.drag.hint');node.onpointerdown=event=>startBlockDrag(event,block);const summary=element('div','','block-summary');const content=element('div','','block-content'),editor=element('div','','block-editor');node.append(title,summary,editor,content);view={node,title,summary,content,editor};node.onclick=event=>{if(!editLayout&&!blockDrag&&!layoutSaving&&!isBlockControl(event.target as HTMLElement))openBlock(block);};blockNodes.set(block,view);gridHost.append(node);}
  const rowIndex=rows.findIndex(r=>r.slots.includes(block)),row=rows[rowIndex];const peer=!!row&&!!visualExpanded&&row.slots.includes(visualExpanded)&&visualExpanded!==block;
  view.node.hidden=rowIndex<0||peer;view.node.inert=peer||rowIndex<0;view.node.setAttribute('aria-hidden',String(peer||rowIndex<0));if(!row)continue;
  const isExpanded=visualExpanded===block&&!editLayout;const showFullBootstrap=block==='bootstrap'&&row.slots.length===1&&!editLayout;view.node.style.gridRow=isExpanded&&narrow&&row.slots.length===2?`${visualRow(rowIndex)} / span 2`:String(visualRow(rowIndex,row.slots.indexOf(block)));view.node.style.gridColumn=narrow||isExpanded||row.slots.length===1?'1 / -1':String(row.slots.indexOf(block)+1);view.node.classList.toggle('full-bootstrap',showFullBootstrap);view.node.style.setProperty('--block-accent',blockAccent(block));view.node.classList.toggle('expanded',isExpanded);view.node.classList.toggle('mini',row.slots.length===2&&!isExpanded);
  view.title.setAttribute('aria-expanded',String(isExpanded));view.title.disabled=!!editLayout;view.content.hidden=block==='bootstrap'?!!editLayout:!isExpanded&&!showFullBootstrap;view.content.inert=view.content.hidden;view.summary.hidden=block==='bootstrap'||isExpanded||showFullBootstrap||!!editLayout;view.editor.hidden=!editLayout;
  if(block==='ci'){
   const summaries=ciSummaries();
   ciView.update(summaries,state?.context?.checkoutId,isExpanded);
   renderCompactRuns(view.summary,summaries.slice(0,row.slots.length===1&&!narrow?2:1),t,openCI);
   let project=view.title.querySelector<HTMLElement>('.ci-project');if(!project){project=element('span','','ci-project');view.title.append(project);}
   const checkout=state?.context?.checkoutId??summaries[0]?.checkout;
   project.hidden=!checkout;if(checkout){middleText(project,'· '+checkout.split('/').filter(Boolean).at(-1));project.title=checkout;}
  }else{view.summary.textContent=blockStatus(block);view.summary.title=view.summary.textContent;}view.title.title=blockTitle(block)+'\n'+t('layout.drag.hint');
  if(editLayout&&view.editor.dataset.layout!==stableJSON(layout)){view.editor.dataset.layout=stableJSON(layout);const grip=button(t('layout.drag'),()=>{},false,'drag-handle');grip.setAttribute('aria-label',t('layout.drag')+' '+blockTitle(block));grip.onkeydown=event=>{if(event.key==='ArrowUp'||event.key==='ArrowDown'){event.preventDefault();const index=editLayout!.rows.findIndex(r=>r.slots.includes(block));if(event.key==='ArrowUp'&&index>0)edit(l=>move(l,block,l.rows[index-1].id));if(event.key==='ArrowDown')edit(l=>move(l,block,l.rows[index+2]?.id));}};view.editor.replaceChildren(grip,editMenu(block));}
  if(block==='bootstrap'){ensureBootstrapContent(view.content);updateBootstrap(isExpanded? 'expanded':row.slots.length===1?'full':'mini',!!editLayout||view.node.hidden);}else if(isExpanded||showFullBootstrap)ensureBlockContent(block,view.content);
 }
 const hasTargets=!!editLayout||blockDrag?.gesture.phase==='dragging';const placeholders=hasTargets?stableJSON(layout)+narrow+!!editLayout:'';if(gridHost.dataset.placeholders!==placeholders){gridHost.dataset.placeholders=placeholders;gridHost.querySelectorAll('.empty-slot,.grid-end').forEach(n=>n.remove());
 if(hasTargets){for(const [index,row]of rows.entries())if(row.slots.length===2)for(const slot of [0,1])if(row.slots[slot]===null){const empty=element('div','','empty-slot');empty.dataset.row=row.id;empty.dataset.slot=String(slot);empty.style.gridRow=String(visualRow(index,slot));empty.style.gridColumn=narrow?'1 / -1':String(slot+1);empty.classList.toggle('drag-slot',!editLayout);const choose=element('select');choose.setAttribute('aria-label',t('layout.add'));choose.append(new Option(t('layout.add'),''));for(const kind of catalog.filter(b=>!layout.rows.some(r=>r.slots.includes(b))))choose.append(new Option(blockTitle(kind),kind));choose.onchange=()=>edit(l=>{add(l,choose.value as Block,'mini');move(l,choose.value as Block,row.id,slot);});if(editLayout)empty.append(choose);gridHost.append(empty);}
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
// MARK: - Direct card gesture (the source node is never cloned or reparented)
type DragCell={row:string;slot:number;full:boolean;x:number;y:number;width:number;height:number};
type BlockDrag={block:Block;node:HTMLElement;pointer:number;gesture:HoldGesture;origin:Layout;cells:DragCell[];grab:{x:number;y:number};x:number;y:number;hold:ReturnType<typeof setTimeout>;frame:number;lastTick:number;target:InsertionTarget|null;signature:string;editing:boolean;resize:DragResize;anchor:{x:number;y:number};rowIDs:string[];morph:Animation|null};
let blockDrag:BlockDrag|null=null,dragLayout:Layout|null=null,layoutSaving=false,suppressDragClick=false;
const compactMedia=matchMedia('(max-width:479px)');
compactMedia.addEventListener('change',()=>{cancelBlockDrag();renderGrid();});
function logicalBox(node:HTMLElement){const grid=gridHost.getBoundingClientRect();return{x:grid.x+node.offsetLeft,y:grid.y+node.offsetTop,width:node.offsetWidth,height:node.offsetHeight};}
// Surface clicks and drag presses exclude the same nested interactive regions.
function isBlockControl(target:HTMLElement){return !!target.closest('button,input,select,textarea,a,summary,[contenteditable],[role=button],[role=link],.terminal-host,.sim-viewport,.simulator-image,.placement-menu');}
function dragEligible(target:HTMLElement){return !!target.closest('.block-title,.drag-handle')||!isBlockControl(target);}
function startBlockDrag(event:PointerEvent,block:Block){
 if(event.button!==0||blockDrag||layoutSaving||busy||!dragEligible(event.target as HTMLElement)||!currentLayout().rows.some(r=>r.slots.includes(block)))return;
 const node=blockNodes.get(block)!.node,rect=logicalBox(node),gesture=new HoldGesture();gesture.press(event.clientX,event.clientY,performance.now());
 suppressDragClick=false;
 const session:BlockDrag={block,node,pointer:event.pointerId,gesture,origin:structuredClone(currentLayout()),cells:[],grab:{x:event.clientX-rect.x,y:event.clientY-rect.y},x:event.clientX,y:event.clientY,hold:setTimeout(()=>activateBlockDrag(session),350),frame:0,lastTick:performance.now(),target:null,signature:'',editing:!!editLayout,resize:new DragResize(currentLayout().rows.find(r=>r.slots.includes(block))!.slots.length===1?'full':'mini',{x:event.clientX,y:event.clientY}),anchor:{x:0,y:0},rowIDs:Array.from({length:3},()=>crypto.randomUUID()),morph:null};
 blockDrag=session;toolbar.inert=true;
}
function activateBlockDrag(session:BlockDrag){
 if(blockDrag!==session)return;
 if(!session.gesture.activate(performance.now())){if(session.gesture.phase==='waiting')session.hold=setTimeout(()=>activateBlockDrag(session),1);return;}
 suppressDragClick=true;dragLayout=structuredClone(session.origin);session.node.classList.add('dragging');session.node.dataset.dragActive='true';
 // Disclosure is presentation-only during capture; retained forms stay in their original node.
 renderGrid();const grid=gridHost.getBoundingClientRect(),source=logicalBox(session.node);
 session.grab.x=Math.min(session.grab.x,source.width);session.grab.y=Math.min(session.grab.y,source.height-16);session.anchor={x:session.grab.x/source.width,y:session.grab.y/source.height};session.resize=new DragResize(session.resize.size,{x:session.x,y:session.y});session.node.style.transformOrigin=`${session.grab.x}px ${session.grab.y}px`;
 for(const row of session.origin.rows)for(let slot=0;slot<row.slots.length;slot++){
  const block=row.slots[slot],node=block?blockNodes.get(block)!.node:gridHost.querySelector<HTMLElement>(`.empty-slot[data-row="${row.id}"][data-slot="${slot}"]`);
  if(!node)continue;const rect=logicalBox(node);session.cells.push({row:row.id,slot,full:row.slots.length===1,x:rect.x-grid.x,y:rect.y-grid.y,width:rect.width,height:rect.height});
 }
 gridHost.setPointerCapture(session.pointer);moveSource(session);session.lastTick=performance.now();session.frame=requestAnimationFrame(tickBlockDrag);
}
function moveSource(session:BlockDrag){
 const rect=logicalBox(session.node);session.grab={x:session.anchor.x*rect.width,y:session.anchor.y*rect.height};session.node.style.transformOrigin=`${session.grab.x}px ${session.grab.y}px`;
 session.node.style.translate=`${session.x-session.grab.x-rect.x}px ${session.y-session.grab.y-rect.y}px`;
}
/** Retarget the source's live presentation size; translation always follows the pointer directly. */
function morphSource(session:BlockDrag,before:DOMRect){
 session.morph?.cancel();session.morph=null;
 if(matchMedia('(prefers-reduced-motion: reduce)').matches)return;
 const rect=session.node.getBoundingClientRect();if(Math.abs(before.width-rect.width)+Math.abs(before.height-rect.height)<1)return;
 const style=getComputedStyle(session.node),duration=parseFloat(style.getPropertyValue('--motion-geometry'));
 session.morph=session.node.animate([{transform:`scale(${before.width/Math.max(1,rect.width)},${before.height/Math.max(1,rect.height)})`},{transform:'scale(1,1)'}],{duration,easing:style.getPropertyValue('--motion-geometry-ease').trim()});
}
function blockDragTarget(session:BlockDrag):InsertionTarget|null{
 if(session.x<0||session.x>innerWidth||session.y<0||session.y>innerHeight)return null;
 const hit=document.elementFromPoint(session.x,session.y);if(hit?.closest('.context-bar,.panel-toolbar,header,.block-catalog'))return null;
 const grid=gridHost.getBoundingClientRect(),x=session.x-grid.x,y=session.y-grid.y,last=session.cells.at(-1);if(!last||x<0||x>grid.width||y<0||y>last.y+last.height+32)return null;
 if(y>last.y+last.height)return{};
 const cell=session.cells.find(c=>x>=c.x-6&&x<=c.x+c.width+6&&y>=c.y-6&&y<=c.y+c.height+6);if(!cell)return null;
 const mini=session.resize.size==='mini',own=session.origin.rows.find(r=>r.id===cell.row)?.slots.filter(Boolean).join()===session.block;
 if(mini&&(!cell.full||own))return{row:cell.row,slot:cell.full?(x<cell.x+cell.width/2?0:1):cell.slot};
 const index=session.origin.rows.findIndex(r=>r.id===cell.row);return{before:y<cell.y+cell.height/2?cell.row:session.origin.rows[index+1]?.id};
}
function updateBlockDrag(){
 const session=blockDrag;if(!session||session.gesture.phase!=='dragging')return;
 const grid=gridHost.getBoundingClientRect(),zone=blockDragTarget(session)===null?null:resizeZone(session.x-grid.x,grid.width);
 const resized=session.resize.update(zone,{x:session.x,y:session.y},performance.now());
 const target=blockDragTarget(session),side=zone==='right'?1:0,signature=stableJSON([target,session.resize.size,side]);
 if(signature!==session.signature){
  const before=session.node.getBoundingClientRect();session.signature=signature;session.target=target;
  try{const destination=target??{before:session.origin.rows.find(r=>r.slots.includes(session.block))!.id};const next=change(session.origin,l=>insert(l,session.block,destination,session.resize.size,side,session.rowIDs));animateGrid(()=>{dragLayout=next;renderGrid();});}
  catch{session.target=null;dragLayout=structuredClone(session.origin);renderGrid();}
  moveSource(session);if(resized)morphSource(session,before);
 }
 moveSource(session);
}
function tickBlockDrag(time:number){
 const session=blockDrag;if(!session||session.gesture.phase!=='dragging')return;
 const elapsed=Math.min(.05,(time-session.lastTick)/1000);session.lastTick=time;
 // The panel document owns scrolling; scrolling never escapes into a surrounding host window.
 const scroller=document.scrollingElement as HTMLElement|null;
 if(scroller)scroller.scrollTop+=scrollSpeed(session.y,innerHeight)*elapsed;
 updateBlockDrag();session.frame=requestAnimationFrame(tickBlockDrag);
}
function releaseBlockDrag(session:BlockDrag){
 clearTimeout(session.hold);cancelAnimationFrame(session.frame);session.morph?.cancel();session.morph=null;blockDrag=null;
 if(gridHost.hasPointerCapture(session.pointer))gridHost.releasePointerCapture(session.pointer);
 session.node.classList.remove('dragging');delete session.node.dataset.dragActive;toolbar.inert=layoutSaving;
}
function settleBlockDrag(session:BlockDrag,mutation:()=>void){
 // animateGrid reads the live translated frame before clearing capture, preserving the landing path.
 animateGrid(()=>{releaseBlockDrag(session);session.node.style.translate='';session.node.style.transformOrigin='';dragLayout=null;mutation();renderGrid();});
}
function cancelBlockDrag(){const session=blockDrag;if(!session)return;if(session.gesture.phase==='dragging'){suppressDragClick=true;settleBlockDrag(session,()=>{});}else releaseBlockDrag(session);}
async function finishBlockDrag(session:BlockDrag){
 const next=dragLayout,changed=next&&stableJSON(next.rows)!==stableJSON(session.origin.rows);
 if(!session.target||!changed){settleBlockDrag(session,()=>{});return;}
 if(session.editing){settleBlockDrag(session,()=>{editLayout=next;});return;}
 layoutSaving=true;
 settleBlockDrag(session,()=>{savedLayout=next!;});
 try{const result=validate(await tool('panel_save_layout',{layout:next,expectedRevision:session.origin.revision}));savedLayout=result;if(state)state.layout=result;}
 catch(failure){savedLayout=session.origin;if(failure instanceof ToolFailure&&failure.code==='layoutConflict'){try{const latest=await tool('get_state') as State;if(latest.layout)savedLayout=validate(latest.layout);accept(latest);}catch{/* Keep the valid pre-drag value when offline. */}error=t('layout.drag.conflict');}else error=t('layout.drag.failed');if(state)state.layout=savedLayout;}
 finally{layoutSaving=false;toolbar.inert=false;render();}
}
window.addEventListener('pointermove',event=>{const session=blockDrag;if(!session||event.pointerId!==session.pointer)return;session.x=event.clientX;session.y=event.clientY;if(session.gesture.move(session.x,session.y))updateBlockDrag();else if(session.gesture.phase==='cancelled'){suppressDragClick=true;releaseBlockDrag(session);}});
window.addEventListener('pointerup',event=>{const session=blockDrag;if(!session||event.pointerId!==session.pointer)return;session.x=event.clientX;session.y=event.clientY;const result=session.gesture.release();if(result.drop){session.gesture.phase='dragging';updateBlockDrag();void finishBlockDrag(session);}else releaseBlockDrag(session);});
window.addEventListener('pointercancel',event=>{if(event.pointerId===blockDrag?.pointer)cancelBlockDrag();});
gridHost.addEventListener('lostpointercapture',event=>{if(event.pointerId===blockDrag?.pointer)cancelBlockDrag();});
window.addEventListener('blur',cancelBlockDrag);window.addEventListener('pagehide',cancelBlockDrag);
document.addEventListener('visibilitychange',()=>{if(document.hidden)cancelBlockDrag();});
window.addEventListener('click',event=>{if(suppressDragClick){suppressDragClick=false;event.preventDefault();event.stopImmediatePropagation();}},true);
window.addEventListener('keydown',event=>{if(event.key==='Escape'){if(blockDrag){suppressDragClick=true;cancelBlockDrag();event.preventDefault();event.stopImmediatePropagation();}else if(editLayout)cancelEdit();else if(expanded){expanded=null;renderGrid();scheduleWorkspace();}}});
// MARK: - Bootstrap card
let bootstrapView:{host:HTMLElement;controls:HTMLElement;buttons:HTMLButtonElement[];launchers:HTMLElement;platform:HTMLElement;notice:HTMLElement;stages:HTMLElement;description:HTMLElement;state:HTMLElement;time:HTMLElement;progress:HTMLProgressElement;actions:HTMLElement;error:HTMLElement;region:HTMLElement;overlay:HTMLButtonElement;diagnostic:HTMLElement}|null=null;
let bootstrapTerminal:PrivateTerminal|null=null;
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
 box.append(element('p',t('review')),area,note,submit,button(t('close'),()=>{diagnostic=null;diagnosticNode=null;render();}));
 diagnosticNode=box;diagnosticNodeID=diagnostic?.task.id??null;return box;
}
function ensureBootstrapContent(host:HTMLElement){
 if(bootstrapView){if(bootstrapView.host!==host){host.append(...Array.from(bootstrapView.host.children));bootstrapView.host=host;}return;}
 host.classList.add('bootstrap-content');const controls=element('div','','bootstrap-controls'),launchers=element('div','','bootstrap-launchers');
 const buttons=(['ios','tvos'] as const).map(platform=>button(platform==='ios'?'iOS':'tvOS',()=>void launchBootstrap(platform),false,'primary'));
 for(const [i,b]of buttons.entries()){b.dataset.platform=i===0?'ios':'tvos';b.title=t(i===0?'bootstrap_ios':'bootstrap_tvos');const icon=element('span','','bootstrap-platform-icon');icon.setAttribute('aria-hidden','true');icon.innerHTML=i===0?'<svg viewBox="0 0 16 16"><rect x="4.5" y="1.5" width="7" height="13" rx="1.5"/><path d="M7 3h2M7.5 12.5h1"/></svg>':'<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="9" rx="1.5"/><path d="M5 14h6M8 11.5V14"/></svg>';b.prepend(icon);launchers.append(b);}
 const platform=element('span','','bootstrap-platform'),notice=element('p',t('bootstrap.xcode.launch.notice'),'bootstrap-notice'),stages=element('div','','bootstrap-stages'),description=element('p',t('bootstrap.preparation.description'),'bootstrap-description');
 const stateLabel=element('p','','bootstrap-state'),time=element('span','','bootstrap-time'),progress=element('progress','','bootstrap-progress');progress.max=1;
 const actions=element('div','','bootstrap-actions'),failure=element('p','','error bootstrap-error');
 controls.append(launchers,platform,actions,stateLabel,time,progress,notice,stages,failure,description);
 const region=element('div','','bootstrap-terminal-region'),overlay=button(t('bootstrap.error.agent'),()=>{const task=currentBootstrap();if(task){if(expanded!=='bootstrap')openBlock('bootstrap');void analyze(task.id,true);}},false,'bootstrap-agent-overlay');
 region.append(bootstrapPlaceholder(),overlay);
 const diagnosticHost=element('div','','bootstrap-diagnostic-host');host.append(controls,region,diagnosticHost);
 bootstrapView={host,controls,buttons,launchers,platform,notice,stages,description,state:stateLabel,time,progress,actions,error:failure,region,overlay,diagnostic:diagnosticHost};
}
async function launchBootstrap(platform:'ios'|'tvos'){
 const context=state?.context,action=uiAction('bootstrap');if(busy||stale||!context||!action||currentBootstrap()?.canCancel)return;
 bootstrapLaunchPlatform=platform;bootstrapLaunching=true;bootstrapLaunchError='';bootstrapFailedAttempt=null;let attempt:LocalTask|null=null;
 try{await runRole('bootstrap',{platform,device:'true',match:'true',full:'true',dependencies:'true',uiDependencies:'false',setup:'true'},true,id=>{attempt={id,actionID:action.id,title:t(platform==='ios'?'bootstrap_ios':'bootstrap_tvos'),status:'failed',createdAt:new Date().toISOString(),context:structuredClone(context),diagnosticAvailable:true,canCancel:false,bootstrap:{platform,phase:'failed',fraction:0}};});}
 finally{bootstrapLaunching=false;bootstrapLaunchError=cleanFragment(error,8192);if(attempt&&error)bootstrapFailedAttempt={...(attempt as LocalTask),error:bootstrapLaunchError};updateBootstrap();}
}
function currentBootstrap(){if(!state?.context)return undefined;if(bootstrapFailedAttempt?.context.checkoutId===state.context.checkoutId)return bootstrapFailedAttempt;return state?.tasks.find(task=>task.bootstrap&&['queued','running'].includes(task.status))??state?.tasks.find(task=>task.bootstrap);}
function bootstrapPlaceholder(){
 const placeholder=element('div','','bootstrap-placeholder'),overview=element('div','','bootstrap-overview');
 for(const stage of ['dependencies','uiTests','setup'])overview.append(element('span','○ '+t('stage.short.'+stage)));
 placeholder.append(overview);return placeholder;
}
function bootstrapDarkTheme(){const theme=document.documentElement.dataset.theme;return theme==='dark'||theme!=='light'&&matchMedia('(prefers-color-scheme: dark)').matches;}
function updateBootstrap(mode=bootstrapMode,hidden=bootstrapHidden){
 bootstrapMode=mode;bootstrapHidden=hidden;const view=bootstrapView;if(!view)return;
 const task=currentBootstrap(),live=!!task&&['queued','running'].includes(task.status),active=live||bootstrapLaunching;
 for(const b of view.buttons)b.disabled=busy||stale||!state?.context||!uiAction('bootstrap')||active;
 view.launchers.hidden=active;view.platform.hidden=!active;view.platform.textContent=(bootstrapLaunching?bootstrapLaunchPlatform:task?.bootstrap?.platform)==='tvos'?'tvOS':'iOS';
 view.notice.hidden=active;view.description.hidden=mode!=='expanded';view.stages.hidden=mode!=='expanded';
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
 view.region.classList.toggle('has-error',!view.overlay.hidden);
 const failedAdmission=!!task&&task.id===bootstrapFailedAttempt?.id;
 if(task&&!failedAdmission){
  if(!bootstrapTerminal){bootstrapTerminal=new PrivateTerminal(tool,showError,{waiting:t('bootstrap.terminal.waiting'),unavailable:t('noOutput')});view.region.prepend(bootstrapTerminal.host);view.region.querySelector('.bootstrap-placeholder')?.remove();}
  bootstrapTerminal.host.hidden=false;view.region.querySelector('.bootstrap-placeholder')?.remove();
  if(bootstrapTerminalTask!==task.id){bootstrapTerminalTask=task.id;void bootstrapTerminal.attach(task.id).catch(showError);}
  bootstrapTerminal.setBootstrapPresentation(mode==='expanded'?12:10,bootstrapDarkTheme(),matchMedia('(prefers-contrast: more)').matches);
  bootstrapTerminal.setVisibility(mode!=='mini'&&!hidden);bootstrapTerminal.setTaskStatus(task.status);
 }else {if(bootstrapTerminalTask){bootstrapTerminalTask=null;void bootstrapTerminal?.detach();}if(bootstrapTerminal)bootstrapTerminal.host.hidden=true;let placeholder=view.region.querySelector<HTMLElement>('.bootstrap-placeholder');if(!placeholder){placeholder=element('div','','bootstrap-placeholder');view.region.prepend(placeholder);}if(failedAdmission)placeholder.textContent=t('noOutput');else if(!placeholder.querySelector('.bootstrap-overview'))placeholder.replaceChildren(...Array.from(bootstrapPlaceholder().childNodes));}
 if(diagnostic&&diagnosticSource==='bootstrap'&&diagnostic.task.id===task?.id){const editor=diagnosticEditor();if(editor.parentElement!==view.diagnostic)view.diagnostic.append(editor);view.diagnostic.hidden=mode!=='expanded';}
 else{view.diagnostic.replaceChildren();view.diagnostic.hidden=true;}
 const sendButton=diagnosticNode?.querySelector<HTMLButtonElement>('[data-action=diagnostic-send]');if(sendButton)sendButton.disabled=busy||!preview&&!extensions.message;
}
setInterval(()=>{
 const view=blockNodes.get('ci');if(!view)return;
 if(!view.summary.hidden){const row=currentLayout().rows.find(row=>row.slots.includes('ci'));renderCompactRuns(view.summary,ciSummaries().slice(0,row?.slots.length===1&&!compactMedia.matches?2:1),t,openCI);}
 ciView.tick();
},1000);
const bootstrapClock=setInterval(()=>{if(currentBootstrap()?.status==='running')updateBootstrap();},1000);

function ensureBlockContent(block:Block,host:HTMLElement){if(block==='bootstrap'){ensureBootstrapContent(host);return;}if(block==='simulators'){if(simulatorHost.parentElement!==host)host.append(simulatorHost);return;}if(block==='builds'){ensureBuildForm(host);return;}
 if(block==='utils'||block==='ci'){if(!host.querySelector('.tool-choice')){const choices=block==='utils'?['localization','protocols','format','generateUI','generateSicilia','generateGalera','fullCleanup','derivedDataCleanup']:['uiTests','qualityGates','beta'];for(const kind of choices)host.append(button(blockTitle(kind as Block),()=>openBlock(kind as Block),!uiAction(kind),'tool-choice'));}if(block==='ci'&&ciView.host.parentElement!==host)host.prepend(ciView.host);return;}
 const action=uiAction(block);if(!action){host.replaceChildren(element('p',t('noActions')));return;}ensureActionForm(action,block,host);
}
function ensureActionForm(action:Action,block:Block,host:HTMLElement){
 const signature=stableJSON([action,uiBinding(block),state?.context?.checkoutId,state?.context?.profileRevision]);let form=formNodes.get(action.id);if(form?.signature===signature){if(form.node.parentElement!==host)host.append(form.node);return;}
 const box=element('form','','action-form');box.onsubmit=event=>{event.preventDefault();void runAction(action);};const values={...Object.fromEntries(action.parameters.map(p=>[p.id,p.kind==='branch'&&!p.defaultValue?state?.context?.branch??'':p.defaultValue])),...Object.fromEntries(Object.entries(actionValues.get(action.id)??{}).filter(([id])=>action.parameters.some(p=>p.id===id)))};actionValues.set(action.id,values);
 const controls=new Map<string,{wrapper:HTMLElement;input:HTMLInputElement|HTMLSelectElement;choices:string[]}>();
 for(const parameter of action.parameters){const choices=parameter.kind==='platform'?['ios','tvos']:parameter.choices??[];let input:HTMLInputElement|HTMLSelectElement=choices.length?element('select'):element('input');if(input instanceof HTMLSelectElement)for(const choice of choices)input.append(new Option(choice,choice));else{input.type=parameter.kind==='boolean'?'checkbox':'text';if(input.type==='checkbox')input.checked=values[parameter.id]==='true';}input.value=values[parameter.id];input.id='field-'+action.id+'-'+parameter.id;const label=element('label',parameter.title);label.htmlFor=input.id;const wrapper=element('div','','field');if(parameter.kind==='boolean'){wrapper.classList.add('toggle');wrapper.append(input,label);}else wrapper.append(label,input);
  input.oninput=()=>{values[parameter.id]=parameter.kind==='boolean'?String((input as HTMLInputElement).checked):input.value;previews.delete(action.id);update();scheduleWorkspace();};
  if(parameter.kind==='branch'&&action.remote){const searchBranches=button(t('search'),()=>void perform(async()=>{const result=await tool('list_remote_branches',{query:input.value});const list=element('datalist');list.id=input.id+'-choices';list.append(...result.branches.map((branch:string)=>new Option(branch,branch)));wrapper.querySelector('datalist')?.remove();wrapper.append(list);input.setAttribute('list',list.id);}),false,'quiet');wrapper.append(searchBranches);}
  controls.set(parameter.id,{wrapper,input,choices});box.append(wrapper);
 }
 const configuration=button(t('remoteReview'),()=>void configureAction(action,update),false,'quiet');if(action.remote)box.append(configuration);
 const previewBox=element('div','','preview-files'),launch=button(t('run'),()=>void runAction(action),false,'primary');const previewButton=button(t('generator.preview'),()=>void previewGenerator(action),false,'quiet');
 if(action.presentation==='generator'){launch.textContent=t('generator.generate');launch.onclick=()=>void generateAction(action);box.append(previewButton,previewBox);}
 const delegateButton=button(t('delegate'),()=>void delegate(action));const row=element('div','','form-bottom');row.append(launch,delegateButton);box.append(row);
 function update(){for(const p of action.parameters){const control=controls.get(p.id)!;control.wrapper.hidden=p.visibleWhen?Object.entries(p.visibleWhen).some(([key,value])=>values[key]!==value):false;const server=remoteFields.get(action.id)?.[p.id];if(p.kind==='choice'&&server?.choices.length&&!(control.input instanceof HTMLSelectElement)){const select=element('select');select.id=control.input.id;select.oninput=()=>{values[p.id]=select.value;previews.delete(action.id);update();scheduleWorkspace();};control.input.replaceWith(select);control.input=select;control.choices=[];}if(server&&control.input instanceof HTMLSelectElement&&stableJSON(server.choices)!==stableJSON(control.choices)){control.choices=server.choices;control.input.replaceChildren(...server.choices.map(x=>new Option(x,x)));control.input.value=values[p.id];}control.input.disabled=busy;}
  configuration.disabled=busy||stale||!state?.jenkinsConfigured;configuration.textContent=t(remoteFields.has(action.id)?'remoteRefresh':'remoteReview');
  let valid=!!state?.context&&!stale&&!busy&&action.parameters.every(p=>p.visibleWhen&&Object.entries(p.visibleWhen).some(([k,v])=>values[k]!==v)||!p.required||!!values[p.id]);if(action.remote)valid=valid&&remoteFields.has(action.id)&&!!state?.jenkinsConfigured;
  const reviewedPreview=previews.get(action.id);if(action.presentation==='generator'){valid=valid&&!!reviewedPreview?.plan&&reviewedPreview.fingerprint===stableJSON([values,state?.context])&&reviewedPreview.plan.files.length>0&&reviewedPreview.plan.files.every(f=>!f.exists);const text=reviewedPreview?.plan?.files.map(f=>`${f.exists?'!':'+'} ${f.path}`).join('\n')??(reviewedPreview?t('generator.waiting'):'');if(previewBox.textContent!==text)previewBox.textContent=text;previewButton.disabled=busy||stale||!state?.context;}
  launch.disabled=!valid;delegateButton.disabled=!state?.context||busy||!preview&&!extensions.message;
 }
 form={signature,node:box,update};formNodes.set(action.id,form);host.replaceChildren(box);update();
}
async function configureAction(action:Action,update:()=>void){await perform(async()=>{const result=await tool('get_action_configuration',{actionID:action.id});if(stableJSON(result.context)!==stableJSON(state?.context))throw new Error(t('stale'));remoteFields.set(action.id,result.fields);const values=actionValues.get(action.id)!;for(const id of applyRemoteDefaults(action.parameters,values,result.fields)){const input=formNodes.get(action.id)?.node.querySelector<HTMLInputElement|HTMLSelectElement>('#field-'+action.id+'-'+id);if(input){input.value=values[id];if(input instanceof HTMLInputElement&&input.type==='checkbox')input.checked=values[id]==='true';}}update();scheduleWorkspace();});}
async function delegate(action:Action){await perform(async()=>{const parameters=actionValues.get(action.id)??{};let message=t('delegate.prompt')+'\n'+stableJSON({actionID:action.id,parameters,context:state?.context,operation:action.presentation==='generator'?'preview_generator → get_generator_preview → generate_files (expectedDigest)':action.remote?'run_remote_action':'run_local_action'});if(!preview)await extensions.message!.send({role:'user',content:[{type:'text',text:message}]});else fixtureSentMessage=message;notice=t('sent');});}
async function previewGenerator(action:Action){await perform(async()=>{const parameters=actionValues.get(action.id)!;const fingerprint=stableJSON([parameters,state?.context]),key='preview:'+action.id+':'+fingerprint;const result=await tool('panel_preview_generator',{actionID:action.id,parameters,context:state?.context,requestID:requestID(key)});pendingIDs.delete(key);previews.set(action.id,{taskID:result.id,fingerprint});selection={type:'task',id:result.id};await refresh();});}
async function generateAction(action:Action){await perform(async()=>{const reviewed=previews.get(action.id);if(!reviewed?.plan||reviewed.fingerprint!==stableJSON([actionValues.get(action.id),state?.context]))throw new Error(t('generator.review'));const parameters={...actionValues.get(action.id),expectedDigest:reviewed.plan.digest},key=stableJSON([action.id,parameters,state?.context]);try{const result=await tool('panel_generate',{actionID:action.id,parameters,context:state?.context,requestID:requestID(key)});pendingIDs.delete(key);selection={type:'task',id:result.id};previews.delete(action.id);await refresh();}catch(e){releaseRejectedRequest(key,e);throw e;}});}
let checkingPreviews=false;let bindingRequested=false;
async function updatePreviews(){if(checkingPreviews)return;checkingPreviews=true;try{for(const [id,reviewed]of previews){if(reviewed.plan)continue;const task=state?.tasks.find(t=>t.id===reviewed.taskID);if(task?.status==='succeeded'){const result=await tool('panel_get_preview',{taskID:reviewed.taskID});if(previews.get(id)===reviewed&&result.plan){reviewed.plan=result.plan;formNodes.get(id)?.update();}}else if(task&&['failed','cancelled','interrupted'].includes(task.status)){previews.delete(id);formNodes.get(id)?.update();}}}finally{checkingPreviews=false;}}
function ensureBuildForm(host:HTMLElement){let form=formNodes.get('builds');if(form){if(form.node.parentElement!==host)host.append(form.node);return;}const box=element('div','','build-form');const controls=new Map<string,HTMLInputElement|HTMLSelectElement|HTMLTextAreaElement>();
 const backend=element('select');backend.setAttribute('aria-label',t('build.backend'));for(const kind of ['cli','xcodeMCP'])backend.append(new Option(t('build.'+kind),kind));backend.value=buildValues.backend;backend.onchange=()=>{buildValues.backend=backend.value;update();scheduleWorkspace();};box.append(backend);controls.set('backend',backend);
 const advanced=element('details');advanced.append(element('summary',t('build.advanced')));
 for(const name of ['scheme','configuration','destinationID','workspaceTab','testPlan','testIdentifiers','simulatorConfirmed']){const input=name==='testIdentifiers'?element('textarea'):name==='simulatorConfirmed'?element('input'):element('select');input.id='build-'+name;input.setAttribute('aria-label',t('build.'+name));if(input instanceof HTMLInputElement){input.type='checkbox';input.checked=buildValues[name]==='true';}else if(input instanceof HTMLTextAreaElement){input.rows=4;input.placeholder=t('build.testsHint');input.value=buildValues[name];}const wrapper=element('div','','field');wrapper.dataset.field=name;const label=element('label',t('build.'+name));label.htmlFor=input.id;wrapper.append(label,input);if(input instanceof HTMLSelectElement&&buildValues[name])input.append(new Option(buildValues[name],buildValues[name]));input.value=buildValues[name];input.oninput=()=>{buildValues[name]=input instanceof HTMLInputElement?String(input.checked):input.value;if(name==='scheme'){buildCatalogue=null;}scheduleWorkspace();update();};controls.set(name,input);(name==='configuration'||name==='testPlan'?advanced:box).append(wrapper);}
 const load=button(t('build.configure'),()=>void perform(async()=>{buildCatalogue=await tool('get_build_configuration',{context:state?.context,scheme:buildValues.scheme});if(stableJSON(buildCatalogue.context)!==stableJSON(state?.context))throw new Error(t('stale'));const cli=buildCatalogue.cli;options('scheme',cli.schemes.map((x:any)=>typeof x==='string'?{id:x,title:x}:x));options('configuration',(cli.configurations??[]).map((x:string)=>({id:x,title:x})));options('destinationID',(cli.destinations??[]).map((x:any)=>({id:x.id,title:x.name})));options('testPlan',(cli.testPlans??[]).map((x:string)=>({id:x,title:x})));options('workspaceTab',Object.entries(buildCatalogue.xcode.workspaces).map(([id,title])=>({id,title:String(title)})));update();scheduleWorkspace();}));
 const connect=button(t('build.connect'),()=>void setup('xcodeMCP'));box.prepend(load,connect);box.append(advanced);
 const launch=button(t('operation.build'),()=>void launchBuild(false),false,'primary'),test=button(t('operation.test'),()=>void launchBuild(true));const delegate=button(t('delegate'),()=>void perform(async()=>{if(!preview)await extensions.message!.send({role:'user',content:[{type:'text',text:t('delegate.prompt')+'\n'+stableJSON({method:buildValues.testIdentifiers.trim()?'run_selected_tests':'build_project',context:state?.context,parameters:buildParameters(!!buildValues.testIdentifiers.trim()),simulatorConfirmed:buildValues.simulatorConfirmed==='true'})}]});notice=t('sent');}));const row=element('div','','form-bottom');row.append(launch,test,delegate);box.append(row);
 function options(name:string,values:{id:string;title:string}[]){const input=controls.get(name) as HTMLSelectElement;input.replaceChildren(new Option(t('build.choose'),''),...values.map(v=>new Option(v.title,v.id)));input.value=buildValues[name];buildValues[name]=input.value;}
 function update(){const cli=buildValues.backend==='cli';for(const name of ['scheme','configuration','destinationID','testPlan'])box.querySelector<HTMLElement>('[data-field="'+name+'"]')!.hidden=!cli;for(const name of ['workspaceTab','simulatorConfirmed'])box.querySelector<HTMLElement>('[data-field="'+name+'"]')!.hidden=cli;for(const input of controls.values())input.disabled=busy;const valid=!!state?.context&&!busy&&!stale&&(cli?!!buildCatalogue&&!!buildValues.scheme&&!!buildValues.configuration&&!!buildValues.destinationID:!!buildValues.workspaceTab&&buildValues.simulatorConfirmed==='true');launch.disabled=!valid;test.disabled=!valid||!buildValues.testIdentifiers.trim();delegate.disabled=!valid||!preview&&!extensions.message;load.disabled=busy||stale||!state?.context;connect.hidden=cli;}
 form={signature:'builds',node:box,update};formNodes.set('builds',form);host.append(box);update();
}
function buildParameters(test:boolean){return buildValues.backend==='cli'?{backend:'cli',scheme:buildValues.scheme,configuration:buildValues.configuration,destinationID:buildValues.destinationID,...(buildValues.testPlan?{testPlan:buildValues.testPlan}:{}),...(test?{testIdentifiers:buildValues.testIdentifiers.split('\n').map(s=>s.trim()).filter(Boolean)}:{})}:{backend:'xcodeMCP',workspaceTab:buildValues.workspaceTab,...(test?{testIdentifiers:buildValues.testIdentifiers.split('\n').map(s=>s.trim()).filter(Boolean)}:{})};}
async function launchBuild(test:boolean){await perform(async()=>{const parameters=buildParameters(test),method=test?'run_selected_tests':'build_project',key=stableJSON([method,parameters,state?.context]);try{const result=await tool(method,{context:state?.context,requestID:requestID(key),parameters,simulatorConfirmed:buildValues.backend==='xcodeMCP'&&buildValues.simulatorConfirmed==='true'});pendingIDs.delete(key);selection={type:'build',id:result.activity?.id??result.id};historyOpen=true;await refresh();}catch(e){releaseRejectedRequest(key,e);throw e;}});}
async function setup(operation:string){await perform(async()=>{await tool('panel_setup',{operation});await refresh();});}
function render(){root.setAttribute('aria-busy',String(busy));banner.textContent=[preview?t('preview'):'',error,stale?t('stale'):'',notice].filter(Boolean).join(' · ');banner.className=error||stale?'error':'banner';if(!state){contextBar.textContent=t('loading');return;}installWorkspace(state);if(state.needsBinding&&!bindingRequested&&!preview&&extensions.message){bindingRequested=true;void extensions.message.send({role:'user',content:[{type:'text',text:t('binding.prompt')}]}).catch(showError);}
 const active=[...state.tasks.map(t=>({...t,type:'task' as const})),...(state.builds??[]).map(t=>({...t,type:'build' as const}))].find(t=>['running','preparing'].includes(t.status));
 const project=state.context?.checkoutId.split('/').pop()??t('noCheckout'),xcode=state.context?.xcode.split('/').find(p=>p.endsWith('.app'))??t('build.chooseXcode');const contextText=[project,state.context?.branch,xcode].filter(Boolean).join(' · ');
 contextLabel.textContent=contextText;workStatus.textContent=active?t(active.needsInput?'notification.input':active.status):state.progress??t('ready');
 if(contextDetail.dataset.text!==stableJSON(state.context)+settingsOpen){contextDetail.dataset.text=stableJSON(state.context)+settingsOpen;contextDetail.replaceChildren(element('summary',t('context.details')),element('p',[state.context?.checkoutId,state.context?.sha,state.context?.xcode,state.context?.profileRevision].filter(Boolean).join('\n'),'mono'));if(state.needsBinding)contextDetail.append(button(t('binding.request'),()=>void perform(async()=>{if(!preview)await extensions.message!.send({role:'user',content:[{type:'text',text:t('binding.prompt')}]});notice=t('sent');})));if(settingsOpen||!state.context||!state.actions.length){const row=element('div','','row');for(const operation of ['profile','xcode','target','credentials','notifications'])row.append(button(t('setup.'+operation),()=>void setup(operation),busy||!['profile','notifications'].includes(operation)&&!state.context));row.append(button(t('branch.local'),()=>void loadBranches(),busy||!state.context));contextDetail.append(row);contextDetail.open=true;}}
 const toolbarSignature=String(!!editLayout)+busy;if(toolbar.dataset.signature!==toolbarSignature){toolbar.dataset.signature=toolbarSignature;toolbar.replaceChildren(...(editLayout?[button(t('layout.add'),()=>{catalogOpen=!catalogOpen;renderCatalog();}),button(t('layout.reset'),()=>{editLayout=standard();renderGrid();}),button(t('layout.cancel'),cancelEdit),button(t('layout.done'),()=>void finishEdit(),busy,'primary')]:[button(t('newAction'),()=>{catalogOpen=!catalogOpen;renderCatalog();}),button(t('history'),()=>{historyOpen=!historyOpen;renderHistory();}),button(t('settings'),()=>{settingsOpen=!settingsOpen;render();}),button(t('layout.edit'),beginEdit)]));}
 renderCatalog();renderGrid();renderHistory();renderDetails();const waiting=state.queue?.filter(t=>t.context?.checkoutId!==state?.context?.checkoutId)??[];queueHost.textContent=waiting.length?t('queue.other')+' '+waiting.length:'';void updatePreviews();
}
async function loadBranches(){await perform(async()=>{const result=await tool('panel_branches');const select=element('select');select.setAttribute('aria-label',t('branch.local'));select.append(new Option(t('branch.local'),''),...result.branches.map((branch:string)=>new Option(branch,branch)));const change=button(t('branch.switch'),()=>void perform(async()=>{await tool('panel_switch_branch',{branch:select.value,context:state?.context});await refresh();}),false,'quiet');contextDetail.append(select,change);});}
function renderCatalog(){catalogHost.hidden=!catalogOpen;if(!catalogOpen)return;const signature=stableJSON([!!editLayout,currentLayout().rows,state?.actions.map(a=>a.id)]);if(catalogHost.dataset.signature===signature)return;catalogHost.dataset.signature=signature;catalogHost.replaceChildren(element('h2',t('catalog')));for(const block of catalog){if(editLayout&&editLayout.rows.some(r=>r.slots.includes(block)))continue;catalogHost.append(button(blockTitle(block),()=>{if(editLayout)edit(l=>add(l,block));else openBlock(block);},false,'tool-choice'));}}
const historyRows=new Map<string,HTMLButtonElement>();
function renderHistory(){historyHost.hidden=!historyOpen;if(!historyOpen)return;const records=[...state!.tasks.map(t=>({...t,type:'task' as const})),...(state!.builds??[]).map(t=>({...t,type:'build' as const})),...state!.runs.map(t=>({...t,title:t.branch,type:'run' as const}))].sort((a,b)=>b.createdAt.localeCompare(a.createdAt)).slice(0,100);
 if(!historyHost.querySelector('h2'))historyHost.prepend(element('h2',t('history')));historyHost.querySelector('.empty')?.remove();const ids=new Set(records.map(r=>r.type+':'+r.id));for(const [id,node]of historyRows)if(!ids.has(id)){node.remove();historyRows.delete(id);}
 if(!records.length)historyHost.append(element('p',t('emptyTasks'),'empty'));for(const [index,item]of records.entries()){const id=item.type+':'+item.id;let row=historyRows.get(id);if(!row){row=button('',()=>selectItem(item.type,item.id),false,'item');row.append(element('span','','item-title'),status(item.status));historyRows.set(id,row);}row.querySelector('.item-title')!.textContent=item.title;const label=row.querySelector('.status')!;label.textContent=t(item.status);label.className='status '+item.status;row.setAttribute('aria-pressed',String(selection?.id===item.id));if(historyHost.children[index+1]!==row)historyHost.insertBefore(row,historyHost.children[index+1]??null);}}

function renderDetails(){const item=selection?.type==='task'?state?.tasks.find(t=>t.id===selection?.id):selection?.type==='build'?state?.builds?.find(t=>t.id===selection?.id):state?.runs.find(t=>t.id===selection?.id);const signature=stableJSON([item?.id,diagnostic?.task.id,notice]);if(signature===detailSignature){const label=detailHost.querySelector('.status');if(label&&item){label.textContent=t(item.status);label.className='status '+item.status;const cancel=detailHost.querySelector<HTMLButtonElement>('[data-action=cancel]'),analyze=detailHost.querySelector<HTMLButtonElement>('[data-action=analyze]'),secret=detailHost.querySelector<HTMLButtonElement>('[data-action=secret]');if(cancel)cancel.disabled=busy||!('canCancel'in item&&item.canCancel);if(analyze)analyze.disabled=busy||!('diagnosticAvailable'in item&&item.diagnosticAvailable);if(secret)secret.disabled=item.status!=='running';}return;}detailSignature=signature;
 const terminalHost=detailsTerminal?.host;if(terminalHost)terminalHost.remove();detailHost.replaceChildren();if(!item){if(detailsTerminal)void detailsTerminal.detach();return;}const detail=card('title' in item?item.title:item.branch);const close=button(t('close'),()=>{selection=null;diagnostic=null;renderDetails();scheduleWorkspace();});detail.append(close,status(item.status));if('context'in item){detail.append(element('p',[item.context.branch,item.context.sha].join(' · '),'mono'));const actions=element('div','','row');actions.append(button(t('cancel'),()=>void perform(async()=>{await tool(selection!.type==='build'?'cancel_build_activity':'cancel_local_task',selection!.type==='build'?{activityID:item.id}:{taskID:item.id});await refresh();}),busy||!item.canCancel));actions.lastElementChild!.setAttribute('data-action','cancel');actions.append(button(t('analyze'),()=>selection?.type==='task'?void analyze(item.id):void perform(async()=>{const result=await tool('get_build_diagnostic',{activityID:item.id});diagnostic={task:result.task,text:result.analysisPrompt.split('<diagnostic-data>')[1]?.split('</diagnostic-data>')[0]?.trim()??'',analysisPrompt:result.analysisPrompt,truncated:result.truncated,outputUnavailable:false};fragment=diagnostic.text;comment='';}),busy||!item.diagnosticAvailable));actions.lastElementChild!.setAttribute('data-action','analyze');actions.append(button(t('terminal.open'),()=>{if(!detailsTerminal)detailsTerminal=new PrivateTerminal(tool,showError,{waiting:t('bootstrap.terminal.waiting'),unavailable:t('noOutput')});detail.append(detailsTerminal.host);void detailsTerminal.attach(item.id).catch(showError);}),button(t('terminal.secret'),()=>void perform(async()=>{await tool('panel_secret_input',{taskID:item.id});}),item.status!=='running'));actions.lastElementChild!.setAttribute('data-action','secret');detail.append(actions);if(terminalHost){detail.append(terminalHost);void detailsTerminal!.attach(item.id).catch(showError);}}else{if(detailsTerminal)void detailsTerminal.detach();for(const a of [link('Jenkins',item.jenkinsURL),link('GitLab',item.gitlabURL),link('Allure',item.allureURL)])if(a)detail.append(a);if(item.error)detail.append(element('p',item.error,'error'));for(const job of item.jobs)detail.append(element('p',job.name+' · '+t(job.status)));}detailHost.append(detail);
 if(diagnostic&&diagnosticSource==='history')detailHost.append(diagnosticEditor());
}

// Simulator controls are created once. Polling only changes metadata and button availability.
type SimulatorConfig={context:Context;version:string;availability:string;devices:{id:string;name:string;runtime:string;state:string}[]};
type Frame={sessionID:string;revision:number;width:number;height:number;image:string;mimeType:string;targets:{x:number;y:number;width:number;height:number;hitX:number;hitY:number}[]};
let simulatorConfig:SimulatorConfig|null=null, simulatorFrame:Frame|null=null, simulatorBusy=false, simulatorError='', simulatorLoading=false, loadedRevision='';
const simulatorTitle=element('h2',t('sim.title'));
const simulatorNote=element('p',t('sim.note'));
const simulatorStatus=element('p');simulatorStatus.setAttribute('role','status');simulatorStatus.setAttribute('aria-live','polite');
const simulatorErrorNode=element('p','','error');simulatorErrorNode.setAttribute('role','alert');
const deviceSelect=element('select');deviceSelect.id='sim-device';deviceSelect.setAttribute('aria-label',t('sim.device'));
const simulatorImage=element('img');simulatorImage.alt=t('sim.screen');simulatorImage.className='simulator-image';simulatorImage.draggable=false;simulatorImage.tabIndex=0;simulatorImage.hidden=true;
const simulatorPlaceholder=element('p',t('sim.empty'),'empty');
const textInput=element('textarea');textInput.id='sim-text';textInput.rows=2;textInput.placeholder=t('sim.textPlaceholder');textInput.setAttribute('aria-label',t('sim.text'));textInput.maxLength=8192;
const orientationSelect=element('select');orientationSelect.setAttribute('aria-label',t('sim.orientation'));for(const value of ['portrait','landscapeLeft','landscapeRight','portraitUpsideDown']){const option=element('option',t('sim.'+value));option.value=value;orientationSelect.append(option);}
const configureButton=button(t('sim.devices'),()=>void loadSimulatorConfiguration());
const startButton=button(t('sim.open'),()=>void simulatorRun('start_simulator_session',{deviceID:deviceSelect.value}));
const installButton=button(t('sim.install'),()=>void simulatorRun('install_simulator_app'));
const refreshButton=button(t('sim.refresh'),()=>void simulatorRun('refresh_simulator_screen'));
const closeButton=button(t('sim.close'),()=>void simulatorRun('close_simulator_session'));
const homeButton=button(t('sim.home'),()=>void simulatorAction({type:'home'}));
const rotateButton=button(t('sim.rotate'),()=>void simulatorAction({type:'orientation',orientation:orientationSelect.value}));
const textButton=button(t('sim.sendText'),()=>{const value=textInput.value;if(value)void simulatorAction({type:'text',text:value}).then(ok=>{if(ok&&textInput.value===value)textInput.value='';});});
textInput.oninput=()=>updateSimulatorButtons();
const releaseButton=button(t('sim.release'),()=>{const unknown=state?.simulator?.activities.find(x=>x.status==='unknown'&&!x.queueReleased);if(!unknown)return;if(releaseButton.dataset.confirm!==unknown.id){releaseButton.dataset.confirm=unknown.id;releaseButton.textContent=t('sim.confirmRelease');return;}releaseButton.dataset.confirm='';releaseButton.textContent=t('sim.release');void simulatorPrivateRelease(unknown.id);});
function initializeSimulator(){
 const row=element('div','','sim-toolbar');row.append(configureButton,startButton,installButton,refreshButton,closeButton);
 const deviceLabel=element('label',t('sim.device'));deviceLabel.htmlFor=deviceSelect.id;
 const viewport=element('div','','sim-viewport');viewport.append(simulatorPlaceholder,simulatorImage);
 const hardware=element('div','','sim-toolbar');hardware.append(homeButton,orientationSelect,rotateButton);
 const label=element('label',t('sim.text'));label.htmlFor=textInput.id;
 simulatorHost.append(simulatorTitle,simulatorNote,deviceLabel,deviceSelect,row,simulatorStatus,simulatorErrorNode,viewport,hardware,label,textInput,textButton,releaseButton);
 updateSimulator();
}
function updateSimulatorButtons(){
 const session=state?.simulator?.session, blocked=simulatorBusy||simulatorLoading||!!state?.simulator?.busy||stale;
 const pending=state?.simulator?.activities.some(x=>['queued','preparing','running'].includes(x.status))??false;
 const unavailable=simulatorConfig&&['requiresXcode27','requiresSupportedMacOS'].includes(simulatorConfig.availability);
 configureButton.disabled=simulatorLoading||!state?.context||simulatorBusy;
 startButton.disabled=blocked||pending||!!session||!deviceSelect.value||!simulatorConfig||!!unavailable;
 deviceSelect.disabled=!!session||simulatorBusy;
 const ready=!!session?.ready&&!!simulatorFrame&&simulatorFrame.sessionID===session.id&&simulatorFrame.revision===session.revision&&!blocked&&!pending;
 for(const control of [homeButton,rotateButton,textButton])control.disabled=!ready;
 textButton.disabled=textButton.disabled||!textInput.value;
 installButton.disabled=blocked||pending||!session||!session.ready;
 refreshButton.disabled=blocked||pending||!session||!session.ready;
 closeButton.disabled=blocked||pending||!session;
 simulatorImage.setAttribute('aria-disabled',String(!ready));
 releaseButton.hidden=!state?.simulator?.activities.some(x=>x.status==='unknown'&&!x.queueReleased);
 releaseButton.disabled=simulatorBusy;
}
function updateSimulator(){
 if(!state?.simulator?.session){simulatorFrame=null;loadedRevision='';simulatorImage.hidden=true;simulatorImage.removeAttribute('src');simulatorPlaceholder.hidden=false;}
 const session=state?.simulator?.session;
 if(simulatorFrame&&(!session||simulatorFrame.sessionID!==session.id||simulatorFrame.revision!==session.revision))simulatorFrame=null;
 const operation=state?.simulator?.activities.filter(x=>!x.queueReleased).at(-1);
 simulatorStatus.textContent=simulatorConfig?`${t('sim.xcode')} ${simulatorConfig.version} · ${t('sim.'+(session?.ready?'available':simulatorConfig.availability))}${operation?' · '+t(operation.status):''}`:t('sim.choose');
 simulatorErrorNode.textContent=simulatorError;updateSimulatorButtons();
 const revision=session?.revision?session.id+':'+session.revision:'';
 if(session?.ready&&revision&&revision!==loadedRevision&&!simulatorBusy)void loadSimulatorFrame(session.id,revision);
}
async function loadSimulatorConfiguration(){if(simulatorLoading)return;simulatorLoading=true;simulatorError='';updateSimulator();try{
 const result=await tool('get_simulator_configuration',{context:state?.context}) as SimulatorConfig;
 if(stableJSON(result.context)!==stableJSON(state?.context))throw new Error(t('sim.contextChanged'));
 simulatorConfig=result;const selected=deviceSelect.value;deviceSelect.replaceChildren();for(const device of result.devices){const o=element('option',`${device.name} · ${device.runtime} · ${t('sim.'+device.state)}`);o.value=device.id;o.selected=device.id===selected;deviceSelect.append(o);}
 }catch(e){simulatorError=e instanceof Error?e.message:t('error');}finally{simulatorLoading=false;updateSimulator();}}
async function loadSimulatorFrame(sessionID:string,revision:string){if(simulatorLoading)return;simulatorLoading=true;updateSimulatorButtons();try{
 const frame=await tool('simulator_ui_observe',{sessionID}) as Frame;
 if(!frame||frame.sessionID!==sessionID||sessionID!==state?.simulator?.session?.id||frame.revision!==state.simulator.session.revision||!Number.isFinite(frame.width)||!Number.isFinite(frame.height)||frame.width<=0||frame.height<=0||frame.mimeType!=='image/jpeg')throw new Error(t('sim.invalidFrame'));
 loadedRevision=revision;simulatorImage.onload=()=>{if(loadedRevision!==revision)return;simulatorFrame=frame;simulatorImage.hidden=false;simulatorPlaceholder.hidden=true;updateSimulatorButtons();};
 simulatorImage.onerror=()=>{loadedRevision='';simulatorFrame=null;simulatorError=t('sim.invalidFrame');simulatorErrorNode.textContent=simulatorError;updateSimulatorButtons();};
 simulatorImage.src='data:image/jpeg;base64,'+frame.image;
 }catch(e){simulatorError=e instanceof Error?e.message:t('error');}finally{simulatorLoading=false;simulatorErrorNode.textContent=simulatorError;updateSimulatorButtons();}}
async function simulatorRun(name:string,extra:Record<string,unknown>={}){if(simulatorBusy)return false;const session=state?.simulator?.session;
 if(name!=='start_simulator_session'&&!session)return false;
 simulatorBusy=true;simulatorError='';updateSimulatorButtons();simulatorFrame=null;loadedRevision='';
 try{const result=await tool(name,{context:session?.context??state?.context,requestID:crypto.randomUUID(),...(name==='start_simulator_session'?{}:{sessionID:session!.id}),...extra}) as SimulatorActivity;
 for(let attempt=0;attempt<120;attempt++){
  const response=await tool('get_simulator_activity',{activityID:result.id});
  if(response.state&&state){state.simulator=response.state;updateSimulator();}
  const activity=response.activity as SimulatorActivity;
  if(!['queued','preparing','running'].includes(activity.status)){if(activity.status!=='succeeded')throw new Error(t('sim.operationFailed')+' '+t(activity.status)+(activity.errorCode?' · '+t('sim.error.'+activity.errorCode):''));await refresh();return true;}
  await new Promise(resolve=>setTimeout(resolve,1000));
 }
 throw new Error(t('sim.waiting'));
 }catch(e){simulatorError=e instanceof Error?e.message:t('error');return false;}finally{simulatorBusy=false;updateSimulator();}}
async function simulatorAction(action:Record<string,unknown>){const frame=simulatorFrame;if(!frame||simulatorImage.getAttribute('aria-disabled')==='true')return false;return simulatorRun('simulator_ui_action',{revision:frame.revision,action});}
async function simulatorPrivateRelease(activityID:string){simulatorBusy=true;updateSimulatorButtons();try{await tool('simulator_ui_release_unknown',{activityID});await refresh();}catch(e){simulatorError=e instanceof Error?e.message:t('error');}finally{simulatorBusy=false;updateSimulator();}}
function screenPoint(event:PointerEvent,frame:Frame){const rect=simulatorImage.getBoundingClientRect();return{x:Math.max(0,Math.min(frame.width-0.01,(event.clientX-rect.left)/rect.width*frame.width)),y:Math.max(0,Math.min(frame.height-0.01,(event.clientY-rect.top)/rect.height*frame.height))};}
function hierarchyPoint(point:{x:number;y:number},frame:Frame){const targets=frame.targets.filter(x=>x.width*x.height<frame.width*frame.height*0.95&&point.x>=x.x&&point.x<=x.x+x.width&&point.y>=x.y&&point.y<=x.y+x.height).sort((a,b)=>a.width*a.height-b.width*b.height);return targets.length?{x:targets[0].hitX,y:targets[0].hitY}:null;}
let drag:{pointer:number;start:{x:number;y:number};time:number;frame:Frame}|null=null;
simulatorImage.onpointerdown=event=>{if(event.button!==0||simulatorImage.getAttribute('aria-disabled')==='true'||!simulatorFrame)return;event.preventDefault();simulatorImage.focus({preventScroll:true});drag={pointer:event.pointerId,start:screenPoint(event,simulatorFrame),time:performance.now(),frame:simulatorFrame};simulatorImage.setPointerCapture(event.pointerId);};
simulatorImage.onpointercancel=()=>{drag=null;};
simulatorImage.onpointerup=event=>{const current=drag;drag=null;if(!current||current.pointer!==event.pointerId||current.frame!==simulatorFrame)return;const end=screenPoint(event,current.frame);if(Math.hypot(end.x-current.start.x,end.y-current.start.y)<8){const point=hierarchyPoint(end,current.frame);if(point)void simulatorAction({type:'tap',...point});}else{const start=hierarchyPoint(current.start,current.frame),finish=hierarchyPoint(end,current.frame);if(start&&finish)void simulatorAction({type:'swipe',...start,endX:finish.x,endY:finish.y,duration:Math.max(0.05,Math.min(2,(performance.now()-current.time)/1000))});}};
setInterval(()=>{const session=state?.simulator?.session;if(session&&!preview)void tool('simulator_ui_heartbeat',{sessionID:session.id}).catch(()=>{});},10000);
const fixtureContext:Context={checkoutId:'/private/tmp/MimicFixture',branch:'feature/mcp',sha:'fixture-sha',xcode:'/Applications/Xcode.app/Contents/Developer',appleTarget:null,profileID:null,profileRevision:null};
const fixtureState:State={interface:{version:1,bindings:[{role:'bootstrap',actionID:'prepare',fields:Object.fromEntries(['platform','device','match','full','dependencies','uiDependencies','setup'].map(x=>[x,x]))}]},context:fixtureContext,actions:[{id:'prepare',title:'Подготовка',presentation:'preparation',remote:false,parameters:[...['device','match','full','dependencies','uiDependencies','setup'].map(id=>({id,title:id,kind:'boolean',defaultValue:'true',required:true})),{id:'platform',title:'Платформа',kind:'platform',defaultValue:'ios',required:true}]}],tasks:[{id:'fixture-task',actionID:'prepare',bootstrap:{platform:'ios',phase:'failed',fraction:0},title:t('bootstrap_ios'),status:'failed',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:true,canCancel:false}],builds:[{id:'fixture-build',title:t('operation.build'),status:'failed',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:true,canCancel:false,tracking:'unavailable',source:'Terminal',phase:'build.phase.failed',parameters:{operation:'build',backend:'cli',scheme:'Fixture',configuration:'Debug',destinationID:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',workspaceTab:''}}],runs:[],jenkinsConfigured:true,progress:t('failed')};
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
let fixtureSimulator:SimulatorState={session:null,activities:[],busy:false};
let fixtureScreenText='Тестовый экран',fixtureCounter=0;
function fixtureFrame():Frame{const canvas=document.createElement('canvas');canvas.width=402;canvas.height=874;const context=canvas.getContext('2d')!;context.fillStyle='#f2f2f7';context.fillRect(0,0,402,874);context.fillStyle='#202024';context.font='bold 24px system-ui';context.fillText('Mimic · Simulator',24,120);context.font='18px system-ui';context.fillText(fixtureScreenText,24,235);context.fillText('Счётчик: '+fixtureCounter,24,340);return{sessionID:fixtureSimulator.session!.id,revision:fixtureSimulator.session!.revision!,width:402,height:874,image:canvas.toDataURL('image/jpeg').split(',')[1],mimeType:'image/jpeg',targets:[{x:24,y:200,width:350,height:60,hitX:200,hitY:230},{x:24,y:300,width:350,height:60,hitX:200,hitY:330}]};}
async function fixtureTool(name:string,args:Record<string,unknown>){
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
 if(name==='panel_switch_branch'){fixtureContext.branch=String(args.branch);return{done:true};}
 if(name==='get_build_configuration')return{context:fixtureContext,cli:{schemes:['Fixture','Another'],configurations:['Debug','Release'],destinations:args.scheme?[{id:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',name:'iPhone Fixture'}]:[],testPlans:['Selected']},backends:['cli','xcodeMCP'],xcode:{workspaces:{fixture:'Fixture.xcworkspace'}}};
 if(name==='build_project'||name==='run_selected_tests'){const record={...fixtureState.builds![0],id:String(args.requestID),status:'queued',parameters:{...(args.parameters as any),operation:name==='build_project'?'build':'test'},canCancel:true};fixtureState.builds!.unshift(record);return{activity:record};}
 if(name==='panel_preview_generator'||name==='panel_generate'){const record={id:String(args.requestID),title:'Fixture generator',status:'succeeded',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:false,canCancel:false};fixtureState.tasks.unshift(record);return record;}
 if(name==='panel_get_preview')return{status:'succeeded',plan:{files:[{path:'Sources/Fixture.swift',exists:false}],digest:'a'.repeat(64)}};
 if(name==='panel_secret_input')return{done:true};
 if(name==='panel_terminal_open')return await fixtureTerminalOpen(args);
 if(name==='panel_terminal_poll')return await fixtureTerminalPoll(args);
 if(name==='panel_terminal_send')return await fixtureTerminalSend(args);
 if(name==='panel_terminal_close'){fixtureChannels.delete(String(args.channelID));return{closed:true};}
 if(name==='get_simulator_configuration')return{context:fixtureContext,version:'27.0',availability:'requiresNativeAccess',devices:[{id:'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',name:'iPhone Fixture',runtime:'iOS 27',state:'Booted'}]};
 if(name==='simulator_ui_observe')return fixtureFrame();
 if(name==='get_simulator_activity')return{activity:fixtureSimulator.activities.find(x=>x.id===args.activityID),state:fixtureSimulator};
 if(['start_simulator_session','perform_simulator_action','simulator_ui_action','refresh_simulator_screen','install_simulator_app','close_simulator_session'].includes(name)){
  const activity:SimulatorActivity={id:String(args.requestID),kind:name,status:'succeeded',queueReleased:false};fixtureSimulator.activities.push(activity);
  if(name==='start_simulator_session')fixtureSimulator.session={id:'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',deviceID:String(args.deviceID),context:fixtureContext,revision:1,ready:true};
  else if(name==='close_simulator_session')fixtureSimulator.session=null;
  else if(fixtureSimulator.session){fixtureSimulator.session.revision!++;const action=args.action as {type:string;text?:string};if(action?.type==='text')fixtureScreenText=action.text??'';if(action?.type==='tap')fixtureCounter++;}
  fixtureState.simulator=fixtureSimulator;return activity;
 }
if(name==='get_action_configuration'){const action=fixtureState.actions.find(x=>x.id===args.actionID)!;return{context:Object.fromEntries(Object.entries(fixtureContext).reverse()),fields:Object.fromEntries(action.parameters.map(p=>[p.id,{defaultValue:p.defaultValue,choices:p.kind==='boolean'?['true','false']:p.kind==='choice'?['yes','no']:p.choices??[]}]))};}if(name==='get_build_diagnostic')return{task:fixtureState.builds![0],analysisPrompt:'Fixture context\n<diagnostic-data>\nFixture: compilation failed\n</diagnostic-data>',truncated:false};if(name==='get_task_diagnostic')return{task:fixtureState.tasks.find(task=>task.id===args.taskID)!,text:'Fixture: dependency unavailable\nExit status: 1',truncated:false,outputUnavailable:false,analysisPrompt:''};if(name==='list_remote_branches')return{branches:['develop','feature/mcp','feature/very-long-branch-name-for-layout-testing']};if(name==='run_local_action'){if(args.actionID==='prepare'&&fixtureRejectBootstrap){fixtureRejectBootstrap=false;throw new ToolFailure('Fixture admission refused','context');}if(args.actionID==='prepare')fixtureBootstrapLaunches.push(structuredClone(args));const task:LocalTask={id:String(args.requestID),actionID:String(args.actionID),...(args.actionID==='prepare'?{bootstrap:{platform:((args.parameters as Record<string,string>)?.platform??'ios') as 'ios'|'tvos',phase:'queued',fraction:0}}:{}),title:t(String(args.actionID)),status:'queued',createdAt:new Date().toISOString(),context:fixtureContext,diagnosticAvailable:false,canCancel:true};fixtureState.tasks.unshift(task);return task;}if(name==='run_remote_action'){const run:Run={id:String(args.requestID),branch:String(((args.parameters as Record<string,string>)?.ref??fixtureContext.branch)),plan:String((args.parameters as Record<string,string>)?.plan),status:'running',createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),pipelineID:123,sha:'fixture-sha',jenkinsURL:'https://jenkins.example/job/fixture/1',gitlabURL:'https://gitlab.example/pipelines/123',allureURL:'https://allure.example/launch/456',jobs:[{name:'UI tests',status:'running',allowFailure:false,url:'https://gitlab.example/jobs/1'}]};fixtureState.runs.unshift(run);return run;}if(name==='cancel_local_task'){const task=fixtureState.tasks.find(x=>x.id===args.taskID);if(task){task.status='cancelled';task.canCancel=false;}}return fixtureState;}
if(preview){(window as any).mimicCIFixture={set:(summary:CICompactSummary|null)=>{fixtureState.ciSummary=summary;fixtureState.ciSummaries=summary?[summary]:[];state=fixtureState;render();},setRuns:(summaries:CICompactSummary[])=>{fixtureState.ciSummary=summaries[0];fixtureState.ciSummaries=summaries;state=fixtureState;render();},details:(identity:string,value:CIInspection,delay=0)=>fixtureCIDetails.set(identity,{value,delay}),mode:(mode:'mini'|'full'|'expanded')=>{savedLayout=standard();if(mode==='full')resize(savedLayout,'ci','full');fixtureState.layout=savedLayout;expanded=mode==='expanded'?'ci':null;render();},current:()=>fixtureState.ciSummary};}
const fixtureCIDetails=new Map<string,{value:CIInspection;delay:number}>();
// MARK: - Quiet status notifications
const notificationNode=element('p','','banner');notificationNode.setAttribute('role','status');notificationNode.setAttribute('aria-live','polite');root.prepend(notificationNode);
const observedStatuses=new Map<string,string>();
function notifyChanges(next:State){if(next.notices){for(const item of next.notices)notificationNode.textContent=item.title+' · '+item.body;return;}for(const item of [...next.tasks,...(next.builds??[]),...next.runs]){const previous=observedStatuses.get(item.id);observedStatuses.set(item.id,item.status);if(previous&&previous!==item.status&&['succeeded','success','failed','interrupted','unknown'].includes(item.status)){notificationNode.textContent=('title'in item?item.title:item.branch)+' · '+t(['succeeded','success'].includes(item.status)?'notification.completed':'notification.failed');}}}
// MARK: - Disposable preview contracts; never connected to a real executor
let fixtureLayout=standard();
if(preview&&new URL(location.href).searchParams.get('layout')==='empty')fixtureLayout.rows=[];
if(preview&&new URL(location.href).searchParams.get('layout')==='one')fixtureLayout.rows=fixtureLayout.rows.slice(0,1);
let fixtureWorkspace:{expanded?:Block;selection?:string;drafts:Record<string,Record<string,string>>}={drafts:{}};fixtureState.layout=fixtureLayout;fixtureState.workspace=fixtureWorkspace;
for(const role of ['generateUI','generateSicilia','generateGalera','localization','protocols','format','qualityGates','beta']){
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
 task(status:string,platform:'ios'|'tvos'='ios',reuse=false,error=''){
  const previous=fixtureState.tasks.find(task=>task.bootstrap),id=reuse&&previous?previous.id:crypto.randomUUID();
  const task:LocalTask={id,actionID:'prepare',title:t('bootstrap_'+platform),bootstrap:{platform,phase:status,fraction:status==='succeeded'?1:.4,stages:['dependencies','uiTests','setup'],currentStage:status==='running'?'uiTests':null,completedStages:status==='succeeded'?['dependencies','uiTests','setup']:status==='running'?['dependencies']:[]},status,context:fixtureContext,createdAt:new Date().toISOString(),startedAt:new Date(Date.now()-41000).toISOString(),finishedAt:['queued','running','blocked'].includes(status)?null:new Date().toISOString(),canCancel:['queued','running','blocked'].includes(status),diagnosticAvailable:['failed','interrupted'].includes(status),error};
  if(status==='blocked'){task.status='queued';task.bootstrap!.phase='blocked';}
  fixtureState.tasks=fixtureState.tasks.filter(task=>!task.bootstrap);fixtureState.tasks.unshift(task);
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

initializeSimulator();
app.onteardown=async()=>{clearInterval(bootstrapClock);cancelBlockDrag();await detailsTerminal?.dispose();await bootstrapTerminal?.dispose();if(state?.simulator?.session){const session=state.simulator.session;try{await tool('close_simulator_session',{context:session.context,sessionID:session.id,requestID:crypto.randomUUID()});}catch{/* Native lease closes an abandoned panel; unknown operations remain blocked. */}}return {};};
app.ontoolresult=params=>{if(params.structuredContent){accept({...params.structuredContent,...(params._meta?.['mimic/workspace'] as object??{})} as State);render();}};
function hostStyle(context:ReturnType<App['getHostContext']>){if(context?.theme)applyDocumentTheme(context.theme);if(context?.styles?.variables)applyHostStyleVariables(context.styles.variables);updateBootstrap();}
for(const query of ['(prefers-color-scheme: dark)','(prefers-contrast: more)'])matchMedia(query).addEventListener('change',()=>updateBootstrap());
app.onhostcontextchanged=context=>hostStyle(context);
render();
if(preview){accept(fixtureState);render();}else{void app.connect().then(()=>{hostStyle(app.getHostContext());return refresh();}).catch(()=>{error=t('connecting');render();});}
setInterval(()=>{if(!busy&&document.visibilityState==='visible')void refresh();},5000);
