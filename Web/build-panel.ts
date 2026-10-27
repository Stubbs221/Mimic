// Created by Василий Маслов on 09.10.2026.
type Context = {checkoutId:string;branch:string;sha:string;xcode:string;[key:string]:unknown};
export type BuildDraft = {operation:'build'|'test';backend:'cli'|'xcodeMCP';scheme:string;configuration:string;destinationID:string;testPlan:string;testIdentifiers:string[];testTarget?:string|null;workspaceTab:string;platform?:string};
type Product = {path:string;name:string;bundleIdentifier:string};
export type BuildRecord = {id:string;status:string;phase:string;source:string;actionKey?:string;startedAt?:string|null;finishedAt?:string|null;createdAt:string;canCancel:boolean;xcodeRequestID?:string|null;context:Context;parameters:{scheme:string;operation:string;backend?:string;intent?:string|null;destinationID:string};stage?:string|null;products?:Product[]|null;selectedProductID?:string|null;destinationName?:string|null;completedStages?:number|null;progressTotal?:number;progressFraction?:number|null;errorCode?:string|null;completedTestCount?:number|null;selectedTestCount?:number|null};
type CatalogueProgress = {phase:string;completed:number;total:number;startedAt:string};
type Catalogue = {schemes:string[];configurations:string[];destinations:{id:string;name:string;platform?:string}[];testPlans:string[];testTargets?:{name:string;testPlan:string}[]};
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
 private catalogue:Catalogue|null=null;private loadedAt=0;
 private catalogueProgress:CatalogueProgress|null=null;private catalogueStatus=false;
 private developerDirectory='';private workspaces:Record<string,string>={};private xcodeConfirmed=false;
 private presentationID:string|null|undefined;private viewed=new Set<string>();
 private mode=''; private action='tests'; private popupKind=''; private anchor:HTMLElement|null=null;
 private revision=0; private loading=false; private submitting=false; private error=''; private saveTimer:ReturnType<typeof setTimeout>|undefined;
 private content=node('div'); private status=node('div','','build-current-work'); private issue=node('p','','error');
 private activeSignature='';private previousStatuses=new Map<string,string>();private requests=new Map<string,string>();
 constructor(private tool:(name:string,args?:Record<string,unknown>)=>Promise<any>,private t:(key:string)=>string,private refresh:()=>Promise<void>,private details:(id:string)=>void,private openSimulator:()=>void=()=>{}) {
  this.host.dataset.blockControl='true';this.popup.dataset.blockControl='true';this.popup.setAttribute('popover','auto');this.popup.setAttribute('role','dialog');this.popup.setAttribute('aria-label',t('build.parameters.title'));document.body.append(this.popup);
  this.host.append(this.content,this.status,this.issue);
  this.host.addEventListener('click',event=>{if(this.mode==='extended'||event.target instanceof Element&&event.target.closest('button,select,[role=button]'))return;this.openFailure();});
  this.popup.addEventListener('keydown',event=>{if(event.key==='Escape')event.stopPropagation();});
  this.popup.addEventListener('toggle',event=>{if((event as ToggleEvent).newState==='closed'){this.popupKind='';this.anchor?.focus();}});
 }
 update(host:HTMLElement,mode:'mini'|'full'|'extended',context:Context|null,records:BuildRecord[],blocked=false,presentationID?:string|null) {
  if(this.host.parentElement!==host)host.append(this.host);
  const changed=key(context)!==key(this.context);
  if(changed){this.revision++;this.loading=false;this.requests.clear();this.context=context?structuredClone(context):null;this.catalogue=null;this.loadedAt=0;this.xcodeConfirmed=false;this.workspaces={};this.close();this.mode='';this.error='';this.records=[];void this.load(true);}
  this.records=records.filter(r=>r.context.checkoutId===context?.checkoutId&&r.context.sha===context?.sha&&r.context.branch===context?.branch&&(!context?.xcode||r.context.xcode===context.xcode)&&r.context.profileID===context?.profileID&&r.context.profileRevision===context?.profileRevision&&(r.context.appleTarget===undefined||key(r.context.appleTarget)===key(context?.appleTarget)));
  this.presentationID=presentationID;this.host.inert=blocked;
  if(this.mode!==mode){this.mode=mode;this.renderControls();this.renderStatus();}
  const record=this.current,signature=key([record?.id,record?.status,record?.stage,record?.products,record?.progressFraction,record?.canCancel,record?.xcodeRequestID,record?.errorCode]);
  if(signature!==this.activeSignature){this.activeSignature=signature;this.renderStatus();if(record?.parameters.intent==='catalogue'&&record.status==='succeeded')void this.load(true);if(record?.stage==='products'&&pending(record)&&(record.products?.length??0)>1&&!record.selectedProductID)this.open('products',this.host);}
  const current=this.current;
  if(current){const previous=this.previousStatuses.get(current.id);this.previousStatuses.set(current.id,current.status);if(previous&&previous!==current.status&&current.status==='succeeded'&&current.parameters.intent==='run')queueMicrotask(this.openSimulator);}
  if(this.popupKind==='products'&&(!pending(current)||current?.selectedProductID))this.close();
  this.updateControls();this.tick();
 }
 private get current(){
  if(this.presentationID!==undefined)return this.records.find(r=>r.id===this.presentationID);
  return this.records.find(pending)??this.records.find(r=>r.status==='unknown'&&(r as any).queueReleased!==true)??this.records.find(r=>['failed','interrupted','unknown'].includes(r.status)&&!this.viewed.has(r.id));
 }
 openFailure(){const record=this.current;if(!record||pending(record))return false;this.details(record.id);return true;}
 /** Only a successfully displayed result acknowledges its exact activity in the native owner. */
 resultOpened(id:string){const record=this.records.find(r=>r.id===id);if(!record||!['failed','interrupted','unknown'].includes(record.status))return;
  void this.call('viewed',{}, {activityID:id}).then(()=>{this.viewed.add(id);return this.refresh();}).catch(error=>{this.error=String(error);this.updateControls();});
 }
 private get testsCompatible(){return this.runCompatible&&!!this.catalogue?.testTargets?.some(t=>t.name===this.draft.testTarget);}
 private get busy(){return this.submitting||this.records.some(r=>pending(r)||r.status==='unknown'&&(r as any).queueReleased!==true);}
 private get runCompatible(){return !!this.context&&!!this.catalogue?.schemes.includes(this.draft.scheme)&&!!this.catalogue?.configurations.includes(this.draft.configuration)&&!!this.catalogue?.destinations.some(d=>d.id===this.draft.destinationID&&d.platform!=='tvos');}
 private get compatible(){return !!this.context&&!!this.catalogue?.schemes.includes(this.draft.scheme)&&!!this.catalogue?.configurations.includes(this.draft.configuration)&&!!this.catalogue?.destinations.some(d=>d.id===this.draft.destinationID);}

 private button(label:string,action:(button:HTMLButtonElement)=>void,cls=''){const button=node('button',this.t(label),cls);button.type='button';button.onclick=()=>action(button);return button;}
 private renderControls(){
  this.host.dataset.mode=this.mode;this.content.className='';this.content.replaceChildren();
  if(this.mode==='extended'){
   const tabs=node('div','','build-tabs');tabs.setAttribute('role','tablist');tabs.setAttribute('aria-label',this.t('build.action'));
   for(const action of ['build','run','tests']){const tab=this.button('build.tab.'+action,()=>{this.action=action;this.renderControls();this.renderStatus();this.updateControls();});tab.setAttribute('role','tab');tab.setAttribute('aria-selected',String(this.action===action));tabs.append(tab);}
   this.content.append(tabs,this.settings());if(this.action==='tests')this.content.append(this.testPicker());this.content.append(this.actionButton(this.action,true));
   if(this.records[0])this.content.append(this.button('build.output',()=>this.details(this.records[0].id),'quiet'));
  }else{
   this.content.className=this.mode==='full'?'build-full-controls':'build-mini-controls';
   if(this.mode==='full')this.content.append(this.selections(true,true));else{const summary=this.button('build.parameters.title',b=>this.open('settings',b),'build-parameter-summary quiet');summary.dataset.parameters='';this.content.append(summary,this.targetField(true));}
   const actions=node('div','','build-launch-actions');actions.append(this.actionButton('tests',true));
   if(this.mode==='full')actions.append(this.actionButton('run'),this.actionButton('build'));
   else{const row=node('div','','build-secondary-actions');row.append(this.actionButton('run'),this.actionButton('build'));actions.append(row);}this.content.append(actions);
  }
 }
 private actionButton(action:string,primary=false){const button=this.button(action==='tests'?'build.tests.runTarget':action==='run'&&this.mode!=='extended'?'build.action.runShort':'build.action.'+action,b=>{
  this.action=action;if(action==='tests'){void this.execute(action);return;}
  if(!(action==='run'?this.runCompatible:this.compatible))this.open('settings',b);else void this.execute(action);
 },primary?'primary build-action':'build-action');button.dataset.buildAction=action;return button;}
 private field(field:'scheme'|'destinationID'|'testTarget'|'configuration',label:string,compact=false){const row=node('label',compact?'':this.t(label)),input=node('select');input.setAttribute('aria-label',this.t(label));input.dataset.buildField=field;
  input.onchange=()=>{this.draft[field]=input.value;this.draft.testIdentifiers=[];if(field==='scheme'){this.revision++;this.loading=false;this.draft.testTarget=null;void this.load(false);}if(field==='testTarget')this.draft.testPlan=this.catalogue?.testTargets?.find(t=>t.name===input.value)?.testPlan??'';this.save();this.updateControls();};row.append(input);return row;
 }
 private targetField(compact=false){return this.field('testTarget',compact?'build.tests.target':'build.tests.targetLabel',compact);}
 private selections(compact=false,targets=false){const fields=node('div','','build-settings-fields');fields.append(this.field('scheme','build.scheme',compact),this.field('destinationID','build.destination',compact));if(targets)fields.append(this.targetField(true));return fields;}
 private settings(){const box=node('div','','build-settings');box.append(node('h3',this.t('build.environment')),this.selections(),this.progressView(),node('p','','build-catalogue-note muted'),node('p',this.t('build.settings.required'),'build-settings-reason muted'));
  const advanced=node('details');advanced.append(node('summary',this.t('build.moreSettings')),this.field('configuration','build.configuration'));box.append(advanced);
  const refresh=this.button('build.refreshSettings',()=>void this.load(false,true,true),'quiet');refresh.dataset.catalogueRefresh='';box.append(refresh);return box;
 }
 private async call(operation:string,parameters:BuildDraft|Record<string,unknown>={},extra:Record<string,string>={}){return this.tool('panel_build_control',{context:this.context,operation,parameters:Object.hasOwn(parameters,'backend')?{...parameters,developerDirectory:this.developerDirectory}:parameters,requestID:'',activityID:'',productID:'',...extra});}
 private async load(restore:boolean,discover=true,force=false){
  if(this.loading)return;
  if(!this.context)return;const context=this.context,revision=++this.revision;this.loading=true;this.catalogueProgress={phase:'checking',completed:0,total:0,startedAt:new Date().toISOString()};this.updateControls();
  try{
   if(force)await this.call('refresh');
   const value=await this.call('get');if(revision!==this.revision||key(context)!==key(this.context))return;if(restore||value.developerDirectory!==this.developerDirectory){this.draft=value.draft;}this.developerDirectory=value.developerDirectory??'';if(value.configuration&&value.draft.scheme===this.draft.scheme){this.catalogue=value.configuration.value;this.loadedAt=value.configuration.loadedAt;this.updateControls();}if(!discover)return;
   const testsScope=true;const scheme=this.draft.scheme,query=await this.tool('start_build_configuration',{context,scheme,includeTestPlans:testsScope});let result=query;const deadline=performance.now()+130000;
   while(result.status==='pending'){if(result.progress){this.catalogueProgress=result.progress;this.updateControls();}if(revision!==this.revision||scheme!==this.draft.scheme)return;if(performance.now()>deadline)throw new Error(this.t('build.error.catalogueTimeout'));await new Promise(resolve=>setTimeout(resolve,500));result=await this.tool('get_build_configuration_state',{queryID:query.queryID});}
   if(revision!==this.revision||key(context)!==key(this.context)||scheme!==this.draft.scheme)return;
   if(result.status!=='ready'||key(result.result.context)!==key(context))throw new Error(result.message??this.t('stale'));
   this.catalogue=result.result.cli;this.loadedAt=Date.now();if(testsScope&&this.draft.testPlan&&!this.catalogue!.testPlans.includes(this.draft.testPlan)){this.draft.testPlan='';this.draft.testIdentifiers=[];}this.workspaces=result.result.xcode?.workspaces??{};
   if(!this.catalogue!.schemes.includes(this.draft.scheme))this.draft.scheme='';if(!this.catalogue!.destinations.some(d=>d.id===this.draft.destinationID))this.draft.destinationID='';if(!this.catalogue!.configurations.includes(this.draft.configuration))this.draft.configuration=this.catalogue!.configurations.includes('Debug')?'Debug':'';
   if(!this.catalogue?.testTargets?.some(t=>t.name===this.draft.testTarget))this.draft.testTarget=this.catalogue?.testTargets?.[0]?.name??null;this.draft.testPlan=this.catalogue?.testTargets?.find(t=>t.name===this.draft.testTarget)?.testPlan??'';this.error='';this.save();
  }catch(error){if(revision===this.revision)this.error=error instanceof Error?error.message:this.t('error');}
  finally{if(revision===this.revision){this.loading=false;this.catalogueProgress=null;this.updateControls();}}
 }
 private save(){clearTimeout(this.saveTimer);const context=this.context,draft=structuredClone(this.draft);this.saveTimer=setTimeout(()=>{if(key(context)!==key(this.context))return;void this.call('save',draft).catch(error=>{this.error=String(error);this.updateControls();});},150);}
 private async execute(action:string){
  if(this.busy||!this.context||!(action==='tests'?this.testsCompatible:action==='run'?this.runCompatible:this.compatible))return;
  this.submitting=true;this.error='';this.updateControls();const context=this.context,parameters=structuredClone(this.draft),confirmed=this.draft.backend==='xcodeMCP'&&this.xcodeConfirmed;parameters.backend='cli';parameters.workspaceTab='';if(action==='tests'){parameters.testIdentifiers=[];}else{parameters.testTarget=null;parameters.testIdentifiers=[];}const fingerprint=key([context,action,parameters]);const requestID=this.requests.get(fingerprint)??crypto.randomUUID();this.requests.set(fingerprint,requestID);
  try{clearTimeout(this.saveTimer);await this.call('save',parameters);if(key(context)!==key(this.context))return;await this.call(action,{...parameters,simulatorConfirmed:confirmed},{requestID});this.requests.delete(fingerprint);if(key(context)===key(this.context)&&action!=='catalogue')this.close();await this.refresh();}
  catch(error){const code=(error as {code?:string}).code;if(code&&!['unavailable','unknown'].includes(code))this.requests.delete(fingerprint);this.error=error instanceof Error?error.message:this.t('error');}
  finally{this.submitting=false;this.updateControls();}
 }
 private open(kind:string,anchor:HTMLElement){
  this.popupKind=kind;this.anchor=anchor;this.popup.replaceChildren();const header=node('div','','build-popover-header');header.append(node('h3',this.t(kind==='tests'?'build.tab.tests':kind==='products'?'build.chooseProduct':'build.parameters.title')),this.button('close',()=>this.close(),'quiet'));this.popup.append(header);
  if(['tests','settings','execute'].includes(kind))void this.load(false);
  if(kind==='products'){this.popup.append(node('p',this.t('build.product.explanation'),'muted'));const record=this.current;for(const product of record?.products??[])this.popup.append(this.button(product.name,()=>{void this.call('product',{}, {activityID:record!.id,productID:product.path}).then(()=>{this.close();return this.refresh();}).catch(error=>{this.error=String(error);this.updateControls();});}));}
  else{this.popup.append(this.settings());if(kind==='tests')this.popup.append(this.testPicker());else if(kind==='execute')this.popup.append(this.actionButton(this.action,true));else{this.popup.append(this.actionButton('run',true),this.actionButton('build'));}}
  this.updateControls();if(!this.popup.matches(':popover-open'))this.popup.showPopover();const rect=anchor.getBoundingClientRect(),width=Math.min(420,innerWidth-24);this.popup.style.width=width+'px';this.popup.style.left=Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';this.popup.style.top=Math.max(12,Math.min(rect.bottom+8,innerHeight-this.popup.offsetHeight-12))+'px';
  this.popup.querySelector<HTMLElement>(kind==='tests'&&this.compatible?'input[type=search]':kind==='products'?'button:not(.quiet)':'select')?.focus();
 }
 private close(){if(this.popup.matches(':popover-open'))this.popup.hidePopover();this.popupKind='';}
 private testPicker(){const box=node('div','','build-test-picker');box.append(node('h3',this.t('build.tests.target')),this.targetField());const note=node('p',this.t('build.tests.noTargets'),'build-target-note muted');note.hidden=!!this.catalogue?.testTargets?.length;box.append(note);return box;}
 /** Each surface shows the same completed steps; elapsed time never changes the fill. */
 private progressView(){const box=node('div','','build-catalogue-progress');const row=node('div','','build-phase');row.append(node('span','','build-catalogue-label'),node('span','','build-catalogue-counter'),node('time'));const bar=node('div','','build-progress');bar.setAttribute('role','progressbar');bar.setAttribute('aria-label',this.t('build.catalogue.progress.label'));bar.append(node('div','','build-progress-fill'));box.append(row,bar);return box;}
 private updateControls(){
  this.content.hidden=this.mode!=='extended'&&!!this.current;this.host.dataset.working=String(!!this.current);
  for(const root of [this.host,this.popup]){
   for(const input of Array.from(root.querySelectorAll<HTMLSelectElement>('select[data-build-field]'))){const field=input.dataset.buildField as keyof BuildDraft;const choices:({id:string;name:string}|string)[]=field==='scheme'?this.catalogue?.schemes??[]:field==='destinationID'?this.catalogue?.destinations??[]:field==='configuration'?this.catalogue?.configurations??[]:(this.catalogue?.testTargets??[]).map(t=>({id:t.name,name:t.name}));
    const signature=key(choices);if(input.dataset.choices!==signature){input.replaceChildren(new Option(this.t(field==='testTarget'&&!choices.length?'build.tests.noTargets':'build.choose'),''),...choices.map(c=>typeof c==='string'?new Option(c,c):new Option(c.name,c.id)));input.dataset.choices=signature;}
    input.value=String(this.draft[field]??'');input.disabled=this.busy||!choices.length;input.title=input.selectedOptions[0]?.text??'';
   }
   root.querySelectorAll<HTMLButtonElement>('[data-build-action]').forEach(b=>b.disabled=this.busy||!this.context||b.dataset.buildAction==='tests'&&!this.testsCompatible);
   root.querySelectorAll<HTMLButtonElement>('[data-catalogue-refresh]').forEach(b=>b.disabled=this.loading||this.busy);
   root.querySelectorAll<HTMLElement>('.build-target-note').forEach(n=>n.hidden=!!this.catalogue?.testTargets?.length);
   const summary=root.querySelector<HTMLElement>('[data-parameters]');if(summary){summary.textContent=(this.draft.scheme||this.t('build.chooseScheme'))+' · '+(this.catalogue?.destinations.find(d=>d.id===this.draft.destinationID)?.name??this.t('build.chooseDevice'))+' ⌄';summary.title=summary.textContent;}
   root.querySelectorAll<HTMLElement>('.build-settings-reason').forEach(n=>{n.hidden=this.compatible;});
   root.querySelectorAll<HTMLElement>('.build-catalogue-note').forEach(n=>n.hidden=true);
   root.querySelectorAll<HTMLElement>('.build-catalogue-progress').forEach(box=>{box.hidden=!this.loading;const value=this.catalogueProgress;if(!value)return;box.querySelector('.build-catalogue-label')!.textContent=this.t('build.catalogue.progress.'+value.phase);box.querySelector('.build-catalogue-counter')!.textContent=value.total?Math.min(value.completed+1,value.total)+'/'+value.total:'';box.querySelector('time')!.dateTime=value.startedAt;const bar=box.querySelector<HTMLElement>('.build-progress')!;bar.setAttribute('aria-valuenow',String(value.completed));bar.setAttribute('aria-valuemax',String(value.total||1));bar.firstElementChild!.setAttribute('style','transform:scaleX('+(value.total?value.completed/value.total:0)+')');});
  }
  this.issue.textContent=this.error;this.issue.hidden=!this.error||this.mode!=='extended';this.tick();
 }
 private renderStatus(){
  this.status.replaceChildren();const record=this.current;this.status.hidden=!record;this.status.onclick=null;this.status.onkeydown=null;this.status.removeAttribute('role');this.status.removeAttribute('tabindex');if(!record)return;
  const left=node('div','','build-work-progress'),right=node('div','','build-work-actions');
  left.append(node('p',[this.t(record.actionKey??'build.action.build'),record.parameters.scheme].filter(Boolean).join(' · '),'build-work-identity'),node('p',this.t(record.errorCode?'build.error.'+record.errorCode:record.phase),'build-work-phase'));
  const bar=node('div','','build-progress');bar.setAttribute('role','progressbar');bar.setAttribute('aria-label',this.t('build.progress'));const value=record.progressFraction;
  if(value!=null){bar.setAttribute('aria-valuenow',String(Math.round(value*100)));const fill=node('div','','build-progress-fill');fill.style.transform='scaleX('+value+')';bar.append(fill);}else if(pending(record)){bar.classList.add('indeterminate');bar.setAttribute('aria-valuetext',this.t('build.progress.active'));bar.append(node('div','','build-progress-fill'));}
  left.append(bar);const time=node('time');right.append(time);
  if(pending(record)&&record.stage==='products'&&(record.products?.length??0)>1)right.append(this.button('build.chooseProduct',b=>this.open('products',b),'quiet'));
  if(record.canCancel){const cancel=this.button(record.parameters.backend==='xcodeMCP'&&record.xcodeRequestID?'build.stop.request':'build.stop',()=>void this.tool('cancel_build_activity',{activityID:record.id}).then(()=>this.refresh()).catch(error=>{this.error=String(error);this.updateControls();}),'quiet');cancel.dataset.buildCancel='';cancel.addEventListener('click',e=>e.stopPropagation());right.append(cancel);}
  else{this.status.setAttribute('role','button');this.status.tabIndex=0;this.status.setAttribute('aria-label',this.t('build.output'));this.status.onclick=()=>this.details(record.id);this.status.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();e.stopPropagation();this.details(record.id);}};right.append(node('span',this.t('build.output'),'build-error-open'));}
  this.status.dataset.failed=String(!pending(record));this.status.append(left,right);this.tick();
 }
 tick(){for(const root of [this.host,this.popup])for(const time of Array.from(root.querySelectorAll<HTMLTimeElement>('.build-catalogue-progress time'))){const seconds=Math.max(0,Math.floor((Date.now()-Date.parse(time.dateTime))/1000));if(Number.isFinite(seconds))time.textContent=String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');}const record=this.catalogueStatus?undefined:this.current,time=this.status.querySelector('time');if(!time||!record)return;const seconds=Math.max(0,Math.floor(((record.finishedAt?Date.parse(record.finishedAt):Date.now())-Date.parse(record.startedAt??record.createdAt))/1000));const value=String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');if(time.textContent!==value)time.textContent=value;}
}
