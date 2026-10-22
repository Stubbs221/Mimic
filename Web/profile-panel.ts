// Created by Василий Маслов on 16.10.2026.
/** Environment controls with an adapter-defined target. No project-specific keys, commands or application identifiers are bundled. */
export type CustomPanel={id:string;block:`profile:${string}:${string}`;title:string;actionID:string;fields:{id:string;title:string;pattern?:string;placeholder?:string}[];applications:{id:string;title:string}[]};
export type PanelResult={status:string;values:Record<string,string>;revision:string;devices:{id:string;title:string}[];developerMode:boolean};
type Context={checkoutId:string;profileRevision:string|null;[key:string]:unknown};
const node=<K extends keyof HTMLElementTagNameMap>(tag:K,text='')=>{const n=document.createElement(tag);n.textContent=text;return n;};

export class ProfilePanel {
 readonly host=node('div');private context:Context|null=null;private identity='';private generation=0;private pending=false;private result:PanelResult|null=null;private revision='';private baseline:Record<string,string>={};private values:Record<string,string>={};private conflict=false;private notice='';private activeRequest:{id:string;operation:string;field:string;discardDraft:boolean;target:string;draft:Record<string,string>}|null=null;
 private device=node('select');private application=node('select');private inputs=new Map<string,HTMLInputElement>();private controls=node('div');private status=node('span');private apply:HTMLButtonElement;private resetAll:HTMLButtonElement;private refresh:HTMLButtonElement;
 constructor(readonly definition:CustomPanel,private call:(name:string,args:Record<string,unknown>)=>Promise<any>,private t:(key:string)=>string,private draft:()=>Record<string,string>,private save:(value:Record<string,string>)=>void){
  this.host.className='profile-panel';this.host.dataset.panel=definition.id;
  this.refresh=this.button(t('refresh'),()=>void(this.result?this.run('read','',false,this.conflict):this.start()));this.refresh.className='profile-panel-refresh';this.refresh.setAttribute('aria-label',t('refresh'));
  for(const app of definition.applications)this.application.append(new Option(app.title,app.id));
  for(const field of definition.fields){const row=node('label');row.className='profile-panel-field';const caption=node('span',field.title),input=node('input');caption.title=field.title;input.setAttribute('aria-label',field.title);input.placeholder=field.placeholder??t('customPanel.default');input.inputMode=field.pattern?'text':'numeric';input.autocomplete='off';input.spellcheck=false;input.oninput=()=>{this.values[field.id]=input.value;this.persist();this.paint();};input.onkeydown=event=>{if(event.key==='Enter'&&!this.conflict&&this.valid()){event.preventDefault();void this.run('apply');}};this.inputs.set(field.id,input);row.append(caption,input);this.host.append(row);}
  this.controls.className='profile-panel-actions';this.apply=this.button(t('customPanel.apply'),()=>void this.run(this.result?.status==='launchFailed'?'launch':'apply'));this.apply.className='primary';this.resetAll=this.button(t('customPanel.resetAll'),()=>void this.run('resetAll'));this.controls.append(this.resetAll,this.apply,this.refresh);this.status.className='profile-panel-status';this.status.setAttribute('role','status');this.host.append(this.controls,this.status);
 }
 private button(title:string,action:()=>void){const b=node('button',title);b.type='button';b.onclick=action;return b;}
 update(host:HTMLElement,context:Context){
  if(this.host.parentElement!==host)host.replaceChildren(this.host);
  const identity=JSON.stringify([context.checkoutId,context.branch,context.sha,context.xcode,context.profileID,context.profileRevision]);if(identity!==this.identity){this.generation++;this.context=context;this.identity=identity;this.result=null;this.revision='';this.pending=false;this.conflict=false;this.activeRequest=null;const saved=this.draft();this.device.replaceChildren(new Option(saved.device??'',saved.device??''));this.application.value=this.definition.applications[0].id;this.restore();}this.paint();
 }
 dispose(){this.generation++;this.context=null;this.host.remove();}
 private targetKey(){return JSON.stringify([this.context?.checkoutId,this.device.value,this.application.value]);}
 private restore(){try{const saved=JSON.parse(this.draft().values??'{}')[this.targetKey()]??{};this.values=saved.values??{};this.baseline=saved.baseline??{};this.revision=saved.profileRevision===this.context?.profileRevision?saved.revision??'':'';}catch{this.values={};this.baseline={};this.revision='';}}
 private persist(){let all:Record<string,unknown>={};try{all=JSON.parse(this.draft().values??'{}');}catch{}all[this.targetKey()]={values:this.values,baseline:this.baseline,revision:this.revision,profileRevision:this.context?.profileRevision};this.save({device:this.device.value,application:this.application.value,values:JSON.stringify(all)});}
 private async select(){if(this.pending)return;this.persistSelection();this.result=null;this.revision='';this.conflict=false;this.restore();this.paint();await this.run('read');}
 private persistSelection(){this.save({...this.draft(),device:this.device.value,application:this.application.value});}
 private async start(){await this.run('catalog');if(this.device.value)await this.select();}
 private valid(){return !!this.device.value&&!!this.application.value&&this.definition.fields.every(field=>{const value=(this.values[field.id]??'').trim();return !value||(field.pattern?new TextEncoder().encode(value).length<=128&&new RegExp('^(?:'+field.pattern+')$').test(value):/^[1-9][0-9]{0,19}$/.test(value));});}
 private dirty(){return this.definition.fields.some(field=>(this.values[field.id]??'')!==(this.baseline[field.id]??''));}
 private async reloadValues(){await this.run('read','',false,true);}
 private async run(operation:string,field='',force=false,discardDraft=false){
  if(this.pending||!this.context||operation!=='catalog'&&!this.device.value)return;this.pending=true;this.paint();const generation=this.generation,context=this.context;
  const values=Object.fromEntries(this.definition.fields.map(field=>[field.id,(this.values[field.id]??'').trim()])),parameters={operation,device:this.device.value,application:this.application.value,values:JSON.stringify(operation==='apply'?values:{}),field,expectedRevision:this.revision,force:String(force)};
  // An uncertain mutation is observed by its original ID; it is never submitted again.
  const resuming=this.activeRequest!==null;
  this.activeRequest??={id:crypto.randomUUID(),operation,field,discardDraft,target:this.targetKey(),draft:{...this.values}};
  const active=this.activeRequest;
  ({operation,field,discardDraft}=this.activeRequest);
  try{
   let record=resuming?await this.call('get_task',{taskID:this.activeRequest.id}):await this.call('panel_profile_control',{context,actionID:this.definition.actionID,parameters,requestID:this.activeRequest.id});
   if(generation!==this.generation)return;
   while(['queued','running'].includes(record.status)){await new Promise(resolve=>setTimeout(resolve,200));record=await this.call('get_task',{taskID:record.id});if(generation!==this.generation)return;}
   if(generation!==this.generation)return;this.activeRequest=null;
   if(active.target!==this.targetKey()){queueMicrotask(()=>{if(generation===this.generation)void this.run('read');});return;}
   const edited=new Set(this.definition.fields.filter(field=>(this.values[field.id]??'')!==(active.draft[field.id]??'')).map(field=>field.id));
   const result=record.panelResult as PanelResult|undefined;if(record.status!=='succeeded'||!result)throw new Error(this.t('customPanel.failed'));
   this.result=result;this.notice=this.t('customPanel.'+result.status);
   if(operation==='catalog'){const selected=this.device.value;this.device.replaceChildren(...result.devices.map(d=>new Option(d.title,d.id)));if(result.devices.some(d=>d.id===selected))this.device.value=selected;this.persistSelection();return;}
   if(result.status==='conflict'||operation==='read'&&!discardDraft&&this.revision&&result.revision!==this.revision&&this.dirty()){this.conflict=true;return;}
   if(!['ready','shutdown','saved','launchFailed'].includes(result.status))return;
   const dirty=this.dirty();this.revision=result.revision;this.baseline=result.values;this.conflict=false;
   if(operation==='apply'||operation==='resetAll'){const drafts=this.values;this.values={...result.values};for(const id of edited)this.values[id]=drafts[id]??'';}
   if(operation==='read'&&(discardDraft||!dirty))this.values={...result.values};if(operation==='reset'&&!edited.has(field))this.values[field]='';this.persist();
  }catch(error){if(generation===this.generation){if(['catalog','read'].includes(operation))this.activeRequest=null;this.notice=error instanceof Error?error.message:this.t('customPanel.failed');}}
  finally{if(generation===this.generation){this.pending=false;this.paint();}}
 }
 private paint(){
  const unavailable=this.pending||!this.revision;for(const control of [this.device,this.application,this.refresh])control.disabled=this.pending;
  for(const [id,input]of this.inputs){if(document.activeElement!==input||input.disabled)input.value=this.values[id]??'';input.disabled=this.pending;}
  this.apply.disabled=unavailable||!this.valid()||this.conflict;this.resetAll.disabled=unavailable||this.conflict;
  this.status.textContent=this.t(this.pending?'customPanel.working':this.conflict?'customPanel.conflict':'')||this.notice;if(!this.pending&&!this.conflict)this.status.textContent=this.notice||(!this.result?this.t(this.revision?'customPanel.cached':'customPanel.refreshRequired'):'');this.status.title=this.status.textContent;
 }
}
