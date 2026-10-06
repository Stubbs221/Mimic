// Created by Василий Маслов on 06.10.2026.
import {ciIdentity,ciDisplayID,renderCompactCI,type CICompactSummary} from './ci-compact';

type Check={id:number;name:string;status:string;url:string;stage?:string;allowFailure:boolean;child?:boolean};
export type CIInspection={summary:CICompactSummary;loadState:'loading'|'loaded'|'partial'|'failed';error?:string|null;commitTitle?:string|null;sha?:string|null;initiator?:string|null;jobs:Check[];bridges:Check[];gitlabURL?:string|null;jenkinsURL?:string|null;allureURL?:string|null};
type Translate=(key:string)=>string;

/** One panel owns its selection; only cache data is shared with the native owner. */
export class PanelCIView {
 readonly host=document.createElement('section');
 private readonly choices=document.createElement('div');
 private readonly overview=document.createElement('div');
 private readonly body=document.createElement('div');
 private readonly message=document.createElement('p');
 private readonly retry=document.createElement('button');
 private selected:CICompactSummary|null=null;
 private summaries:CICompactSummary[]=[];
 private owner='';
 private visible=false;
 private generation=0;
 private pending:number|null=null;
 private lastRequest=0;
 private data:CIInspection|null=null;
 private error='';
 private signature='';
 constructor(private tool:(name:string,args:Record<string,unknown>)=>Promise<any>,private t:Translate,private link:(label:string,url?:string)=>HTMLAnchorElement|null){
  this.host.className='ci-inspection';this.choices.className='ci-run-choices';this.overview.className='ci-expanded-summary';this.body.className='ci-inspection-body';this.message.className='ci-inspection-message';this.retry.type='button';this.retry.textContent=t('ci.details.retry');this.retry.onclick=()=>void this.load(true);
  this.host.append(this.choices,this.overview,this.message,this.retry,this.body);
 }
 select(summary:CICompactSummary){
  if(!this.selected||ciIdentity(this.selected)!==ciIdentity(summary)){this.generation++;this.pending=null;this.lastRequest=0;this.data=null;this.error='';this.signature='';}
  this.selected=summary;this.render();if(this.visible)void this.load();
 }
 update(summaries:CICompactSummary[],checkout:string|undefined,visible:boolean){
  const owner=(checkout??'')+'\0'+(summaries[0]?.scopeID??'');
  if(this.owner!==owner){this.owner=owner;this.selected=null;this.data=null;this.error='';this.generation++;this.pending=null;this.lastRequest=0;this.signature='';}
  this.summaries=summaries;this.visible=visible;
  if(!this.selected&&summaries.length)this.selected=summaries[0];
  const newer=summaries.find(value=>this.selected&&ciIdentity(value)===ciIdentity(this.selected));if(newer)this.selected=newer;
  this.render();if(visible&&this.selected)void this.load();
 }
 tick(){if(this.visible&&this.selected)renderCompactCI(this.overview,this.selected,this.t);}
 private async load(refresh=false){
  if(!this.visible||!this.selected||this.pending!==null||!refresh&&Date.now()-this.lastRequest<4000)return;
  const generation=this.generation,identity=ciIdentity(this.selected),owner=this.owner;
  this.pending=generation;this.lastRequest=Date.now();this.error='';this.render();
  try{
   const result=await this.tool('panel_get_ci_details',{identity,refresh}) as CIInspection;
   if(generation!==this.generation||owner!==this.owner||!this.selected||identity!==ciIdentity(this.selected))return;
   if(!result.summary||ciIdentity(result.summary)!==identity||result.summary.checkout!==this.selected.checkout)throw new Error(this.t('stale'));
   if(this.selected.pipelineID!=null&&result.summary.pipelineID!==this.selected.pipelineID)return;
   this.data=result;this.selected=result.summary;
  }catch(error){if(generation===this.generation&&owner===this.owner)this.error=error instanceof Error?error.message:this.t('error');}
  finally{if(this.pending===generation){this.pending=null;this.render();}}
 }
 private render(){
  const selected=this.selected;
  const options=this.summaries.slice();if(selected&&!options.some(value=>ciIdentity(value)===ciIdentity(selected)))options.unshift(selected);
  const old=new Map(Array.from(this.choices.querySelectorAll<HTMLButtonElement>('button')).map(node=>[node.dataset.identity!,node]));
  const focused=(document.activeElement as HTMLElement|null)?.dataset.identity;
  for(const summary of options){const identity=ciIdentity(summary);let node=old.get(identity);if(!node){node=document.createElement('button');node.type='button';node.dataset.identity=identity;}old.delete(identity);node.textContent=ciDisplayID(summary,this.t)+' · '+this.t('ci.status.'+summary.status);node.setAttribute('aria-pressed',String(!!selected&&ciIdentity(selected)===identity));node.onclick=()=>this.select(summary);this.choices.append(node);}
  for(const node of old.values())node.remove();if(focused)(Array.from(this.choices.children).find(node=>(node as HTMLElement).dataset.identity===focused) as HTMLElement|undefined)?.focus({preventScroll:true});
  this.choices.hidden=options.length<2;
  renderCompactCI(this.overview,selected,this.t);
  const message=this.error||this.data?.error||(this.pending!==null||this.data?.loadState==='loading'?this.t('ci.checks.loading'):this.data?.loadState==='partial'?this.t('ci.checks.incomplete'):'');
  this.message.textContent=message;this.message.hidden=!message;this.retry.hidden=!this.error&&!this.data?.error&&this.data?.loadState!=='partial';this.retry.disabled=this.pending!==null;
  const signature=JSON.stringify([this.data,selected?.startedAt,selected?.finishedAt]);if(signature===this.signature)return;this.signature=signature;this.body.replaceChildren();if(!this.data)return;
  for(const value of [this.data.initiator,this.data.commitTitle,this.data.sha])if(value){const p=document.createElement('p');p.textContent=value;if(value===this.data.sha)p.className='mono';this.body.append(p);}
  for(const [key,value] of [['ci.time.created',this.data.summary.createdAt],['ci.time.begin',this.data.summary.startedAt],['ci.time.finished',this.data.summary.finishedAt]])if(value){const p=document.createElement('p');p.textContent=this.t(key!)+' · '+new Date(value).toLocaleString();this.body.append(p);}
  for(const child of [false,true]){
   const jobs=this.data.jobs.filter(job=>!!job.child===child);if(!jobs.length)continue;
   if(child){const title=document.createElement('h3');title.textContent=this.t('ci.children.jobs');this.body.append(title);}
   for(const job of jobs)this.check(job);
  }
  for(const bridge of this.data.bridges)this.check(bridge);
  const links=document.createElement('div');links.className='links';for(const [label,url] of [['GitLab',this.data.gitlabURL],['Jenkins',this.data.jenkinsURL],['Allure',this.data.allureURL]]){const a=this.link(label!,url??undefined);if(a)links.append(a);}this.body.append(links);
 }
 private check(check:Check){
  const row=document.createElement('div');row.className='ci-detail-check';const name=this.link(check.name,check.url)??document.createElement('span');name.textContent=check.name;name.title=check.name;
  const state=document.createElement('span');state.className='status '+check.status;state.textContent=this.t('ci.status.'+check.status);row.append(name,state);this.body.append(row);
  if(check.allowFailure&&check.status==='failed'){const note=document.createElement('p');note.textContent=this.t('ci.job.allowedFailure');this.body.append(note);}
 }
}
