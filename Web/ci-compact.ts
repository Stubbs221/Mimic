// Created by Василий Маслов on 06.10.2026.

/** Additive get_state presentation: absent values are unknown, never inferred from creation time. */
export type CICompactSummary={id:string;scopeID:string;checkout:string;pipelineID?:number|null;branch:string;status:string;createdAt?:string|null;startedAt?:string|null;finishedAt?:string|null;duration?:number|null;runningJobs:string[];completed?:number|null;total?:number|null;complete:boolean;waitingForManual:boolean;updatedAt?:string|null;stale:boolean};
type Translate=(key:string)=>string;
const active=(status:string)=>['running','queued','triggering','pending','preparing','waiting_for_resource','manual','blocked','scheduled'].includes(status);
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
function current(summary:CICompactSummary,t:Translate){
 if(summary.runningJobs.length===1)return t('ci.checks.current')+' '+summary.runningJobs[0];
 if(summary.runningJobs.length>1)return t('ci.checks.parallel').replace('%d',String(summary.runningJobs.length));
 if(summary.waitingForManual)return t('ci.checks.manual');
 return t(summary.status==='running'?'ci.progress.unavailable':'ci.status.'+summary.status);
}
export function ciFraction(summary:CICompactSummary){
 return summary.complete&&summary.completed!=null&&summary.total!=null&&summary.total>0?Math.max(0,Math.min(1,summary.completed/summary.total)):null;
}
/** Reuse the same DOM subtree while the clock, polling and card dragging update independently. */
export function renderCompactCI(host:HTMLElement,summary:CICompactSummary|null|undefined,t:Translate,now=new Date()){
 host.classList.toggle('ci-compact',!!summary);
 if(!summary){host.replaceChildren(document.createTextNode(t('ci.compact.empty')));return;}
 if(!host.querySelector('.ci-compact-branch')){
  host.replaceChildren();
  const branch=document.createElement('div');branch.className='ci-compact-branch';
  for(const cls of ['ci-branch-prefix','ci-branch-suffix']){const span=document.createElement('span');span.className=cls;branch.append(span);}host.append(branch);
  const timing=document.createElement('div');timing.className='ci-compact-timing';
  for(const cls of ['ci-compact-start','ci-compact-elapsed']){const span=document.createElement('span');span.className=cls;timing.append(span);}host.append(timing);
  const job=document.createElement('div');job.className='ci-compact-current';host.append(job);
  const footer=document.createElement('div');footer.className='ci-compact-footer';host.append(footer);
  for(const cls of ['ci-compact-count','ci-compact-stale']){const row=document.createElement('span');row.className=cls;footer.append(row);}
 }
 const branch=host.querySelector<HTMLElement>('.ci-compact-branch')!;
 const chars=Array.from(summary.branch),split=Math.ceil(chars.length*.65);
 branch.children[0].textContent=chars.slice(0,split).join('');branch.children[1].textContent=chars.slice(split).join('');branch.title=summary.branch;branch.setAttribute('aria-label',summary.branch);
 host.querySelector('.ci-compact-start')!.textContent=t('ci.time.begin')+' '+start(summary.startedAt,now);
 const parsed=date(summary.startedAt),duration=summary.status==='running'&&!summary.stale&&parsed?(now.getTime()-parsed.getTime())/1000:summary.duration;
 host.querySelector('.ci-compact-elapsed')!.textContent=t('ci.time.duration')+' '+ciElapsed(duration);
 const job=host.querySelector<HTMLElement>('.ci-compact-current')!;job.textContent=current(summary,t);job.title=summary.runningJobs.length?summary.runningJobs.join('\n'):job.textContent;
 host.querySelector('.ci-compact-count')!.textContent=t('ci.compact.completed').replace('%@',String(summary.completed??'—')).replace('%@',String(summary.complete?summary.total??'—':'—'));
 const stale=host.querySelector<HTMLElement>('.ci-compact-stale')!;stale.hidden=!summary.stale;stale.textContent='⚠';stale.setAttribute('aria-label',t('ci.compact.stale'));stale.title=t('ci.compact.stale')+(summary.updatedAt?' · '+date(summary.updatedAt)?.toLocaleString():'');
 host.dataset.ciIdentity=summary.scopeID+':'+summary.id;
}
export function renderCIProgress(card:HTMLElement,summary:CICompactSummary|null|undefined,t:Translate,visible:boolean){
 let track=card.querySelector<HTMLElement>(':scope > .ci-compact-progress');
 if(!track){track=document.createElement('div');track.className='ci-compact-progress';track.append(document.createElement('div'));card.append(track);}
 track.hidden=!summary||!visible;if(!summary)return;
 const fraction=ciFraction(summary),color=['failed','error'].includes(summary.status)?'#c55c27':summary.status==='success'?'#2b9463':'var(--block-accent)';
 track.firstElementChild!.setAttribute('style',`transform:scaleX(${fraction??0});background:${color}`);
 track.setAttribute('role','progressbar');track.setAttribute('aria-label',t('ci.checks.progress'));track.setAttribute('aria-valuemin','0');track.setAttribute('aria-valuemax','100');
 if(fraction!=null){track.setAttribute('aria-valuenow',String(Math.round(fraction*100)));track.setAttribute('aria-valuetext',Math.round(fraction*100)+'%');}
 else{track.removeAttribute('aria-valuenow');track.setAttribute('aria-valuetext',t('ci.progress.unavailable'));}
}
export function ciActive(summary:CICompactSummary){return active(summary.status);}
