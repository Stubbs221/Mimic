// Created by Василий Маслов on 27.10.2026.
type Translate=(key:string)=>string;
type Tool=(name:string,args:Record<string,unknown>)=>Promise<any>;
let pickerID=0;

/** Remote search and launch selection are separate; late replies never select another query. */
export function remoteBranchPicker(host:HTMLElement,initial:string,tool:Tool,t:Translate,select:(branch:string)=>void){
 const trigger=document.createElement('button');trigger.type='button';trigger.className='ci-branch-trigger';
 const popup=document.createElement('div');popup.className='ci-branch-popover';popup.popover='auto';popup.id='ci-branch-'+(++pickerID);popup.setAttribute('role','dialog');popup.setAttribute('aria-label',t('ci.launch.branch'));
 const search=document.createElement('input');search.type='search';search.placeholder=t('ci.launch.search');search.setAttribute('aria-label',t('ci.launch.search'));
 const message=document.createElement('p'),list=document.createElement('div');list.className='ci-branch-results';popup.append(search,message,list);host.append(trigger,popup);
 trigger.setAttribute('aria-controls',popup.id);trigger.setAttribute('aria-expanded','false');
 let chosen='',revision=0,timer:ReturnType<typeof setTimeout>|undefined;
 const label=()=>{trigger.textContent=(chosen||t('ci.launch.branch'))+' ⌄';trigger.title=chosen;};label();
 const close=()=>{popup.hidePopover();trigger.focus({preventScroll:true});};
 const choose=(branch:string)=>{chosen=branch;label();select(branch);close();};
 async function load(query:string,restore=false){
  const current=++revision;message.textContent=t('ci.loading');list.replaceChildren();
  try{
   const result=await tool('list_remote_branches',{query});if(current!==revision)return;
   const branches=(result.branches as unknown[]).filter((value):value is string=>typeof value==='string');
   if(restore&&initial&&branches.includes(initial)){chosen=initial;label();select(initial);}
   message.textContent=branches.length?'':t('ci.launch.noBranches');
   for(const branch of branches){const row=document.createElement('button');row.type='button';row.className='ci-branch-option';row.textContent=branch;row.title=branch;row.setAttribute('aria-pressed',String(branch===chosen));row.onclick=()=>choose(branch);row.onkeydown=event=>{if(!['ArrowDown','ArrowUp','Home','End'].includes(event.key))return;event.preventDefault();const rows=Array.from(list.querySelectorAll('button')),index=rows.indexOf(row);rows[event.key==='Home'?0:event.key==='End'?rows.length-1:Math.max(0,Math.min(rows.length-1,index+(event.key==='ArrowDown'?1:-1)))]?.focus();};list.append(row);}
  }catch(error){if(current===revision)message.textContent=error instanceof Error?error.message:t('ci.error.network');}
 }
 trigger.onclick=()=>{
  if(popup.matches(':popover-open')){close();return;}
  const bounds=trigger.getBoundingClientRect();popup.style.left=Math.max(16,Math.min(bounds.left,innerWidth-376))+'px';popup.style.top=Math.max(16,Math.min(bounds.bottom+6,innerHeight-300))+'px';
  popup.showPopover();search.value='';search.focus();void load('');
 };
 popup.addEventListener('toggle',()=>trigger.setAttribute('aria-expanded',String(popup.matches(':popover-open'))));
 popup.onkeydown=event=>{if(event.key==='Escape'){event.stopPropagation();event.preventDefault();close();}};
 search.oninput=()=>{revision++;clearTimeout(timer);timer=setTimeout(()=>void load(search.value),250);};
 search.onkeydown=event=>{if(event.key==='ArrowDown'){event.preventDefault();list.querySelector('button')?.focus();}};
 // Run after the form has registered its controls and validity callback.
 queueMicrotask(()=>{select('');void load(initial,true);});
 return trigger;
}
