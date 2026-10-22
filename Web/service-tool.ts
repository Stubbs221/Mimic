// Created by Василий Маслов on 16.10.2026.
/** Service forms persist through the native owner; secrets and full responses never enter workspace drafts. */
export type ServiceField={id:string;title:string;kind:string;required:boolean;defaultValue:string;advanced:boolean;secret:boolean;source?:string;choices?:{value:string;title:string}[];customChoice?:boolean;pattern?:string};
type Variant={id:string;title:string;fields:ServiceField[]};
type Action={id:string;title:string;hint:string;usesUID:boolean;returnsUID:boolean;variants:Variant[]};
export type ServiceCatalog={id:string;title:string;block:`profile:${string}:${string}`;actions:Action[]};
type Configuration={tool:ServiceCatalog;context:{namespace:string;appVersion:string;[key:string]:unknown};state:{uid?:string;drafts?:Record<string,Record<string,string>>;recent?:{uid:string;contact:string}[];result?:Result}};
type Result={requestID:string;phase:string;namespace?:string;data?:unknown;httpStatus?:number};
const node=<K extends keyof HTMLElementTagNameMap>(tag:K,text='',className='')=>{const value=document.createElement(tag);value.textContent=text;value.className=className;return value;};
export function maskServiceSecrets(value:unknown):unknown {
 if(Array.isArray(value))return value.map(maskServiceSecrets);
 if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,/password|session|token|auth_code/i.test(key)?'••••••':maskServiceSecrets(item)]));
 return value;
}
export class ServiceToolPanel {
 readonly host=node('div','','service-tool');
 private config:Configuration|null=null;private identity='';private actionID='';private variantID='';private drafts:Record<string,Record<string,string>>={};private result:Result|null=null;private generation=0;private pending=false;private refreshing=false;private dirty=false;
 private namespace=node('span','','service-namespace');private uid=node('input');private recent=node('select');private action=node('select');private variant=node('select');private fields=node('div','','service-fields');private actions=node('div','','service-actions');private status=node('span','','service-status');private runButton:HTMLButtonElement;private resultButton:HTMLButtonElement;
 private popup:HTMLDialogElement|null=null;private saveTimer:ReturnType<typeof setTimeout>|undefined;private refreshKey='';
 constructor(readonly definition:ServiceCatalog,private call:<T=any>(name:string,args?:Record<string,unknown>)=>Promise<T>,private t:(key:string)=>string){
  const top=node('div','','service-target');this.uid.placeholder='UID';this.uid.setAttribute('aria-label','UID');this.uid.inputMode='numeric';this.uid.autocomplete='off';this.recent.setAttribute('aria-label',t('service.recent'));
  this.uid.oninput=()=>{this.prefillPhone();this.scheduleSave();};this.recent.onchange=()=>{if(this.recent.value==='clear'){void this.save(true);return;}if(this.recent.value){this.uid.value=this.recent.value;this.prefillPhone();this.scheduleSave();}};
  top.append(this.namespace,this.uid,this.recent);const selectors=node('div','','service-selectors');this.action.setAttribute('aria-label',t('service.action'));this.variant.setAttribute('aria-label',t('service.mode'));this.action.onchange=()=>{this.actionID=this.action.value;this.variantID=this.currentAction().variants[0].id;this.buildForm();};this.variant.onchange=()=>{this.variantID=this.variant.value;this.buildForm();};selectors.append(this.action,this.variant);
  for(const action of definition.actions)this.action.append(new Option(action.title,action.id));this.actionID=definition.actions[0].id;this.variantID=definition.actions[0].variants[0].id;
  this.runButton=this.button(t('service.run'),()=>void this.run());this.runButton.className='primary';this.resultButton=this.button(t('service.result'),()=>this.showResult());this.actions.append(this.runButton,this.button(t('service.extra'),()=>this.showExtra()),this.resultButton);this.status.setAttribute('role','status');this.host.append(top,selectors,this.fields,this.actions,this.status);
 }
 update(host:HTMLElement,key=''){if(this.host.parentElement!==host)host.replaceChildren(this.host);if(!this.config||this.refreshKey!==key){this.refreshKey=key;void this.refresh();}}
 dispose(){clearTimeout(this.saveTimer);this.generation++;this.popup?.remove();this.host.remove();}
 private button(title:string,action:()=>void){const b=node('button',title);b.type='button';b.onclick=action;return b;}
 private currentAction(){return this.definition.actions.find(a=>a.id===this.actionID)??this.definition.actions[0];}
 private currentVariant(){return this.currentAction().variants.find(v=>v.id===this.variantID)??this.currentAction().variants[0];}
 private key(){return this.actionID+':'+this.currentVariant().id;}
 private value(field:ServiceField){return this.drafts[this.key()]?.[field.id]??(field.source==='appVersion'?this.config?.context.appVersion??'':field.defaultValue);}
 private buildForm(){
  const action=this.currentAction();this.action.value=action.id;this.variant.replaceChildren(...action.variants.map(v=>new Option(v.title,v.id)));this.variant.value=this.currentVariant().id;this.variant.hidden=action.variants.length<2;
  this.uid.title=this.t(action.usesUID?'service.uidUsed':'service.uidUnused');this.fields.replaceChildren(...this.currentVariant().fields.filter(f=>!f.advanced).map(f=>this.editor(f)));this.paint();
 }
 private editor(field:ServiceField){
  const label=node('label','','service-field');label.title=field.title;let input:HTMLInputElement|HTMLSelectElement;
  if(field.choices&&!field.customChoice){const select=node('select');for(const option of field.choices)select.append(new Option(option.title,option.value));input=select;}
  else{const editor=node('input');editor.type=field.secret?'password':field.kind==='boolean'?'checkbox':'text';editor.placeholder=field.title;editor.autocomplete='off';editor.spellcheck=false;
   if(field.choices){const list=node('datalist');list.id='service-choices-'+crypto.randomUUID();for(const choice of field.choices){const option=node('option',choice.title);option.value=choice.value;list.append(option);}editor.setAttribute('list',list.id);label.append(list);}input=editor;}
  input.setAttribute('aria-label',field.title);if(input instanceof HTMLInputElement&&field.kind==='boolean')input.checked=this.value(field)==='true';else input.value=this.value(field);
  const changed=()=>{const value=input instanceof HTMLInputElement&&field.kind==='boolean'?String(input.checked):input.value;this.drafts[this.key()]??={};this.drafts[this.key()][field.id]=value;this.scheduleSave();};input.oninput=changed;input.onchange=changed;
  if(field.kind==='boolean'||field.advanced)label.append(node('span',field.title));label.append(input);return label;
 }
 private scheduleSave(){this.dirty=true;this.paint();clearTimeout(this.saveTimer);this.saveTimer=setTimeout(()=>void this.save(),250);}
 private async save(clearRecent=false){
  if(!this.config)return;const config=this.config;
  try{await this.call('panel_service_save',{toolID:this.definition.id,context:config.context,uid:this.uid.value.trim(),drafts:this.drafts,clearRecent});if(config===this.config)this.dirty=false;await this.refresh();}catch{this.status.textContent=this.t('service.invalid');}
 }
 private prefillPhone(){const user=this.config?.state.recent?.find(u=>u.uid===this.uid.value);if(!user?.contact||user.contact.includes('@'))return;for(const action of this.definition.actions)for(const variant of action.variants)if(variant.fields.some(f=>f.id==='phone')){this.drafts[action.id+':'+variant.id]??={};this.drafts[action.id+':'+variant.id].phone=user.contact;}this.buildForm();}
 private async refresh(){
  if(this.refreshing)return;this.refreshing=true;const generation=this.generation;
  try{const config=await this.call<Configuration>('panel_service_configuration',{toolID:this.definition.id});if(generation!==this.generation)return;
   const identity=JSON.stringify(config.context);if(identity!==this.identity){this.identity=identity;this.config=config;this.generation++;this.pending=false;this.dirty=false;this.drafts=config.state.drafts??{};this.uid.value=config.state.uid??'';this.result=config.state.result??null;this.popup?.close();this.buildForm();}else{this.config=config;if(!this.dirty&&document.activeElement!==this.uid)this.uid.value=config.state.uid??this.uid.value;if(!this.pending)this.result=config.state.result??this.result;}
   const selected=this.uid.value;this.recent.replaceChildren(new Option(this.t('service.recent'),''),...(config.state.recent??[]).map(u=>new Option(u.uid+' · '+u.contact,u.uid)),new Option(this.t('service.clearRecent'),'clear'));this.recent.value=(config.state.recent??[]).some(u=>u.uid===selected)?selected:'';this.namespace.textContent=config.context.namespace||this.t('service.noEnvironment');this.namespace.title=this.namespace.textContent;this.paint();
  }catch{this.status.textContent=this.t('service.unavailable');}finally{this.refreshing=false;}
 }
 private valid(){return !!this.config?.context.namespace&&(!this.currentAction().usesUID||/^[1-9][0-9]{0,19}$/.test(this.uid.value)&&BigInt(this.uid.value)<=18446744073709551615n)&&this.currentVariant().fields.every(f=>{
  const value=this.value(f);if(!value)return !f.required;if(value.length>4096)return false;if(f.pattern&&!new RegExp(f.pattern).test(value))return false;if(f.choices&&!f.customChoice&&!f.choices.some(c=>c.value===value))return false;
  if(f.kind==='integer')return /^[0-9]{1,20}$/.test(value)&&BigInt(value)<=18446744073709551615n;
  if(f.kind==='number')return Number.isFinite(Number(value))&&Number(value)>0;if(f.kind==='boolean')return ['true','false'].includes(value);if(f.kind==='datetime')return Number.isFinite(Date.parse(value));return true;
 });}
 private paint(){this.runButton.disabled=this.pending||!this.valid();this.resultButton.disabled=!this.result;this.action.disabled=this.variant.disabled=this.pending;this.uid.disabled=this.pending;this.status.textContent=this.t('service.'+(this.pending?'pending':this.result?.phase??'ready'));}
 private async run(){
  if(!this.config||this.pending||!this.valid())return;clearTimeout(this.saveTimer);await this.save();if(!this.config)return;
  const context=this.config.context,generation=this.generation,requestID=crypto.randomUUID(),parameters={...(this.drafts[this.key()]??{})};this.pending=true;this.paint();
  try{let result=await this.call<Result>('panel_service_run',{toolID:this.definition.id,context,requestID,actionID:this.actionID,variantID:this.currentVariant().id,uid:this.uid.value.trim(),parameters});
   while(result.phase==='pending'){await new Promise(resolve=>setTimeout(resolve,200));result=await this.call<Result>('panel_service_result',{toolID:this.definition.id,context,requestID});if(generation!==this.generation)return;}
   if(generation===this.generation){this.result=result;this.pending=false;await this.refresh();this.prefillPhone();}
  }catch(error){if(generation===this.generation){const code=error&&typeof error==='object'&&'code' in error?String(error.code):'';this.result={requestID,phase:code==='servicePersistence'?'persistence':['arguments','context','namespace','updating'].includes(code)?'failed':'unknown'};}}
  finally{if(generation===this.generation){this.pending=false;this.paint();}}
 }
 private dialog(title:string){this.popup?.remove();const dialog=node('dialog','','service-dialog');const heading=node('div','','service-actions');heading.append(node('strong',title),this.button(this.t('close'),()=>dialog.close()));dialog.append(heading);document.body.append(dialog);dialog.showModal();this.popup=dialog;return dialog;}
 private showExtra(){const dialog=this.dialog(this.t('service.extra'));dialog.append(node('p',this.currentAction().hint));for(const field of this.currentVariant().fields.filter(f=>f.advanced))dialog.append(this.editor(field));}
 private showResult(){
  const result=this.result;if(!result)return;const dialog=this.dialog(this.t('service.result')),body=node('pre'),reveal=node('input');reveal.type='checkbox';const label=node('label',this.t('service.reveal'));label.prepend(reveal);const json=()=>JSON.stringify(reveal.checked?result.data:maskServiceSecrets(result.data),null,2)??'';const paint=()=>{body.textContent=json();};reveal.onchange=paint;dialog.append(node('p',this.t('service.'+result.phase)+' · '+(result.namespace??'')));
  if(result.data&&typeof result.data==='object'&&!Array.isArray(result.data))for(const key of ['uid','email','phone','password','session','token','code','auth_code']){const value=(result.data as Record<string,unknown>)[key];if(value==null||value==='')continue;const row=node('div','','service-actions');row.append(node('span',key),this.button(this.t('service.copy'),()=>void navigator.clipboard.writeText(String(value))));dialog.append(row);}
  dialog.append(label,body,this.button(this.t('service.copyJSON'),()=>void navigator.clipboard.writeText(json())));paint();
 }
}
