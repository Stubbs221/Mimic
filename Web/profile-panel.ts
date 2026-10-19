// Created by Василий Маслов on 16.10.2026.
/** Generic profile form. No project-specific keys, commands or application identifiers are bundled. */
export type CustomPanel={id:string;block:`profile:${string}:${string}`;title:string;actionID:string;fields:{id:string;title:string;pattern?:string;placeholder?:string}[];applications:{id:string;title:string}[]};
export type PanelResult={status:string;values:Record<string,string>;revision:string;devices:{id:string;title:string}[];developerMode:boolean};
type Context={checkoutId:string;profileRevision:string|null;[key:string]:unknown};
const node=<K extends keyof HTMLElementTagNameMap>(tag:K,text='')=>{const n=document.createElement(tag);n.textContent=text;return n;};

export class ProfilePanel {
 readonly host=node('div');private context:Context|null=null;private identity='';private generation=0;private pending=false;private result:PanelResult|null=null;private revision='';private baseline:Record<string,string>={};private values:Record<string,string>={};private conflict=false;private notice='';private activeRequest:{key:string;id:string}|null=null;
 private device=node('select');private application=node('select');private inputs=new Map<string,HTMLInputElement>();private resets=new Map<string,HTMLButtonElement>();private controls=node('div');private status=node('span');private apply:HTMLButtonElement;private resetAll:HTMLButtonElement;private reload:HTMLButtonElement;private overwrite:HTMLButtonElement;private retry:HTMLButtonElement;private refresh:HTMLButtonElement;private timer:ReturnType<typeof setInterval>;
 constructor(readonly definition:CustomPanel,private call:(name:string,args:Record<string,unknown>)=>Promise<any>,private t:(key:string)=>string,private draft:()=>Record<string,string>,private save:(value:Record<string,string>)=>void){
  this.host.className='profile-panel';this.host.dataset.panel=definition.id;
  const target=node('div');target.className='profile-panel-target';this.device.setAttribute('aria-label',t('customPanel.device'));this.application.setAttribute('aria-label',t('customPanel.application'));
  this.device.onchange=()=>void this.select();this.application.onchange=()=>void this.select();this.refresh=this.button(t('refresh'),()=>void this.run('read'));this.refresh.className='profile-panel-refresh';target.append(this.device,this.application,this.refresh);this.host.append(target);
  for(const app of definition.applications)this.application.append(new Option(app.title,app.id));
  for(const field of definition.fields){const row=node('label');row.className='profile-panel-field';const caption=node('span',field.title),input=node('input');caption.title=field.title;input.setAttribute('aria-label',field.title);input.placeholder=field.placeholder??t('customPanel.default');input.inputMode=field.pattern?'text':'numeric';input.autocomplete='off';input.spellcheck=false;input.oninput=()=>{this.values[field.id]=input.value;this.persist();this.paint();};input.onkeydown=event=>{if(event.key==='Enter'&&!this.conflict&&this.valid()){event.preventDefault();void this.run('apply');}};this.inputs.set(field.id,input);const reset=this.button('↶',()=>void this.run('reset',field.id));reset.title=t('customPanel.reset')+' '+field.title;reset.setAttribute('aria-label',reset.title);this.resets.set(field.id,reset);row.append(caption,input,reset);this.host.append(row);}
  this.controls.className='profile-panel-actions';this.apply=this.button(t('customPanel.apply'),()=>void this.run('apply'));this.apply.className='primary';this.resetAll=this.button(t('customPanel.resetAll'),()=>void this.run('resetAll'));this.reload=this.button(t('customPanel.reload'),()=>void this.reloadValues());this.overwrite=this.button(t('customPanel.overwrite'),()=>void this.run('apply','',true));this.retry=this.button(t('customPanel.retryLaunch'),()=>void this.run('launch'));this.controls.append(this.apply,this.resetAll,this.reload,this.overwrite,this.retry);this.status.className='profile-panel-status';this.status.setAttribute('role','status');this.host.append(this.controls,this.status);
  this.timer=setInterval(()=>{if(this.context&&!this.pending&&this.device.value&&!document.hidden&&this.host.isConnected&&!this.host.closest('[hidden]'))void this.run('read');},15000);
 }
 private button(title:string,action:()=>void){const b=node('button',title);b.type='button';b.onclick=action;return b;}
 update(host:HTMLElement,context:Context){
  if(this.host.parentElement!==host)host.replaceChildren(this.host);
  const identity=JSON.stringify(context);if(identity!==this.identity){this.generation++;this.context=context;this.identity=identity;this.result=null;this.revision='';this.pending=false;this.conflict=false;this.activeRequest=null;const saved=this.draft();this.device.replaceChildren(new Option(saved.device??'',saved.device??''));this.application.value=saved.application??this.definition.applications[0].id;this.restore();void this.start();}this.paint();
 }
 dispose(){clearInterval(this.timer);this.generation++;this.context=null;this.host.remove();}
 private targetKey(){return JSON.stringify([this.context?.checkoutId,this.device.value,this.application.value]);}
 private restore(){try{const saved=JSON.parse(this.draft().values??'{}')[this.targetKey()]??{};this.values=saved.values??{};this.baseline=saved.baseline??{};this.revision=saved.revision??'';}catch{this.values={};this.baseline={};this.revision='';}}
 private persist(){let all:Record<string,unknown>={};try{all=JSON.parse(this.draft().values??'{}');}catch{}all[this.targetKey()]={values:this.values,baseline:this.baseline,revision:this.revision};this.save({device:this.device.value,application:this.application.value,values:JSON.stringify(all)});}
 private async select(){if(this.pending)return;this.persistSelection();this.result=null;this.revision='';this.conflict=false;this.restore();this.paint();await this.run('read');}
 private persistSelection(){this.save({...this.draft(),device:this.device.value,application:this.application.value});}
 private async start(){await this.run('catalog');if(this.device.value)await this.select();}
 private valid(){return !!this.device.value&&!!this.application.value&&this.definition.fields.every(field=>{const value=(this.values[field.id]??'').trim();return !value||(field.pattern?value.length<=128&&new RegExp(field.pattern).test(value):/^[1-9][0-9]{0,19}$/.test(value));});}
 private dirty(){return this.definition.fields.some(field=>(this.values[field.id]??'')!==(this.baseline[field.id]??''));}
 private async reloadValues(){this.values={};this.baseline={};this.revision='';this.conflict=false;await this.run('read');}
 private async run(operation:string,field='',force=false){
  if(this.pending||!this.context||operation!=='catalog'&&!this.device.value)return;this.pending=true;this.paint();const generation=this.generation,context=this.context;
  const values=Object.fromEntries(this.definition.fields.map(field=>[field.id,(this.values[field.id]??'').trim()])),parameters={operation,device:this.device.value,application:this.application.value,values:JSON.stringify(operation==='apply'?values:{}),field,expectedRevision:this.revision,force:String(force)},key=JSON.stringify([context,this.definition.actionID,parameters]);
  if(this.activeRequest&&this.activeRequest.key!==key){this.notice=this.t('customPanel.unknown');this.pending=false;this.paint();return;}
  this.activeRequest??={key,id:crypto.randomUUID()};
  try{
   let record=await this.call('panel_profile_control',{context,actionID:this.definition.actionID,parameters,requestID:this.activeRequest.id});
   while(['queued','running'].includes(record.status)){await new Promise(resolve=>setTimeout(resolve,200));record=await this.call('get_task',{taskID:record.id});if(generation!==this.generation)return;}
   this.activeRequest=null;if(generation!==this.generation)return;const result=record.panelResult as PanelResult|undefined;if(!result)throw new Error(this.t('customPanel.failed'));
   this.result=result;this.notice=this.t('customPanel.'+result.status);
   if(operation==='catalog'){const selected=this.device.value;this.device.replaceChildren(...result.devices.map(d=>new Option(d.title,d.id)));if(result.devices.some(d=>d.id===selected))this.device.value=selected;this.persistSelection();return;}
   if(result.status==='conflict'||operation==='read'&&this.revision&&result.revision!==this.revision&&this.dirty()){this.conflict=true;return;}
   if(!['ready','shutdown','saved','launchFailed'].includes(result.status))return;
   const dirty=this.dirty();this.revision=result.revision;this.baseline=result.values;this.conflict=false;
   if(operation==='apply'||operation==='resetAll'||operation==='read'&&!dirty)this.values={...result.values};if(operation==='reset')this.values[field]='';this.persist();
  }catch(error){if(['catalog','read'].includes(operation))this.activeRequest=null;if(generation===this.generation)this.notice=error instanceof Error?error.message:this.t('customPanel.failed');}
  finally{if(generation===this.generation){this.pending=false;this.paint();}}
 }
 private paint(){
  const unavailable=this.pending||!this.revision;for(const control of [this.device,this.application,this.refresh])control.disabled=this.pending;
  for(const [id,input]of this.inputs){if(document.activeElement!==input)input.value=this.values[id]??'';input.disabled=this.pending;this.resets.get(id)!.disabled=unavailable||this.conflict;}
  this.apply.disabled=unavailable||!this.valid();this.resetAll.disabled=unavailable;this.overwrite.disabled=this.pending||!this.valid();this.reload.disabled=this.pending;this.retry.disabled=this.pending;
  this.apply.hidden=this.resetAll.hidden=this.conflict||this.result?.status==='launchFailed';this.reload.hidden=this.overwrite.hidden=!this.conflict;this.retry.hidden=this.result?.status!=='launchFailed'||this.conflict;
  this.status.textContent=this.t(this.pending?'customPanel.working':this.conflict?'customPanel.conflict':'')||this.notice;if(!this.pending&&!this.conflict)this.status.textContent=this.notice;this.status.title=this.status.textContent;
 }
}
