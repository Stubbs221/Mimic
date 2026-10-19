// Created by Василий Маслов on 13.10.2026.
type WorkDocument={id:string;title:string;url:string;version?:number;content?:string;nextOffset?:number;incomplete?:boolean};
type WorkIssue={key:string;title:string;status:string;url:string;description:string;requirements:Record<string,string>;documents:WorkDocument[];incomplete:boolean};
export type WorkSnapshot={presetID?:string;phase:string;candidates:string[];issue?:WorkIssue;fetchedAt?:string;stale:boolean;error?:string;manual:boolean;connecting?:boolean;message?:string;presets?:{id:string;title:string}[]};
type Evidence={id:string;title:string;result:string};
type Context={checkoutId:string;branch:string;profileRevision:string|null};
const node=<K extends keyof HTMLElementTagNameMap>(tag:K,text='',className='')=>{const n=document.createElement(tag);n.textContent=text;n.className=className;return n;};

/** B23/02 keeps the tile fixed; polling preserves open drafts and rejects previous-branch responses. */
export class WorkPanel {
 readonly host=node('div','','work-panel');
 private snapshot:WorkSnapshot={phase:'unconfigured',candidates:[],stale:false,manual:false};
 private identity='';private generation=0;private full=true;private dialog:HTMLDialogElement|null=null;private busy=false;
 private copyAction:HTMLButtonElement;private documentsAction:HTMLButtonElement;private connectionAction:HTMLButtonElement;
 private dismissPopup:(()=>void)|null=null;
 private heading=node('div','','work-header');private selector:HTMLButtonElement;
 private title=node('button','','work-title');private status=node('p','','work-status');private actions=node('div','','work-actions');
 constructor(private call:<T=any>(name:string,args?:Record<string,unknown>)=>Promise<T>,private t:(key:string)=>string,private open:(url:string)=>Promise<void>,private send:(text:string)=>Promise<void>){
  this.selector=this.button(t('work.choose'),()=>this.actionsMenu());this.heading.append(this.selector,this.status);
  this.title.type='button';this.title.onclick=()=>this.criteria();
  // Retain compact controls: polling must not detach the keyboard target.
  this.copyAction=this.button('',()=>{const issue=this.snapshot.issue;if(issue)void this.copy(this.contextText(issue));},'primary');
  this.documentsAction=this.button('',()=>this.documents());
  this.connectionAction=this.button('',()=>['choose','empty'].includes(this.snapshot.phase)?this.search():this.connection(),'primary');
  this.actions.append(this.copyAction,this.documentsAction,this.connectionAction);this.host.append(this.heading,this.title,this.actions);
 }
 update(parent:HTMLElement,full:boolean,snapshot:WorkSnapshot|undefined,context:Context|null){
  const identity=JSON.stringify([context?.checkoutId,context?.branch,context?.profileRevision,snapshot?.presetID,snapshot?.issue?.key]);if(identity!==this.identity){this.identity=identity;this.generation++;this.closePopup();}
  this.snapshot=snapshot??{phase:'unconfigured',candidates:[],stale:false,manual:false};this.full=full;if(this.host.parentElement!==parent)parent.append(this.host);parent.classList.add('work-summary');this.host.classList.toggle('work-mini',!full);
  const issue=this.snapshot.issue;this.selector.textContent=(issue?.key??this.t('work.choose'))+' ⌄';this.title.textContent=issue?.title??this.t('work.phase.'+this.snapshot.phase);this.title.disabled=!issue;
  const error=this.snapshot.error;
  this.status.textContent=error?this.t('work.stale'):this.snapshot.stale?this.t('work.stale'):this.snapshot.phase==='loading'?this.t('work.phase.loading'):this.snapshot.message??issue?.status??'';
  this.status.title=[error?this.t('work.error.'+error):'',this.status.textContent,this.snapshot.fetchedAt?new Date(this.snapshot.fetchedAt).toLocaleString():'',issue?.incomplete?this.t('work.incomplete'):''].filter(Boolean).join(' · ');
  this.title.title=issue?.title??this.title.textContent??'';
  this.copyAction.hidden=this.documentsAction.hidden=!issue;
  this.connectionAction.hidden=!!issue||this.snapshot.phase==='loading';
  this.copyAction.textContent=this.t(full?'work.context.copy':'work.context');
  this.documentsAction.textContent=this.t('work.documents')+(full?' · '+(issue?.documents.length??0):'');
  this.connectionAction.textContent=this.t(['choose','empty'].includes(this.snapshot.phase)?'work.choose':'work.connect');
 }

