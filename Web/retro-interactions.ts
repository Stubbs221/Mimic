import tokens from './themes/tokens.json';
// Created by Василий Маслов on 12.10.2026.
/** R1 timings are Mimic parameters, not measurements of an original Windows installation. */
const enabled=()=>document.documentElement.dataset.retro==='true';
const reduced=()=>matchMedia('(prefers-reduced-motion: reduce)').matches;
let keyboard=false;
let press:{button:HTMLButtonElement;pointer:number|null;armed:boolean}|null=null;
let suppressClick=false;
let tooltipTimer:ReturnType<typeof setTimeout>|undefined;
let tooltip:HTMLElement|null=null;
let tooltipTarget:HTMLElement|null=null;
const cancellers=new Set<()=>void>();

/** State feedback never delays activation; incomplete fades are disposable decoration. */
export function fadePopup(host:HTMLElement){
 host.getAnimations().forEach(a=>a.cancel());
 if(document.documentElement.dataset.appearance==='windowsXP'&&!keyboard&&!reduced())host.animate([{opacity:0},{opacity:1}],{duration:tokens.windowsXP.menuEnterMs,easing:'linear'});
}

function hideTooltip(){clearTimeout(tooltipTimer);tooltipTimer=undefined;tooltip?.getAnimations().forEach(a=>a.cancel());if(tooltip)tooltip.hidden=true;tooltipTarget=null;}
function releasePress(){
 const old=press;press=null;if(!old)return;
 old.button.removeAttribute('data-pressed');
 if(old.pointer!==null&&old.button.hasPointerCapture(old.pointer))old.button.releasePointerCapture(old.pointer);
}
export function cancelRetroInteractions(){suppressClick=!!press||suppressClick;releasePress();hideTooltip();for(const cancel of cancellers)cancel();document.querySelectorAll('.chrome-popover,.retro-select-popup').forEach(n=>n.getAnimations().forEach(a=>a.cancel()));}

