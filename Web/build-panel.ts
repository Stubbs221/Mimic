// Created by Василий Маслов on 09.10.2026.
type Context = {checkoutId:string;branch:string;sha:string;xcode:string;[key:string]:unknown};
export type BuildDraft = {operation:'build'|'test';backend:'cli'|'xcodeMCP';scheme:string;configuration:string;destinationID:string;testPlan:string;testIdentifiers:string[];workspaceTab:string;platform?:string};
type Test = {id:string;target:string;className:string;name:string};
type Product = {path:string;name:string;bundleIdentifier:string};
export type BuildRecord = {id:string;status:string;phase:string;source:string;actionKey?:string;startedAt?:string|null;finishedAt?:string|null;createdAt:string;canCancel:boolean;context:Context;parameters:{scheme:string;operation:string;intent?:string|null;destinationID:string};stage?:string|null;products?:Product[]|null;selectedProductID?:string|null;destinationName?:string|null;completedStages?:number|null;progressTotal?:number;progressFraction?:number|null;errorCode?:string|null;completedTestCount?:number|null;selectedTestCount?:number|null};
type Catalogue = {schemes:string[];configurations:string[];destinations:{id:string;name:string;platform?:string}[];testPlans:string[]};
const key=(value:unknown):string=>JSON.stringify(value,(_k,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
const node=<K extends keyof HTMLElementTagNameMap>(tag:K,text='',cls=''):HTMLElementTagNameMap[K]=>{const n=document.createElement(tag);n.textContent=text;n.className=cls;return n;};
const pending=(record?:BuildRecord)=>!!record&&['queued','preparing','running'].includes(record.status);

/** A retained control surface and anchored popover share one draft in every size. No action discloses Extended. */
export class BuildPanel {
 readonly host=node('div','','build-card-controls');
 private popup=node('div','','build-popover');
 private context:Context|null=null;
 private records:BuildRecord[]=[];
 private draft:BuildDraft={operation:'build',backend:'cli',scheme:'',configuration:'Debug',destinationID:'',testPlan:'',testIdentifiers:[],workspaceTab:''};
 private catalogue:Catalogue|null=null;
 private developerDirectory='';private workspaces:Record<string,string>={};private xcodeConfirmed=false;
 private tests:Test[]|null=null;
 private mode=''; private action='run'; private search=''; private popupKind=''; private anchor:HTMLElement|null=null;
 private revision=0; private loading=false; private submitting=false; private error=''; private saveTimer:ReturnType<typeof setTimeout>|undefined;
 private content=node('div'); private status=node('div','','build-current-work'); private issue=node('p','','error');
 private testList=node('div','','build-test-list'); private count=node('p','','muted'); private activeSignature='';private previousStatuses=new Map<string,string>();private requests=new Map<string,string>();
 constructor(private tool:(name:string,args?:Record<string,unknown>)=>Promise<any>,private t:(key:string)=>string,private refresh:()=>Promise<void>,private details:(id:string)=>void,private openSimulator:()=>void=()=>{}) {
  this.host.dataset.blockControl='true';this.popup.dataset.blockControl='true';this.popup.setAttribute('popover','auto');this.popup.setAttribute('role','dialog');this.popup.setAttribute('aria-label',t('build.parameters.title'));document.body.append(this.popup);
  this.host.append(this.content,this.status,this.issue);
  this.popup.addEventListener('keydown',event=>{if(event.key==='Escape')event.stopPropagation();});
  this.popup.addEventListener('toggle',event=>{if((event as ToggleEvent).newState==='closed'){this.popupKind='';this.anchor?.focus();}});
 }
 update(host:HTMLElement,mode:'mini'|'full'|'extended',context:Context|null,records:BuildRecord[],blocked=false) {
  if(this.host.parentElement!==host)host.append(this.host);
  const changed=key(context)!==key(this.context);
  if(changed){this.revision++;this.requests.clear();this.context=context;this.catalogue=null;this.tests=null;this.xcodeConfirmed=false;this.workspaces={};this.close();this.mode='';this.error='';this.records=[];void this.load(true);}
  this.records=records.filter(r=>r.context.checkoutId===context?.checkoutId&&r.context.sha===context?.sha&&r.context.branch===context?.branch&&(!context?.xcode||r.context.xcode===context.xcode)&&r.context.profileID===context?.profileID&&r.context.profileRevision===context?.profileRevision&&(r.context.appleTarget===undefined||key(r.context.appleTarget)===key(context?.appleTarget)));
  this.host.inert=blocked;
  if(this.mode!==mode){this.mode=mode;this.renderControls();this.renderStatus();}
  const record=this.current,signature=key([record?.id,record?.status,record?.stage,record?.products,record?.progressFraction]);
  if(signature!==this.activeSignature){this.activeSignature=signature;this.renderStatus();if(record?.parameters.intent==='catalogue'&&record.status==='succeeded')void this.load(true);if(record?.stage==='products'&&pending(record)&&(record.products?.length??0)>1&&!record.selectedProductID)this.open('products',this.host);}
  const current=this.current;
  if(current){const previous=this.previousStatuses.get(current.id);this.previousStatuses.set(current.id,current.status);if(previous&&previous!==current.status&&current.status==='succeeded'&&current.parameters.intent==='run')queueMicrotask(this.openSimulator);}
  if(this.popupKind==='products'&&(!pending(current)||current?.selectedProductID))this.close();
  this.updateControls();this.tick();
 }
 private get current(){return this.records.find(pending)??this.records[0];}
 private get testsCompatible(){return this.compatible&&(this.draft.backend==='xcodeMCP'||(this.catalogue!.testPlans.length<=1||!!this.draft.testPlan)&&(!this.draft.testPlan||this.catalogue!.testPlans.includes(this.draft.testPlan)));}
 private get busy(){return this.submitting||this.records.some(pending);}
 private get compatible(){if(this.draft.backend==='xcodeMCP')return !!this.context&&!!this.workspaces[this.draft.workspaceTab]&&this.xcodeConfirmed;return !!this.context&&!!this.catalogue?.schemes.includes(this.draft.scheme)&&!!this.catalogue?.configurations.includes(this.draft.configuration)&&!!this.catalogue?.destinations.some(d=>d.id===this.draft.destinationID);}
 private button(label:string,action:(button:HTMLButtonElement)=>void,cls=''){const button=node('button',this.t(label),cls);button.type='button';button.onclick=()=>action(button);return button;}
 private renderControls(){
  this.host.dataset.mode=this.mode;this.content.className="";
  this.content.replaceChildren();
  if(this.mode==='extended'){
   const tabs=node('div','','build-tabs');tabs.setAttribute('role','tablist');tabs.setAttribute('aria-label',this.t('build.action'));
   for(const action of ['build','run','tests']){const tab=this.button('build.tab.'+action,()=>{this.action=action;this.renderControls();this.renderStatus();this.updateControls();if(action==='tests')void this.load(false);});tab.setAttribute('role','tab');tab.setAttribute('aria-selected',String(this.action===action));tabs.append(tab);}this.content.append(tabs,node('p',this.t('build.purpose'),'muted'),this.settings());
   if(this.action==='tests')this.content.append(this.testPicker());else this.content.append(this.actionButton(this.action,true));
  }else{
   this.content.className=this.mode==='full'?'build-full-controls':'build-mini-controls';
   if(this.mode==='full')this.content.append(this.selections(true));else{const summary=this.button('build.parameters.title',button=>this.open('settings',button),'build-parameter-summary quiet');summary.dataset.parameters='';this.content.append(summary);}
   const actions=node('div','','build-launch-actions');actions.append(this.actionButton('run',true));const row=node('div','','build-secondary-actions');row.append(this.actionButton('build'),this.actionButton('tests'));actions.append(row);this.content.append(actions);
   if(this.mode==='full')this.content.append(this.button('build.moreSettings',button=>this.open('settings',button),'quiet'));
  }
 }
 private actionButton(action:string,primary=false){const button=this.button('build.action.'+action,b=>{this.action=action;if(action==='tests')this.open('tests',b);else if(!this.compatible||action==='run'&&this.draft.backend!=='cli')this.open('execute',b);else void this.execute(action);},primary?'primary build-action':'build-action');button.dataset.buildAction=action;return button;}
 private selections(compact=false){const fields=node('div','','build-settings-fields');for(const field of ['scheme','destinationID'] as const){const name=this.t(field==='scheme'?'build.scheme':'build.destination'),label=node('label',compact?'':name);const input=node('select');input.setAttribute('aria-label',name);input.dataset.buildField=field;input.onchange=()=>{this.draft[field]=input.value;this.draft.testIdentifiers=[];this.tests=null;if(field==='scheme'){this.draft.destinationID='';this.catalogue=null;void this.load(false);}this.save();this.updateControls();};label.append(input);fields.append(label);}return fields;}
 private settings(){const box=node('div','','build-settings');box.append(this.selections(),node('p',this.t('build.settings.required'),'build-settings-reason muted'),this.button('build.refreshSettings',()=>void this.load(false),'quiet'));
  const advanced=node('details');advanced.append(node('summary',this.t('build.moreSettings')));
  for(const field of ['backend','configuration','testPlan','workspaceTab'] as const){const label=node('label',this.t('build.'+field)),input=node('select');input.dataset.buildField=field;input.setAttribute('aria-label',label.textContent!);input.onchange=()=>{this.draft[field]=input.value as never;this.tests=null;this.draft.testIdentifiers=[];this.save();this.updateControls();};label.append(input);advanced.append(label);}
  const confirm=node('label',this.t('build.xcode.simulator.confirm'),'build-xcode-only');const checkbox=node('input');checkbox.type='checkbox';checkbox.checked=this.xcodeConfirmed;checkbox.onchange=()=>{this.xcodeConfirmed=checkbox.checked;this.updateControls();};confirm.prepend(checkbox);advanced.append(confirm);const connect=this.button('build.xcode.connect',()=>{void this.tool('panel_setup',{operation:'xcodeMCP'}).then(()=>this.load(false));},'quiet build-xcode-only');advanced.append(connect,node('p',this.t('build.run.cliRequired'),'muted'));box.append(advanced);return box;
 }
 private async call(operation:string,parameters:BuildDraft|Record<string,unknown>={},extra:Record<string,string>={}){return this.tool('panel_build_control',{context:this.context,operation,parameters:Object.hasOwn(parameters,'backend')?{...parameters,developerDirectory:this.developerDirectory}:parameters,requestID:'',activityID:'',productID:'',...extra});}
 private async load(restore:boolean){
  if(!this.context)return;const context=this.context,revision=++this.revision;this.loading=true;this.updateControls();
  try{
   const value=await this.call('get');if(revision!==this.revision||key(context)!==key(this.context))return;if(restore||value.developerDirectory!==this.developerDirectory){this.draft=value.draft;this.tests=value.catalogue?.tests??null;}this.developerDirectory=value.developerDirectory??'';
   const testsScope=this.popupKind==='tests'||this.mode==='extended'&&this.action==='tests';const scheme=this.draft.scheme,query=await this.tool('start_build_configuration',{context,scheme,includeTestPlans:testsScope});let result=query;const deadline=performance.now()+130000;
   while(result.status==='pending'){if(revision!==this.revision||scheme!==this.draft.scheme)return;if(performance.now()>deadline)throw new Error(this.t('build.error.catalogueTimeout'));await new Promise(resolve=>setTimeout(resolve,500));result=await this.tool('get_build_configuration_state',{queryID:query.queryID});}
   if(revision!==this.revision||key(context)!==key(this.context)||scheme!==this.draft.scheme)return;
   if(result.status!=='ready'||key(result.result.context)!==key(context))throw new Error(result.message??this.t('stale'));
   this.catalogue=result.result.cli;if(testsScope&&this.draft.testPlan&&!this.catalogue!.testPlans.includes(this.draft.testPlan)){this.draft.testPlan='';this.draft.testIdentifiers=[];this.tests=null;}this.workspaces=result.result.xcode?.workspaces??{};
   if(!this.catalogue!.schemes.includes(this.draft.scheme))this.draft.scheme='';if(!this.catalogue!.destinations.some(d=>d.id===this.draft.destinationID))this.draft.destinationID='';if(!this.catalogue!.configurations.includes(this.draft.configuration))this.draft.configuration=this.catalogue!.configurations.includes('Debug')?'Debug':'';
   this.error='';this.save();this.renderTestList();
  }catch(error){if(revision===this.revision)this.error=error instanceof Error?error.message:this.t('error');}
  finally{if(revision===this.revision){this.loading=false;this.updateControls();}}
 }
 private save(){clearTimeout(this.saveTimer);const context=this.context,draft=structuredClone(this.draft);this.saveTimer=setTimeout(()=>{if(key(context)!==key(this.context))return;void this.call('save',draft).catch(error=>{this.error=String(error);this.updateControls();});},150);}
 private async execute(action:string){
  if(this.busy||!this.context||!this.compatible||['tests','catalogue'].includes(action)&&!this.testsCompatible)return;
  this.submitting=true;this.error='';this.updateControls();const context=this.context,parameters=structuredClone(this.draft),confirmed=this.draft.backend==='xcodeMCP'&&this.xcodeConfirmed;const fingerprint=key([context,action,parameters]);const requestID=this.requests.get(fingerprint)??crypto.randomUUID();this.requests.set(fingerprint,requestID);
  try{clearTimeout(this.saveTimer);await this.call('save',parameters);if(key(context)!==key(this.context))return;await this.call(action,{...parameters,simulatorConfirmed:confirmed},{requestID});this.requests.delete(fingerprint);if(key(context)===key(this.context)&&action!=='catalogue')this.close();await this.refresh();}
  catch(error){const code=(error as {code?:string}).code;if(code&&!['unavailable','unknown'].includes(code))this.requests.delete(fingerprint);this.error=error instanceof Error?error.message:this.t('error');}
  finally{this.submitting=false;this.updateControls();}
 }
 private open(kind:string,anchor:HTMLElement){
  this.popupKind=kind;this.anchor=anchor;this.popup.replaceChildren();const header=node('div','','build-popover-header');header.append(node('h3',this.t(kind==='tests'?'build.tab.tests':kind==='products'?'build.chooseProduct':'build.parameters.title')),this.button('close',()=>this.close(),'quiet'));this.popup.append(header);
  if(kind==='tests')void this.load(false);
  if(kind==='products'){this.popup.append(node('p',this.t('build.product.explanation'),'muted'));const record=this.current;for(const product of record?.products??[])this.popup.append(this.button(product.name,()=>{void this.call('product',{}, {activityID:record!.id,productID:product.path}).then(()=>{this.close();return this.refresh();}).catch(error=>{this.error=String(error);this.updateControls();});}));}
  else{this.popup.append(this.settings());if(kind==='tests')this.popup.append(this.testPicker());else if(kind==='execute')this.popup.append(this.actionButton(this.action,true));else{this.popup.append(this.actionButton('run',true),this.actionButton('build'));}}
  this.updateControls();if(!this.popup.matches(':popover-open'))this.popup.showPopover();const rect=anchor.getBoundingClientRect(),width=Math.min(420,innerWidth-24);this.popup.style.width=width+'px';this.popup.style.left=Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';this.popup.style.top=Math.max(12,Math.min(rect.bottom+8,innerHeight-this.popup.offsetHeight-12))+'px';
  this.popup.querySelector<HTMLElement>(kind==='tests'&&this.compatible?'input[type=search]':kind==='products'?'button:not(.quiet)':'select')?.focus();
 }
 private close(){if(this.popup.matches(':popover-open'))this.popup.hidePopover();this.popupKind='';}
 private testPicker(){const box=node('div','','build-test-picker');box.append(node('p',this.t('build.catalogue.explanation'),'muted'));const load=this.button('build.catalogue.load',()=>void this.execute('catalogue'));load.dataset.catalogueLoad='';box.append(load);const search=node('input');search.type='search';search.placeholder=this.t('build.tests.search');search.setAttribute('aria-label',search.placeholder);search.value=this.search;search.oninput=()=>{this.search=search.value;this.renderTestList();};box.append(search);this.testList=node('div','','build-test-list');this.count=node('p','','muted');box.append(this.testList,this.count);const manual=node('details');manual.append(node('summary',this.t('build.tests.manual')));const input=node('textarea');input.setAttribute('aria-label',this.t('build.tests.manual'));input.value=this.draft.testIdentifiers.join('\n');input.oninput=()=>{this.draft.testIdentifiers=[...new Set(input.value.split('\n').map(s=>s.trim()).filter(Boolean))];this.save();this.renderTestList();this.updateControls();};manual.append(input);box.append(manual);const start=this.button('build.action.testsSelected',()=>void this.execute('tests'),'primary');start.dataset.testsStart='';box.append(start);this.renderTestList();return box;}
 private renderTestList(){this.testList.replaceChildren();const filtered=this.tests?.filter(test=>!this.search||test.id.toLocaleLowerCase().includes(this.search.toLocaleLowerCase()));if(!filtered?.length)this.testList.append(node('p',this.t(this.tests===null?'build.tests.notLoaded':this.tests.length?'build.tests.noMatches':'build.tests.empty'),'muted'));
  let group='';for(const test of filtered??[]){const next=test.target+' / '+test.className;if(group!==next){group=next;this.testList.append(node('strong',group));}const label=node('label',test.name,'build-test-row'),check=node('input');check.type='checkbox';check.checked=this.draft.testIdentifiers.includes(test.id);check.disabled=this.busy;check.onchange=()=>{if(check.checked){if(this.draft.testIdentifiers.length<100)this.draft.testIdentifiers.push(test.id);else check.checked=false;}else this.draft.testIdentifiers=this.draft.testIdentifiers.filter(id=>id!==test.id);this.save();this.updateControls();};label.prepend(check);label.title=test.id;this.testList.append(label);}this.count.textContent=this.t('build.tests.selected')+': '+this.draft.testIdentifiers.length+' / 100';
 }
 private updateControls(){
  // Pending work replaces launchers within the shared compact height.
  this.content.hidden=this.mode!=='extended'&&pending(this.current);
  const roots=[this.host,this.popup];for(const root of roots){for(const input of Array.from(root.querySelectorAll<HTMLSelectElement>('select[data-build-field]'))){const field=input.dataset.buildField as keyof BuildDraft;const choices=field==='scheme'?this.catalogue?.schemes??[]:field==='destinationID'?this.catalogue?.destinations??[]:field==='configuration'?this.catalogue?.configurations??[]:field==='backend'?['cli','xcodeMCP']:field==='workspaceTab'?Object.entries(this.workspaces).map(([id,name])=>({id,name})):this.catalogue?.testPlans??[];const signature=key(choices);if(input.dataset.choices!==signature){input.replaceChildren(new Option(this.t('build.choose'),''),...choices.map(c=>typeof c==='string'?new Option(field==='backend'?this.t('build.backend.'+c):c,c):new Option(c.name,c.id)));input.dataset.choices=signature;}input.value=String(this.draft[field]);input.disabled=this.busy||this.loading;if(field==='workspaceTab')input.parentElement!.hidden=this.draft.backend!=='xcodeMCP';}root.querySelectorAll<HTMLElement>('.build-xcode-only').forEach(n=>n.hidden=this.draft.backend!=='xcodeMCP');
   for(const button of Array.from(root.querySelectorAll<HTMLButtonElement>('[data-build-action]')))button.disabled=this.busy||!this.context;
   root.querySelectorAll<HTMLElement>('.build-settings-reason').forEach(n=>{n.hidden=this.compatible;n.textContent=this.loading?this.t('build.loadingSettings'):this.t('build.settings.required');});
   const summary=root.querySelector<HTMLElement>('[data-parameters]');if(summary){summary.textContent=(this.draft.scheme||this.t('build.chooseScheme'))+' · '+(this.catalogue?.destinations.find(d=>d.id===this.draft.destinationID)?.name??this.t('build.chooseDevice'));summary.title=summary.textContent;}
   for(const button of Array.from(root.querySelectorAll<HTMLButtonElement>('[data-catalogue-load]')))button.disabled=this.busy||!this.testsCompatible||this.draft.backend!=='cli';
   for(const button of Array.from(root.querySelectorAll<HTMLButtonElement>('[data-tests-start]')))button.disabled=this.busy||!this.testsCompatible||!this.draft.testIdentifiers.length||this.draft.testIdentifiers.length>100;
   root.querySelectorAll<HTMLInputElement|HTMLTextAreaElement>('.build-test-row input,textarea').forEach(input=>input.disabled=this.busy);
  }this.count.textContent=this.t('build.tests.selected')+': '+this.draft.testIdentifiers.length+' / 100';this.issue.textContent=this.error;this.issue.title=this.error;this.issue.hidden=!this.error;
 }
 private renderStatus(){
  this.status.replaceChildren();const record=this.current,compact=this.mode!=='extended';
  if(!record){const purpose=node('p',this.t(this.context?compact?'build.purpose.compact':'build.purpose':'build.project.required'),'muted');purpose.title=this.t('build.purpose');this.status.append(purpose);return;}
  if(pending(record)){const identity=node('p',[this.t(record.actionKey??'build.action.build'),record.parameters.scheme,['Codex','Claude Code','MCP'].includes(record.source)?this.t('build.initiator.agent')+' · '+record.source:record.source].join(' · '),'build-work-identity');identity.title=identity.textContent!;this.status.append(identity);}
  const row=node('div','','build-phase'),phase=node('span',this.t(record.phase));phase.title=record.errorCode?this.t('build.error.'+record.errorCode):phase.textContent!;row.append(phase,node('time'));this.status.append(row);
  const progress=node('div','','build-progress');progress.setAttribute('role','progressbar');progress.setAttribute('aria-label',this.t('build.progress'));const value=record.progressFraction;
  if(value!=null){progress.setAttribute('aria-valuenow',String(Math.round(value*100)));progress.append(node('div','','build-progress-fill'));progress.firstElementChild!.setAttribute('style','transform:scaleX('+value+')');}
  else if(pending(record)){progress.classList.add('indeterminate');progress.setAttribute('aria-valuetext',this.t('build.progress.active'));progress.append(node('div','','build-progress-fill'));}
  this.status.append(progress);
  if(record.completedStages!=null&&record.parameters.intent==='run'&&(!compact||pending(record)))this.status.append(node('p',this.t('build.progress.stages').replace('%d',String(record.completedStages)).replace('%d',String(record.progressTotal)),'muted'));
  if(record.completedTestCount!=null&&record.selectedTestCount!=null&&(!compact||pending(record)))this.status.append(node('p',this.t('build.progress.tests').replace('%d',String(record.completedTestCount)).replace('%d',String(record.selectedTestCount)),'muted'));
  if(record.errorCode&&!compact)this.status.append(node('p',this.t('build.error.'+record.errorCode),'error'));
  const controls=node('div','','build-work-actions');
  if(compact&&record.stage==='products'&&pending(record)&&(record.products?.length??0)>1)controls.append(this.button('build.chooseProduct',button=>this.open('products',button),'quiet'));
  if(record.canCancel){const cancel=this.button('build.stop',()=>void this.tool('cancel_build_activity',{activityID:record.id}).then(()=>this.refresh()).catch(error=>{this.error=String(error);this.updateControls();}),'quiet');cancel.dataset.buildCancel='';controls.append(cancel);}
  if(controls.children.length)this.status.append(controls);if(this.mode==='extended')this.status.append(this.button('build.output',()=>this.details(record.id),'quiet'));
 }
 tick(){const record=this.current,time=this.status.querySelector('time');if(!time||!record)return;const seconds=Math.max(0,Math.floor(((record.finishedAt?Date.parse(record.finishedAt):Date.now())-Date.parse(record.startedAt??record.createdAt))/1000));time.textContent=String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');}
}