 private actionsMenu(){
  const dialog=this.popup(this.t('work.popup.actions'),this.selector),issue=this.snapshot.issue;
  if(issue)dialog.append(this.button(this.t('work.openJira'),()=>void this.open(issue.url)),this.button(this.t('work.criteria'),()=>this.criteria()),this.button(this.t('work.report'),()=>void this.report()));
  dialog.append(this.button(this.t('work.choose'),()=>this.search()));
  for(const key of this.snapshot.candidates)dialog.append(this.button(key,()=>void this.select(key)));
  dialog.append(this.button(this.t('work.search.confluence'),()=>this.search('confluence')));
  const refresh=this.button(this.t('refresh'),()=>void this.refresh());refresh.disabled=this.snapshot.phase==='loading';dialog.append(refresh,this.button(this.t('work.connect'),()=>this.connection()));
  if(this.snapshot.error)dialog.append(node('p',this.t('work.error.'+this.snapshot.error),'work-status'));
 }
 private button(label:string,action:()=>void,tone='quiet'){const n=node('button',label,'work-button '+tone);n.type='button';n.onclick=action;return n;}
 private closePopup(){this.dismissPopup?.();this.dismissPopup=null;const old=this.dialog;this.dialog=null;old?.close();old?.remove();}
 /** Compact lists are anchored, nonmodal popovers; editors retain their modal presentation. */
 private popup(title:string,anchor?:HTMLElement){
  this.closePopup();const dialog=node('dialog','','work-dialog'),header=node('div','','work-header');
  header.append(node('strong',title),this.button(this.t('work.close'),()=>dialog.close()));dialog.append(header);document.body.append(dialog);this.dialog=dialog;
  if(anchor){
   dialog.classList.add('work-popover');dialog.show();
   const position=()=>{const a=anchor.getBoundingClientRect(),r=dialog.getBoundingClientRect();dialog.style.left=Math.max(16,Math.min(a.left,innerWidth-r.width-16))+'px';dialog.style.top=Math.max(16,a.bottom+8+r.height<=innerHeight-16?a.bottom+8:a.top-r.height-8)+'px';};
   // Position after the caller has populated the list, and keep it anchored through reflow.
   const observer=new ResizeObserver(position);observer.observe(dialog);position();
   const outside=(e:PointerEvent)=>{if(!dialog.contains(e.target as Node)&&!anchor.contains(e.target as Node))dialog.close();};
   const escape=(e:KeyboardEvent)=>{if(e.key==='Escape'&&dialog.open){e.preventDefault();dialog.close();}};
   document.addEventListener('pointerdown',outside,true);document.addEventListener('keydown',escape,true);window.addEventListener('resize',position);window.addEventListener('scroll',position,true);
   const cleanup=()=>{observer.disconnect();document.removeEventListener('pointerdown',outside,true);document.removeEventListener('keydown',escape,true);window.removeEventListener('resize',position);window.removeEventListener('scroll',position,true);};
   this.dismissPopup=cleanup;dialog.addEventListener('close',()=>{cleanup();if(this.dialog===dialog&&anchor.isConnected&&(document.activeElement===document.body||dialog.contains(document.activeElement)))anchor.focus({preventScroll:true});},{once:true});
  }else{dialog.showModal();dialog.addEventListener('click',e=>{if(e.target===dialog)dialog.close();});}
  return dialog;
 }
 private async operation(body:()=>Promise<void>){if(this.busy)return;const generation=this.generation;this.busy=true;this.host.setAttribute('aria-busy','true');try{await body();}catch(e){if(generation===this.generation){this.status.textContent=e instanceof Error?e.message:this.t('work.error.network');this.status.title=this.status.textContent;this.status.setAttribute('role','status');}}finally{this.busy=false;this.host.removeAttribute('aria-busy');}}
 private async refresh(){await this.operation(async()=>{const generation=this.generation,result=await this.call<WorkSnapshot>('panel_work_context',{refresh:true});if(generation===this.generation){this.snapshot=result;this.update(this.host.parentElement!,this.full,result,JSON.parse(this.identity).length?{checkoutId:JSON.parse(this.identity)[0],branch:JSON.parse(this.identity)[1],profileRevision:JSON.parse(this.identity)[2]}:null);}});}
 private async select(issue:string){await this.operation(async()=>{const generation=this.generation;const result=await this.call<WorkSnapshot>('panel_work_select',{issue});if(generation===this.generation){this.snapshot=result;this.dialog?.close();await this.refreshAfterAction();}});}
 private async refreshAfterAction(){const generation=this.generation;const result=await this.call<WorkSnapshot>('panel_work_context',{});if(generation===this.generation){this.snapshot=result;this.update(this.host.parentElement!,this.full,result,{checkoutId:JSON.parse(this.identity)[0],branch:JSON.parse(this.identity)[1],profileRevision:JSON.parse(this.identity)[2]});}}
 private search(initialService='jira'){
  const dialog=this.popup(this.t('work.popup.search')),input=node('input'),service=node('select'),results=node('div','','work-search-results');input.placeholder=this.t('work.search.placeholder');service.append(new Option('Jira','jira'),new Option('Confluence','confluence'));service.value=initialService;
  let cursor:string|undefined;const run=(more=false)=>void this.operation(async()=>{const generation=this.generation;const query=input.value.trim();if(!query)return;const result=await this.call<{issues?:WorkIssue[];documents?:WorkDocument[];nextCursor?:string}>('panel_work_search',{query,service:service.value,...(more&&cursor?{cursor}:{})});if(generation!==this.generation||!dialog.open)return;results.replaceChildren();for(const issue of result.issues??[])results.append(this.button(issue.key+' · '+issue.title,()=>void this.select(issue.key)));for(const page of result.documents??[])results.append(this.button(page.title,()=>void this.read(page)));cursor=result.nextCursor;if(cursor)results.append(this.button(this.t('work.more'),()=>run(true)));});
  input.onkeydown=e=>{if(e.key==='Enter')run();};dialog.append(input,service,this.button(this.t('work.search'),()=>run(),'secondary'),results);input.focus();
  dialog.append(this.button(this.t('work.connect'),()=>this.connection()));
 }
 private documents(){
  const dialog=this.popup(this.t('work.documents'),this.documentsAction),pages=this.snapshot.issue?.documents??[];
  if(!pages.length)dialog.append(node('p',this.t('work.documents.empty'),'work-status'));
  for(const page of pages){const row=node('div','','work-document-row'),copy=this.button('⧉',()=>void this.copy(page.url,'work.link.copied'));copy.title=this.t('work.link.copy');copy.setAttribute('aria-label',this.t('work.link.copy')+' · '+page.title);row.append(this.button(page.title+' ↗',()=>void this.open(page.url)),copy);dialog.append(row);}
  dialog.append(this.button(this.t('work.readHere'),()=>this.reader()),this.button(this.t('work.search.confluence'),()=>this.search('confluence')));
 }
 private reader(){const dialog=this.popup(this.t('work.readHere'));for(const page of this.snapshot.issue?.documents??[])dialog.append(this.button(page.title,()=>void this.read(page),'secondary'));}