export function installRetroInteractions(){
 document.addEventListener('pointerdown',event=>{
  keyboard=false;suppressClick=false;hideTooltip();if(!enabled()||event.button!==0)return;
  const button=(event.target as HTMLElement).closest<HTMLButtonElement>('button');
  if(!button||button.disabled||button.closest('.xterm')||button.classList.contains('block-title')||button.classList.contains('drag-handle'))return;
  button.focus({preventScroll:true});press={button,pointer:event.pointerId,armed:true};button.dataset.pressed='true';
  try{button.setPointerCapture(event.pointerId);}catch{releasePress();}
 },true);
 document.addEventListener('pointermove',event=>{if(!press||press.pointer!==event.pointerId)return;const rect=press.button.getBoundingClientRect();press.armed=event.clientX>=rect.left&&event.clientX<rect.right&&event.clientY>=rect.top&&event.clientY<rect.bottom&&!press.button.disabled;press.button.toggleAttribute('data-pressed',press.armed);},true);
 document.addEventListener('pointerup',event=>{if(!press||press.pointer!==event.pointerId)return;const {button,armed}=press;const rect=button.getBoundingClientRect();const activate=armed&&!button.disabled&&event.clientX>=rect.left&&event.clientX<rect.right&&event.clientY>=rect.top&&event.clientY<rect.bottom;releasePress();suppressClick=true;event.preventDefault();if(activate)button.click();},true);
 document.addEventListener('click',event=>{if(suppressClick&&event.detail!==0){suppressClick=false;event.preventDefault();event.stopImmediatePropagation();}},true);
 document.addEventListener('keydown',event=>{
  keyboard=true;if(event.key==='Escape'){cancelRetroInteractions();return;}if(!enabled())return;
  const button=event.target instanceof HTMLButtonElement?event.target:null;
  if(event.key===' '&&button&&!button.disabled){event.preventDefault();if(!event.repeat&&!press){hideTooltip();press={button,pointer:null,armed:true};button.dataset.pressed='true';}}
  if(event.key==='Enter'&&button&&!button.disabled){event.preventDefault();hideTooltip();button.click();}
  const tab=(event.target as HTMLElement).closest<HTMLElement>('[role=tab]');
  if(tab&&['ArrowLeft','ArrowRight','Home','End'].includes(event.key)){const tabs=Array.from(tab.parentElement!.querySelectorAll<HTMLButtonElement>('[role=tab]:not(:disabled)')),index=tabs.indexOf(tab as HTMLButtonElement);if(index>=0){event.preventDefault();const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowLeft'?-1:1)+tabs.length)%tabs.length;tabs.forEach((n,i)=>n.tabIndex=i===next?0:-1);tabs[next].focus();tabs[next].click();}}
 },true);
 document.addEventListener('keyup',event=>{if(event.key!==' '||press?.pointer!==null)return;event.preventDefault();const {button}=press,activate=document.activeElement===button&&!button.disabled;releasePress();if(activate)button.click();},true);
 document.addEventListener('focusout',()=>{if(press?.pointer===null)releasePress();hideTooltip();},true);
 document.addEventListener('pointercancel',cancelRetroInteractions,true);
 document.addEventListener('lostpointercapture',event=>{if(press?.pointer===event.pointerId)cancelRetroInteractions();},true);
 window.addEventListener('blur',cancelRetroInteractions);window.addEventListener('pagehide',cancelRetroInteractions);
 document.addEventListener('visibilitychange',()=>{if(document.hidden)cancelRetroInteractions();});
 matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change',cancelRetroInteractions);
 const rails=new Map<HTMLElement,RetroScrollbar>();
 const discover=()=>{
  if(!enabled()){for(const rail of rails.values())rail.update();return;}
  document.querySelectorAll<HTMLElement>('.list,.build-test-list,.ci-details-jobs,.sim-choices,.sim-menu-list,textarea').forEach(scroller=>{
   if(scroller.closest('.xterm')||rails.has(scroller))return;
   const wrapper=document.createElement('div');wrapper.className='retro-scroll-container';scroller.parentNode!.insertBefore(wrapper,scroller);wrapper.append(scroller);scroller.classList.add('retro-native-scroll');
   const rail=new RetroScrollbar(scroller);rails.set(scroller,rail);wrapper.append(rail.rail);rail.update();
  });
  for(const [node,rail]of rails){if(node.isConnected)rail.update();else{rail.dispose();rails.delete(node);}}
 };
 new MutationObserver(()=>{if(press?.button.disabled)releasePress();discover();}).observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['disabled']});
 new MutationObserver(discover).observe(document.documentElement,{attributes:true,attributeFilter:['data-appearance']});
 installRetroSelects();

 // Keep DOM controls and native editing, replacing only browser tooltip presentation in retro themes.
 const titles=new WeakMap<HTMLElement,string>();
 const remember=(node:HTMLElement)=>{if(node.title){titles.set(node,node.title);node.dataset.retroTooltip=node.title;if(enabled())node.removeAttribute('title');}};
 const schedule=(node:HTMLElement)=>{
  if(!enabled()||node.closest('.xterm')||('disabled'in node&&node.disabled))return;
  remember(node);const text=node.dataset.retroTooltip??titles.get(node);if(!text)return;hideTooltip();tooltipTarget=node;
  tooltipTimer=setTimeout(()=>{if(tooltipTarget!==node||!node.isConnected||document.hidden||!enabled())return;if(!tooltip){tooltip=document.createElement('div');tooltip.className='retro-tooltip';tooltip.setAttribute('role','tooltip');tooltip.id='mimic-retro-tooltip';document.body.append(tooltip);}tooltip.textContent=text;tooltip.hidden=false;const rect=node.getBoundingClientRect();tooltip.style.left=Math.max(4,Math.min(innerWidth-tooltip.offsetWidth-4,rect.left))+'px';tooltip.style.top=Math.min(innerHeight-tooltip.offsetHeight-4,rect.bottom+4)+'px';fadePopup(tooltip);},tokens.windows95.tooltipDelayMs);
 };
 document.addEventListener('pointerover',event=>{const node=(event.target as HTMLElement).closest<HTMLElement>('[title],[data-retro-tooltip]');if(node&&!node.contains(event.relatedTarget as Node))schedule(node);});
 document.addEventListener('pointerout',event=>{if(tooltipTarget&&!tooltipTarget.contains(event.relatedTarget as Node))hideTooltip();});
 document.addEventListener('focusin',event=>{if(event.target instanceof HTMLElement)schedule(event.target);});
 new MutationObserver(records=>{for(const record of records){if(record.type==='attributes'&&record.target instanceof HTMLElement)remember(record.target);else for(const node of Array.from(record.addedNodes))if(node instanceof HTMLElement){remember(node);node.querySelectorAll<HTMLElement>('[title]').forEach(remember);}}}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['title']});
}

