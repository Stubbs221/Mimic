// Created by Василий Маслов on 06.10.2026.
import {gitlabMark} from './gitlab-mark';

/** Additive checkout-scoped presentation; missing evidence never becomes an inferred time or percentage. */
export type CICompactSummary={id:string;scopeID:string;checkout:string;accountUsername?:string|null;gitlabURL?:string|null;pipelineID?:number|null;displayID?:string|null;firstFailedJob?:string|null;failedChecks?:{id:number;name:string;url:string}[]|null;sha?:string|null;jenkinsURL?:string|null;allureURL?:string|null;analysisPrompt?:string|null;branch:string;status:string;createdAt?:string|null;startedAt?:string|null;finishedAt?:string|null;duration?:number|null;runningJobs:string[];completed?:number|null;total?:number|null;complete:boolean;waitingForManual:boolean;updatedAt?:string|null;stale:boolean};
type Translate=(key:string)=>string;
/** Missing configuration opens secure native token fields without disclosing the tile first. */
export function renderCISetup(host:HTMLElement,full:boolean,t:Translate,openSettings:()=>void){
 let root=host.querySelector<HTMLElement>(':scope > .ci-setup');
 if(!root){root=document.createElement('div');root.className='ci-setup';root.append(document.createElement('strong'),document.createElement('p'),document.createElement('button'));host.replaceChildren(root);}
 host.classList.remove('ci-runs','ci-two-runs');
 root.querySelector('strong')!.textContent=t(full?'ci.setup.title':'ci.setup.compactTitle');
 const detail=root.querySelector('p')!;detail.textContent=t('ci.setup.detail');detail.hidden=!full;
 const action=root.querySelector('button')!;action.type='button';action.className='primary';action.textContent=t('ci.setup.addToken');action.dataset.action='ci-add-token';action.onclick=event=>{event.stopPropagation();openSettings();};
}
export const ciIdentity=(summary:CICompactSummary)=>summary.scopeID+':'+summary.id;
export function ciActive(summary:CICompactSummary){return ['running','queued','triggering','pending','preparing','waiting_for_resource','manual','blocked','scheduled'].includes(summary.status);}
export function ciCanAnalyze(summary:CICompactSummary){return summary.status==='failed'||!!summary.failedChecks?.length||!!summary.firstFailedJob;}
const analysisMark='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M10 5l2.4 6.6L19 14l-6.6 2.4L10 23l-2.4-6.6L1 14l6.6-2.4L10 5Z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M19 1l1.1 3L23 5l-2.9 1.1L19 9l-1.1-2.9L15 5l2.9-1L19 1Z" fill="currentColor"/></svg>';
export function ciElapsed(seconds:number|null|undefined){
 if(seconds==null||!Number.isFinite(seconds))return '—';
 const value=Math.floor(Math.min(999999999,Math.max(0,seconds))),pad=(n:number)=>String(n).padStart(2,'0');
 return value>=3600?`${Math.floor(value/3600)}:${pad(Math.floor(value/60)%60)}:${pad(value%60)}`:`${Math.floor(value/60)}:${pad(value%60)}`;
}
function date(value:string|null|undefined){const result=value?new Date(value):null;return result&&Number.isFinite(result.getTime())?result:null;}
function start(value:string|null|undefined,now:Date){
 const parsed=date(value);if(!parsed)return '—';
 const time=parsed.toLocaleTimeString(undefined,{hour:'2-digit',minute:'2-digit'});
 return parsed.toDateString()===now.toDateString()?time:parsed.toLocaleDateString(undefined,{day:'2-digit',month:'2-digit',...(parsed.getFullYear()!==now.getFullYear()?{year:'numeric'}:{})})+' '+time;
}
export function ciDisplayID(summary:CICompactSummary,t:Translate){return summary.displayID??(summary.pipelineID!=null?'#'+summary.pipelineID:t('ci.compact.launch'));}
export function ciFraction(summary:CICompactSummary){
 return summary.complete&&summary.completed!=null&&summary.total!=null&&summary.total>0?Math.max(0,Math.min(1,summary.completed/summary.total)):null;
}
/** Preserve the meaningful end of a branch or path without breaking grapheme pairs. */
export function middleText(host:HTMLElement,value:string){
 if(host.children.length!==2){host.replaceChildren();for(const cls of ['ci-branch-prefix','ci-branch-suffix']){const span=document.createElement('span');span.className=cls;host.append(span);}}
 const chars=Array.from(new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(value),item=>item.segment),split=Math.ceil(chars.length*.65);host.children[0].textContent=chars.slice(0,split).join('');host.children[1].textContent=chars.slice(split).join('');host.title=value;host.setAttribute('aria-label',value);
}
/** Reuse the subtree while clocks, polling and dragging update independently. */
export function renderCompactCI(host:HTMLElement,summary:CICompactSummary|null|undefined,t:Translate,now=new Date(),compact=false){
 host.classList.toggle('ci-compact',!!summary);
 if(!summary){host.replaceChildren(document.createTextNode(t('ci.compact.empty')));return;}
 if(!host.querySelector('.ci-compact-branch')){
  host.replaceChildren();
  for(const cls of ['ci-run-heading','ci-compact-branch','ci-progress-group','ci-compact-timing','ci-compact-current']){const row=document.createElement('div');row.className=cls;host.append(row);}
  // Details stay intrinsic; collapsed runs push this group to the bottom.
  const footer=document.createElement('div');footer.className='ci-run-footer';
  const caption=document.createElement('div');caption.className='ci-progress-caption';caption.append(host.querySelector('.ci-compact-current')!);footer.append(caption);
  for(const cls of ['ci-progress-group','ci-compact-timing'])footer.append(host.querySelector('.'+cls)!);
  host.append(footer);
  const heading=host.querySelector('.ci-run-heading')!;for(const cls of ['ci-run-id','ci-compact-status','ci-compact-stale']){const span=document.createElement('span');span.className=cls;heading.append(span);}
  const timing=host.querySelector('.ci-compact-timing')!;for(const cls of ['ci-compact-start','ci-compact-elapsed']){const span=document.createElement('span');span.className=cls;timing.append(span);}
 }
 host.querySelector('.ci-run-id')!.textContent=ciDisplayID(summary,t);
 const status=host.querySelector<HTMLElement>('.ci-compact-status')!;status.textContent=t('ci.status.'+summary.status);status.title=status.textContent;status.dataset.status=summary.status;status.dataset.completion='';
 const stale=host.querySelector<HTMLElement>('.ci-compact-stale')!;stale.hidden=!summary.stale;stale.textContent='⚠';stale.setAttribute('aria-label',t('ci.compact.stale'));stale.title=t('ci.compact.stale');
 middleText(host.querySelector('.ci-compact-branch')!,summary.branch);
 renderCIProgress(host.querySelector('.ci-progress-group')!,summary,t,ciActive(summary),host.querySelector<HTMLElement>('.ci-compact-count'));
 const count=host.querySelector<HTMLElement>('.ci-compact-count')!;host.querySelector('.ci-progress-caption')!.append(count);
 count.hidden=!ciActive(summary);count.title=t(ciFraction(summary)==null?'ci.compact.progress.unknown':'ci.checks.progress');
 if(compact&&ciFraction(summary)==null)count.textContent='—';
 renderCITiming(host.querySelector('.ci-compact-timing')!,summary,t,now,compact);
 const job=host.querySelector<HTMLElement>('.ci-compact-current')!;
 const current=ciCurrent(summary,t,now);
 job.classList.toggle('ci-context-label',compact);job.textContent=current;job.hidden=!current;job.title=summary.runningJobs.length?summary.runningJobs.join('\n'):current;
 host.dataset.ciIdentity=ciIdentity(summary);
}
/** Both footer and details use the same clock; compact start time omits the redundant clock glyph. */
function renderCITiming(host:HTMLElement,summary:CICompactSummary,t:Translate,now:Date,compact=false){
 if(!host.firstElementChild)for(const cls of ['ci-compact-start','ci-compact-elapsed']){const span=document.createElement('span');span.className=cls;host.append(span);}
 const begin=host.querySelector<HTMLElement>('.ci-compact-start')!;begin.textContent=(compact?'':'◷ ')+start(summary.startedAt,now);begin.title=t('ci.time.begin')+' · '+(date(summary.startedAt)?.toLocaleString()??'—');begin.setAttribute('aria-label',begin.title);
 const parsed=date(summary.startedAt),duration=summary.status==='running'&&!summary.stale&&parsed?(now.getTime()-parsed.getTime())/1000:summary.duration;
 const elapsed=host.querySelector<HTMLElement>('.ci-compact-elapsed')!;elapsed.textContent='⏱ '+ciElapsed(duration);elapsed.title=t('ci.time.duration');elapsed.setAttribute('aria-label',elapsed.title+' '+ciElapsed(duration));
 }