 private async read(page:WorkDocument,offset=0){await this.operation(async()=>{const generation=this.generation;const result=await this.call<WorkDocument>('panel_work_page',{page:page.id,offset});if(generation!==this.generation)return;const dialog=this.popup(result.title);dialog.append(node('pre',result.content??'','work-document'));if(result.incomplete)dialog.append(node('p',this.t('work.incomplete')));if(result.nextOffset!==undefined&&result.nextOffset!==null)dialog.append(this.button(this.t('work.more'),()=>void this.read(result,result.nextOffset)));dialog.append(this.button(this.t('work.openOriginal'),()=>void this.open(result.url)));});}
 private criteria(){const issue=this.snapshot.issue;if(!issue)return;const dialog=this.popup(this.t('work.criteria'));dialog.append(node('pre',issue.description,'work-document'));for(const [key,value]of Object.entries(issue.requirements??{}))dialog.append(node('strong',key),node('pre',value,'work-document'));}
 private connection(){const dialog=this.popup(this.t('work.connect'));if(!this.snapshot.presets?.length)dialog.append(node('p',this.t('work.unconfigured')));for(const preset of this.snapshot.presets??[])dialog.append(this.button(preset.title+(preset.id===this.snapshot.presetID?' ✓':''),()=>void this.operation(async()=>{await this.call('panel_work_connect',{operation:'choose',presetID:preset.id});await this.refreshAfterAction();dialog.close();}),'secondary'));
  dialog.append(this.button(this.t('work.connect'),()=>void this.operation(async()=>{await this.call('panel_work_connect',{operation:'connect'});dialog.close();}),'secondary'),this.button(this.t('work.disconnect'),()=>void this.operation(async()=>{await this.call('panel_work_connect',{operation:'disconnect'});await this.refreshAfterAction();dialog.close();})));
 }
 private async report(){await this.operation(async()=>{
  const generation=this.generation;const result=await this.call<{text:string;evidence:Evidence[]}>('panel_work_report',{evidenceIDs:[]});if(generation!==this.generation)return;const dialog=this.popup(this.t('work.report')),selected=new Set<string>(),editor=node('textarea');editor.value=result.text;editor.rows=10;
  for(const evidence of result.evidence){const label=node('label',evidence.title+' · '+evidence.result),check=node('input');check.type='checkbox';check.onchange=()=>{if(check.checked)selected.add(evidence.id);else selected.delete(evidence.id);};label.prepend(check);dialog.append(label);}
  dialog.append(this.button(this.t('work.report.prepare'),()=>void this.operation(async()=>{const next=await this.call<{text:string}>('panel_work_report',{evidenceIDs:[...selected]});if(generation===this.generation&&dialog.open)editor.value=next.text;}),'secondary'),editor,this.button(this.t('work.copy'),()=>void this.copy(editor.value),'secondary'),this.button(this.t('work.agent.extend'),()=>void this.send(this.t('work.agent.prompt')+'\n\n'+editor.value)));
 });}
 private contextText(issue:WorkIssue){return [issue.key+' · '+issue.title,issue.url,issue.status,issue.description,...Object.entries(issue.requirements??{}).map(([k,v])=>k+': '+v),...issue.documents.map(d=>d.title+': '+d.url)].join('\n\n');}
 private async copy(value:string,message='work.copied'){try{await navigator.clipboard.writeText(value);this.status.textContent=this.t(message);this.status.setAttribute('role','status');}catch{const dialog=this.popup(this.t('work.copy')),area=node('textarea');area.value=value;area.rows=10;dialog.append(area);area.focus();area.select();}}
}