/** A native overflow container owns scrolling; the rail observes its real metrics and never handles wheel. */
export class RetroScrollbar {
 readonly rail=document.createElement('div');
 private thumb=document.createElement('div');
 private track=document.createElement('div');
 private timer:ReturnType<typeof setTimeout>|undefined;
 private readonly cancelled=()=>this.cancel();
 private readonly observer:ResizeObserver;
 private readonly mutation:MutationObserver;
 private activePointer:number|null=null;
 private grab=0;
 private start=0;
 private maximum=0;
 private travel=0;
 constructor(private scroller:HTMLElement){
  this.rail.className='retro-scrollbar';this.rail.setAttribute('aria-hidden','true');
  const up=document.createElement('button'),down=document.createElement('button');up.type=down.type='button';up.tabIndex=down.tabIndex=-1;up.className='retro-scroll-up';down.className='retro-scroll-down';
  this.track.className='retro-scroll-track';this.thumb.className='retro-scroll-thumb';this.track.append(this.thumb);this.rail.append(up,this.track,down);
  const step=(direction:number,page=false)=>{const line=parseFloat(getComputedStyle(scroller).lineHeight)||14;const before=scroller.scrollTop;scroller.scrollTop+=direction*(page?scroller.clientHeight:line);return before!==scroller.scrollTop;};
  const repeat=(event:PointerEvent,direction:number,page=false)=>{
   if(event.button!==0||!enabled())return;this.cancel();this.activePointer=event.pointerId;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);event.preventDefault();
   const tick=()=>{if(this.activePointer!==event.pointerId)return;if(page){const rect=this.thumb.getBoundingClientRect();if(direction<0?event.clientY>=rect.top:event.clientY<=rect.bottom){this.cancel();return;}}if(step(direction,page))this.timer=setTimeout(tick,tokens.shared.repeatIntervalMs);else this.cancel();};
   if(step(direction,page))this.timer=setTimeout(tick,tokens.shared.repeatDelayMs);
  };
  up.onpointerdown=e=>repeat(e,-1);down.onpointerdown=e=>repeat(e,1);
  this.track.onpointerdown=e=>{if(e.target===this.track)repeat(e,e.clientY<this.thumb.getBoundingClientRect().top?-1:1,true);};
  this.thumb.onpointerdown=e=>{if(e.button!==0)return;this.cancel();this.activePointer=e.pointerId;this.grab=e.clientY;this.start=scroller.scrollTop;this.thumb.setPointerCapture(e.pointerId);e.preventDefault();e.stopPropagation();};
  this.thumb.onpointermove=e=>{if(this.activePointer===e.pointerId)scroller.scrollTop=this.start+(e.clientY-this.grab)*this.maximum/Math.max(1,this.travel);};
  this.rail.onpointerup=this.rail.onpointercancel=()=>this.cancel();this.rail.addEventListener('lostpointercapture',()=>this.cancel());
  scroller.addEventListener('scroll',()=>this.update(),{passive:true});this.observer=new ResizeObserver(()=>this.update());this.observer.observe(scroller);this.mutation=new MutationObserver(()=>this.update());this.mutation.observe(scroller,{subtree:true,childList:true,characterData:true});
  cancellers.add(this.cancelled);
 }
 update(){
  this.rail.hidden=!enabled()||this.scroller.scrollHeight<=this.scroller.clientHeight;
  const height=this.track.clientHeight,length=Math.min(height,Math.max(17,height*this.scroller.clientHeight/Math.max(1,this.scroller.scrollHeight)));
  this.maximum=Math.max(0,this.scroller.scrollHeight-this.scroller.clientHeight);this.travel=Math.max(0,height-length);
  this.thumb.style.height=length+'px';this.thumb.style.transform=`translateY(${this.maximum?this.scroller.scrollTop/this.maximum*this.travel:0}px)`;
 }
 dispose(){this.cancel();this.observer.disconnect();this.mutation.disconnect();cancellers.delete(this.cancelled);}
 private cancel(){clearTimeout(this.timer);this.timer=undefined;const pointer=this.activePointer;this.activePointer=null;for(const node of [this.thumb,this.track,...Array.from(this.rail.querySelectorAll('button'))])if(node instanceof HTMLElement&&node.hasPointerCapture?.(pointer??-1)){try{node.releasePointerCapture(pointer??-1);}catch{}}}
}