/** Context belongs to this run; successful completion uses its reported finish time. */
export function ciCurrent(summary:CICompactSummary,t:Translate,now=new Date()){
 return summary.status==='failed'?(summary.firstFailedJob?t('ci.checks.failed')+' '+summary.firstFailedJob:''):ciActive(summary)?summary.runningJobs.length===1?summary.runningJobs[0]:summary.runningJobs.length>1?t('ci.checks.parallel').replace('%d',String(summary.runningJobs.length)):summary.waitingForManual?t('ci.checks.manual'):'':summary.finishedAt?t('ci.time.finished')+' '+start(summary.finishedAt,now):'';
}
export function renderCIProgress(host:HTMLElement,summary:CICompactSummary,t:Translate,visible:boolean,countElement:HTMLElement|null=null){
 host.hidden=!visible;
 if(!host.firstElementChild){const track=document.createElement('div');track.className='ci-compact-progress';track.append(document.createElement('div'));const count=document.createElement('span');count.className='ci-compact-count';host.append(track,count);}
 const track=host.firstElementChild as HTMLElement,fraction=ciFraction(summary);
 const color=['failed','error'].includes(summary.status)?'#c55c27':summary.status==='success'?'#2b9463':'var(--accent)';
 track.style.setProperty('--progress-fraction',String(fraction??0));
 (track.firstElementChild as HTMLElement).style.transform=`scaleX(${fraction??0})`;(track.firstElementChild as HTMLElement).style.background=color;
 track.setAttribute('role','progressbar');track.setAttribute('aria-label',t('ci.checks.progress'));track.setAttribute('aria-valuemin','0');track.setAttribute('aria-valuemax','100');
 if(fraction!=null){track.setAttribute('aria-valuenow',String(Math.round(fraction*100)));track.setAttribute('aria-valuetext',Math.round(fraction*100)+'%');}
 else{track.removeAttribute('aria-valuenow');track.setAttribute('aria-valuetext',t('ci.progress.unavailable'));}
 (countElement??host.querySelector('.ci-compact-count'))!.textContent=fraction==null?t('ci.compact.progress.unknown'):`${summary.completed}/${summary.total}`;
}
/** Keyed sibling controls preserve selection and focus without nesting the GitLab action in a button. */
export function renderCompactRuns(host:HTMLElement,summaries:CICompactSummary[],t:Translate,open:(summary:CICompactSummary)=>void,makeLink?:(label:string,url?:string)=>HTMLAnchorElement|null,analyze?:(summary:CICompactSummary)=>Promise<void>){
 host.classList.add('ci-runs');host.classList.toggle('ci-two-runs',summaries.length===2);
 const focused=host.contains(document.activeElement)?document.activeElement as HTMLElement:null;
 const old=new Map(Array.from(host.querySelectorAll<HTMLElement>(':scope > .ci-run-card')).map(node=>[node.dataset.ciIdentity!+'\0'+node.dataset.ciCheckout,node]));
 if(!summaries.length){host.replaceChildren(document.createTextNode(t('ci.compact.empty')));return;}
 if(!old.size)host.replaceChildren();
 for(const summary of summaries){
  const identity=ciIdentity(summary),key=identity+'\0'+summary.checkout;let card=old.get(key);
  if(!card){card=document.createElement('div');card.className='ci-run-card';const button=document.createElement('button');button.type='button';button.className='ci-run';button.append(document.createElement('div'));const footer=document.createElement('div');footer.className='ci-context-row';card.append(button,footer);}
  old.delete(key);card.dataset.ciIdentity=identity;card.dataset.ciCheckout=summary.checkout;
  const button=card.querySelector<HTMLButtonElement>('.ci-run')!;button.dataset.ciIdentity=identity;button.onclick=event=>{event.stopPropagation();open(summary);};button.setAttribute('aria-label',ciDisplayID(summary,t)+' · '+summary.branch);
  renderCompactCI(button.firstElementChild as HTMLElement,summary,t,new Date(),true);
  const footer=card.querySelector<HTMLElement>('.ci-context-row')!;footer.querySelector(':scope > .ci-context-label')?.remove();
  let timing=footer.querySelector<HTMLElement>('.ci-compact-timing');if(!timing){timing=document.createElement('div');timing.className='ci-compact-timing';footer.prepend(timing);}renderCITiming(timing,summary,t,new Date(),true);
  let ai=footer.querySelector<HTMLButtonElement>('.ci-ai');
  if(!ciCanAnalyze(summary)){ai?.remove();card.querySelector('.ci-ai-message')?.remove();}
  else{
   if(!ai){ai=document.createElement('button');ai.type='button';ai.className='ci-ai';ai.innerHTML=analysisMark;const label=document.createElement('span');label.textContent=t('ci.analysis.action');ai.append(label);footer.append(ai);}
   ai.title=t('ci.analysis.help');ai.setAttribute('aria-label',ai.title+' · '+ciDisplayID(summary,t));
   const action=ai,captured=structuredClone(summary);
   action.onclick=event=>{event.stopPropagation();if(action.dataset.pending==='true')return;action.dataset.pending='true';action.setAttribute('aria-busy','true');
    let message=card!.querySelector<HTMLElement>('.ci-ai-message');if(!message){message=document.createElement('div');message.className='ci-ai-message';message.setAttribute('role','status');card!.append(message);}message.textContent=t('ci.analysis.sending');message.hidden=false;
    void (async()=>{try{if(!analyze)throw new Error(t('ci.analysis.unavailable'));await analyze(captured);message!.textContent=t('ci.analysis.sent');}catch(error){message!.textContent=error instanceof Error?error.message:t('ci.analysis.unavailable');}finally{action.dataset.pending='false';action.removeAttribute('aria-busy');}})();
   };action.onpointerdown=event=>event.stopPropagation();
  }
  let action=footer.querySelector<HTMLAnchorElement>('.ci-gitlab');
  let url:string|undefined;try{if(summary.gitlabURL&&new URL(summary.gitlabURL).protocol==='https:')url=summary.gitlabURL;}catch{}
  if(!url){action?.remove();}else if(action?.href!==url){action?.remove();action=makeLink?.(t('ci.open.gitlab'),url)??null;if(!action){action=document.createElement('a');action.href=url;action.target='_blank';action.rel='noopener noreferrer';}action.className='ci-gitlab';action.innerHTML=gitlabMark;action.title=t('ci.open.gitlab');action.setAttribute('aria-label',t('ci.open.gitlab')+' · '+ciDisplayID(summary,t));action.addEventListener('click',event=>event.stopPropagation());action.addEventListener('pointerdown',event=>event.stopPropagation());footer.append(action);}
  if(action)footer.append(action);
  card.onkeydown=event=>{if(event.key==='Escape'){const message=card!.querySelector<HTMLElement>('.ci-ai-message');if(message&&!message.hidden){message.hidden=true;event.stopPropagation();}}};
  host.append(card);
 }
 for(const node of old.values())node.remove();
 if(focused?.isConnected&&document.activeElement!==focused)focused.focus({preventScroll:true});
}
