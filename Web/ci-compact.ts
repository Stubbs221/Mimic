// Created by Василий Маслов on 06.10.2026.

/** Additive checkout-scoped presentation; missing evidence never becomes an inferred time or percentage. */
export type CICompactSummary={id:string;scopeID:string;checkout:string;pipelineID?:number|null;displayID?:string|null;firstFailedJob?:string|null;branch:string;status:string;createdAt?:string|null;startedAt?:string|null;finishedAt?:string|null;duration?:number|null;runningJobs:string[];completed?:number|null;total?:number|null;complete:boolean;waitingForManual:boolean;updatedAt?:string|null;stale:boolean};
type Translate=(key:string)=>string;
export const ciIdentity=(summary:CICompactSummary)=>summary.scopeID+':'+summary.id;
export function ciActive(summary:CICompactSummary){return ['running','queued','triggering','pending','preparing','waiting_for_resource','manual','blocked','scheduled'].includes(summary.status);}
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
export function renderCompactCI(host:HTMLElement,summary:CICompactSummary|null|undefined,t:Translate,now=new Date()){
 host.classList.toggle('ci-compact',!!summary);
 if(!summary){host.replaceChildren(document.createTextNode(t('ci.compact.empty')));return;}
 if(!host.querySelector('.ci-compact-branch')){
  host.replaceChildren();
  for(const cls of ['ci-run-heading','ci-compact-branch','ci-progress-group','ci-compact-timing','ci-compact-current']){const row=document.createElement('div');row.className=cls;host.append(row);}
  // Details stay intrinsic; collapsed runs push this group to the bottom.
  const footer=document.createElement('div');footer.className='ci-run-footer';
  for(const cls of ['ci-progress-group','ci-compact-timing','ci-compact-current'])footer.append(host.querySelector('.'+cls)!);
  host.append(footer);
  const heading=host.querySelector('.ci-run-heading')!;for(const cls of ['ci-run-id','ci-compact-status','ci-compact-stale']){const span=document.createElement('span');span.className=cls;heading.append(span);}
  const timing=host.querySelector('.ci-compact-timing')!;for(const cls of ['ci-compact-start','ci-compact-elapsed']){const span=document.createElement('span');span.className=cls;timing.append(span);}
 }
 host.querySelector('.ci-run-id')!.textContent=ciDisplayID(summary,t);
 const status=host.querySelector<HTMLElement>('.ci-compact-status')!;status.textContent=t('ci.status.'+summary.status);status.title=status.textContent;status.dataset.status=summary.status;
 const stale=host.querySelector<HTMLElement>('.ci-compact-stale')!;stale.hidden=!summary.stale;stale.textContent='⚠';stale.setAttribute('aria-label',t('ci.compact.stale'));stale.title=t('ci.compact.stale');
 middleText(host.querySelector('.ci-compact-branch')!,summary.branch);
 renderCIProgress(host.querySelector('.ci-progress-group')!,summary,t,ciActive(summary));
 const begin=host.querySelector<HTMLElement>('.ci-compact-start')!;begin.textContent='◷ '+start(summary.startedAt,now);begin.title=t('ci.time.begin')+' · '+(date(summary.startedAt)?.toLocaleString()??'—');begin.setAttribute('aria-label',begin.title);
 const parsed=date(summary.startedAt),duration=summary.status==='running'&&!summary.stale&&parsed?(now.getTime()-parsed.getTime())/1000:summary.duration;
 const elapsed=host.querySelector<HTMLElement>('.ci-compact-elapsed')!;elapsed.textContent='⏱ '+ciElapsed(duration);elapsed.title=t('ci.time.duration');elapsed.setAttribute('aria-label',elapsed.title+' '+ciElapsed(duration));
 const job=host.querySelector<HTMLElement>('.ci-compact-current')!;
 const current=summary.status==='failed'?(summary.firstFailedJob?t('ci.checks.failed')+' '+summary.firstFailedJob:''):ciActive(summary)?summary.runningJobs.length===1?summary.runningJobs[0]:summary.runningJobs.length>1?t('ci.checks.parallel').replace('%d',String(summary.runningJobs.length)):summary.waitingForManual?t('ci.checks.manual'):'':'';
 job.textContent=current;job.hidden=!current;job.title=summary.runningJobs.length?summary.runningJobs.join('\n'):current;
 host.dataset.ciIdentity=ciIdentity(summary);
}
export function renderCIProgress(host:HTMLElement,summary:CICompactSummary,t:Translate,visible:boolean){
 host.hidden=!visible;
 if(!host.firstElementChild){const track=document.createElement('div');track.className='ci-compact-progress';track.append(document.createElement('div'));const count=document.createElement('span');count.className='ci-compact-count';host.append(track,count);}
 const track=host.firstElementChild as HTMLElement,fraction=ciFraction(summary);
 const color=['failed','error'].includes(summary.status)?'#c55c27':summary.status==='success'?'#2b9463':'var(--accent)';
 (track.firstElementChild as HTMLElement).style.transform=`scaleX(${fraction??0})`;(track.firstElementChild as HTMLElement).style.background=color;
 track.setAttribute('role','progressbar');track.setAttribute('aria-label',t('ci.checks.progress'));track.setAttribute('aria-valuemin','0');track.setAttribute('aria-valuemax','100');
 if(fraction!=null){track.setAttribute('aria-valuenow',String(Math.round(fraction*100)));track.setAttribute('aria-valuetext',Math.round(fraction*100)+'%');}
 else{track.removeAttribute('aria-valuenow');track.setAttribute('aria-valuetext',t('ci.progress.unavailable'));}
 host.querySelector('.ci-compact-count')!.textContent=fraction==null?t('ci.compact.progress.unknown'):`${summary.completed}/${summary.total}`;
}
/** Keyed buttons keep their focus and identity when status priority swaps columns. */
export function renderCompactRuns(host:HTMLElement,summaries:CICompactSummary[],t:Translate,open:(summary:CICompactSummary)=>void){
 host.classList.add('ci-runs');host.classList.toggle('ci-two-runs',summaries.length===2);
 const old=new Map(Array.from(host.querySelectorAll<HTMLButtonElement>(':scope > .ci-run')).map(node=>[node.dataset.ciIdentity!,node]));
 const focused=host.contains(document.activeElement)?(document.activeElement as HTMLElement)?.closest<HTMLElement>('.ci-run')?.dataset.ciIdentity:undefined;
 if(!summaries.length){host.replaceChildren(document.createTextNode(t('ci.compact.empty')));return;}
 if(!old.size)host.replaceChildren();
 for(const summary of summaries){const identity=ciIdentity(summary);let node=old.get(identity);if(!node){node=document.createElement('button');node.type='button';node.className='ci-run';node.append(document.createElement('div'));}old.delete(identity);node.dataset.ciIdentity=identity;node.onclick=event=>{event.stopPropagation();open(summary);};node.setAttribute('aria-label',ciDisplayID(summary,t)+' · '+summary.branch);renderCompactCI(node.firstElementChild as HTMLElement,summary,t);host.append(node);}
 for(const node of old.values())node.remove();
 if(focused){const node=Array.from(host.children).find(node=>(node as HTMLElement).dataset.ciIdentity===focused) as HTMLElement|undefined;node?.focus({preventScroll:true});}
}