/** The original select remains the value, focus and change-event owner across appearance changes. */
function installRetroSelects(){
 let source:HTMLSelectElement|null=null,index=0;
 const popup=document.createElement('div');popup.className='retro-select-popup';popup.hidden=true;popup.setAttribute('role','listbox');popup.id='mimic-retro-options';document.body.append(popup);
 const close=(focus=false)=>{popup.getAnimations().forEach(a=>a.cancel());popup.hidden=true;const old=source;source=null;old?.removeAttribute('aria-expanded');if(focus)old?.focus({preventScroll:true});};
 const render=()=>{if(!source)return;popup.replaceChildren();Array.from(source.options).forEach((option,i)=>{const row=document.createElement('div');row.className='retro-select-option';row.textContent=option.text;row.setAttribute('role','option');row.setAttribute('aria-selected',String(i===index));row.setAttribute('aria-disabled',String(option.disabled));row.onpointerdown=event=>event.preventDefault();row.onclick=()=>{index=i;choose();};popup.append(row);});popup.children[index]?.scrollIntoView({block:'nearest'});};
 const choose=()=>{if(!source||source.options[index]?.disabled)return;const old=source;old.selectedIndex=index;close(true);old.dispatchEvent(new Event('change',{bubbles:true}));};
 const open=(select:HTMLSelectElement)=>{close();source=select;index=select.selectedIndex;select.focus({preventScroll:true});select.setAttribute('aria-controls',popup.id);select.setAttribute('aria-expanded','true');const rect=select.getBoundingClientRect();popup.style.left=rect.left+'px';popup.style.width=rect.width+'px';popup.style.maxHeight=Math.max(60,Math.min(260,innerHeight-rect.bottom-8))+'px';popup.style.top=rect.bottom+'px';popup.hidden=false;render();fadePopup(popup);};
 const move=(direction:number)=>{if(!source)return;const options=source.options;for(let n=0;n<options.length;n++){index=(index+direction+options.length)%options.length;if(!options[index].disabled)break;}render();};
 document.addEventListener('pointerdown',event=>{if(!enabled())return;if(event.target instanceof HTMLSelectElement&&!event.target.disabled&&event.target.size<=1&&!event.target.multiple){event.preventDefault();event.stopImmediatePropagation();if(source===event.target)close(true);else open(event.target);}else if(source&&!popup.contains(event.target as Node))close();},true);
 document.addEventListener('keydown',event=>{
  if(!enabled())return;
  if(source){if(['ArrowDown','ArrowUp','Home','End','Enter',' ','Escape','Tab'].includes(event.key)){if(event.key!=='Tab'){event.preventDefault();event.stopImmediatePropagation();}if(event.key==='ArrowDown'||event.key==='ArrowUp')move(event.key==='ArrowDown'?1:-1);else if(event.key==='Home'||event.key==='End'){index=event.key==='Home'?0:source.options.length-1;render();}else if(event.key==='Enter'||event.key===' ')choose();else close(event.key==='Escape');}return;}
  if(event.target instanceof HTMLSelectElement&&!event.target.disabled&&event.target.size<=1&&!event.target.multiple&&[' ','F4','ArrowDown','ArrowUp'].includes(event.key)){event.preventDefault();event.stopImmediatePropagation();open(event.target);}
 },true);
 cancellers.add(()=>close());
 new MutationObserver(()=>{if(source&&(!source.isConnected||source.disabled))close();}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['disabled']});
}
