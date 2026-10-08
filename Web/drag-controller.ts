// Created by Василий Маслов on 07.10.2026.
import {change,insert,type Block,type Layout,type InsertionTarget} from './layout';
import {dragHoldMS,HoldGesture,DragResize,resizeZone,scrollSpeed,type ResizeZone} from './drag-gesture';

type Point={x:number;y:number};
type Cell={row:string;slot:number;full:boolean;x:number;y:number;width:number;height:number};
type Session={block:Block;node:HTMLElement;pointer:number;gesture:HoldGesture;origin:Layout;
 x:number;y:number;grab:Point;anchor:Point;editing:boolean;resize:DragResize;
 hold:ReturnType<typeof setTimeout>;frame:number;lastTick:number;target:InsertionTarget|null;
 lastHit:Point|null;valid:boolean;morph:Animation|null};
type Options={grid:HTMLElement;toolbar:HTMLElement;nodes:Map<Block,{node:HTMLElement}>;
 getLayout:()=>Layout;editing:()=>boolean;blocked:()=>boolean;render:()=>void;
 animate:(mutation:()=>void)=>void;commit:(next:Layout,origin:Layout,editing:boolean)=>Promise<void>;
 label:(size:'full'|'mini')=>string};

/** All nested controls share the same exclusion for surface clicks and drag presses. */
export function isBlockControl(target:HTMLElement){
 return !!target.closest('button,input,select,textarea,a,summary,[contenteditable],[role=button],[role=link],.terminal-host,.sim-viewport,.simulator-image,.placement-menu');
}

/** Owns one pointer and one layout transaction. Frames come from layout, never presentation transforms. */
export class CardDragController {
 session:Session|null=null;
 layout:Layout|null=null;
 saving=false;
 private suppressClick=false;
 private readonly guides=document.createElement('div');
 private readonly placeholder=document.createElement('div');
 private readonly status=document.createElement('div');
 private readonly progress=document.createElement('div');
 private readonly caption=document.createElement('span');
 private readonly zones=new Map<ResizeZone,HTMLElement>();

 constructor(private readonly options:Options){
  this.guides.className='drag-guides';this.guides.hidden=true;this.guides.setAttribute('aria-hidden','true');
  for(const zone of ['left','center','right'] as const){const node=document.createElement('div');node.className='drag-zone';node.dataset.zone=zone;this.guides.append(node);this.zones.set(zone,node);}
  this.placeholder.className='drag-placeholder';this.guides.append(this.placeholder);options.grid.append(this.guides);
  this.status.className='drag-status';this.status.hidden=true;this.progress.className='drag-dwell-progress';this.status.append(this.caption,this.progress);document.body.append(this.status);
  // A new physical press always clears stale suppression left by Escape or a cancelled capture.
  window.addEventListener('pointerdown',()=>{this.suppressClick=false;},true);
  window.addEventListener('click',event=>{if(this.suppressClick&&event.detail!==0){this.suppressClick=false;event.preventDefault();event.stopImmediatePropagation();}},true);
  window.addEventListener('pointermove',event=>{
   const s=this.session;if(!s||event.pointerId!==s.pointer)return;
   s.x=event.clientX;s.y=event.clientY;s.gesture.move(s.x,s.y);
   if(s.gesture.phase==='cancelled'){this.suppressClick=true;this.release(s);}
  });
  window.addEventListener('pointerup',event=>{
   const s=this.session;if(!s||event.pointerId!==s.pointer)return;
   s.x=event.clientX;s.y=event.clientY;
   if(s.gesture.phase==='dragging'){
    // Resolve the last pointer position synchronously; dwell itself only advances on live frames.
    this.update(false);void this.finish(s);
   }else this.release(s);
  });
  window.addEventListener('pointercancel',event=>{if(event.pointerId===this.session?.pointer)this.cancel();});
  options.grid.addEventListener('lostpointercapture',event=>{if(event.pointerId===this.session?.pointer)this.cancel();});
  window.addEventListener('blur',()=>this.cancel());window.addEventListener('pagehide',()=>this.cancel());
  document.addEventListener('visibilitychange',()=>{if(document.hidden)this.cancel();});
 }

 start(event:PointerEvent,block:Block){
  const hit=event.target as HTMLElement;
  if(event.button!==0||this.session||this.saving||this.options.blocked()||
   (!hit.closest('.block-title,.drag-handle')&&isBlockControl(hit))||!this.options.getLayout().rows.some(r=>r.slots.includes(block)))return;
  const node=this.options.nodes.get(block)!.node,rect=this.box(node),now=performance.now(),gesture=new HoldGesture();
  gesture.press(event.clientX,event.clientY,now);
  const s:Session={block,node,pointer:event.pointerId,gesture,origin:structuredClone(this.options.getLayout()),
   x:event.clientX,y:event.clientY,grab:{x:event.clientX-rect.x,y:event.clientY-rect.y},anchor:{x:0,y:0},
   editing:this.options.editing(),resize:new DragResize(this.options.getLayout().rows.find(r=>r.slots.includes(block))!.slots.length===1?'full':'mini',{x:event.clientX,y:event.clientY}),
   hold:setTimeout(()=>this.activate(s),dragHoldMS),frame:0,lastTick:now,target:null,lastHit:null,valid:false,morph:null};
  this.session=s;this.options.toolbar.inert=true;
 }

 cancel(){
  const s=this.session;if(!s)return;
  if(s.gesture.phase==='dragging'){this.suppressClick=true;this.settle(s,()=>{});}else this.release(s);
 }

 private box(node:HTMLElement){const grid=this.options.grid.getBoundingClientRect();return{x:grid.x+node.offsetLeft,y:grid.y+node.offsetTop,width:node.offsetWidth,height:node.offsetHeight};}
 private cells():Cell[]{
  const layout=this.layout!;
  return layout.rows.flatMap(row=>row.slots.flatMap((block,slot)=>{
   const node=block?this.options.nodes.get(block)?.node:this.options.grid.querySelector<HTMLElement>(`.empty-slot[data-row="${row.id}"][data-slot="${slot}"]`);
   if(!node||node.hidden)return[];
   return[{row:row.id,slot,full:row.slots.length===1,x:node.offsetLeft,y:node.offsetTop,width:node.offsetWidth,height:node.offsetHeight}];
  }));
 }
 private activate(s:Session){
  if(this.session!==s)return;
  if(!s.gesture.activate(performance.now())){if(s.gesture.phase==='waiting')s.hold=setTimeout(()=>this.activate(s),1);return;}
  this.suppressClick=true;this.layout=structuredClone(s.origin);s.node.classList.add('dragging');s.node.dataset.dragActive='true';
  this.options.render();const rect=this.box(s.node);
  s.grab={x:Math.max(0,Math.min(s.grab.x,rect.width)),y:Math.max(0,Math.min(s.grab.y,rect.height-16))};
  s.anchor={x:s.grab.x/rect.width,y:s.grab.y/rect.height};
  try{this.options.grid.setPointerCapture(s.pointer);}catch{this.cancel();return;}
  this.guides.hidden=false;this.status.hidden=false;this.update();s.lastTick=performance.now();
  s.frame=requestAnimationFrame(time=>this.tick(time));
 }
 private moveSource(s:Session){
  const rect=this.box(s.node);s.grab={x:s.anchor.x*rect.width,y:s.anchor.y*rect.height};
  s.node.style.transformOrigin=`${s.grab.x}px ${s.grab.y}px`;
  s.node.style.translate=`${s.x-s.grab.x-rect.x}px ${s.y-s.grab.y-rect.y}px`;
 }
 private morph(s:Session,before:DOMRect){
  s.morph?.cancel();s.morph=null;
  if(matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  const rect=s.node.getBoundingClientRect();if(Math.abs(before.width-rect.width)+Math.abs(before.height-rect.height)<1)return;
  const style=getComputedStyle(s.node);
  s.morph=s.node.animate([{transform:`scale(${before.width/Math.max(1,rect.width)},${before.height/Math.max(1,rect.height)})`},{transform:'scale(1,1)'}],
   {duration:parseFloat(style.getPropertyValue('--motion-geometry')),easing:style.getPropertyValue('--motion-geometry-ease').trim()});
 }

 private resolve(s:Session,cells:Cell[],point:Point,resized:boolean):InsertionTarget|null{
  const source=this.layout!.rows.find(r=>r.slots.includes(s.block))!;
  const own=cells.find(c=>c.row===source.id&&c.slot===source.slots.indexOf(s.block));
  // A placeholder has ownership until the pointer leaves its 12pt margin. Reflow alone cannot retarget it.
  if(own&&point.x>=own.x-12&&point.x<=own.x+own.width+12&&point.y>=own.y-12&&point.y<=own.y+own.height+12){
   if(resized||s.target===null)return s.resize.size==='mini'?{row:source.id,slot:resized?(point.x<this.options.grid.clientWidth/2?0:1):source.slots.indexOf(s.block)}:{before:source.id};
   const id='slot'in s.target?s.target.row:s.target.before;
   if(!id||this.layout!.rows.some(r=>r.id===id))return s.target;
   return s.resize.size==='mini'?{row:source.id,slot:source.slots.indexOf(s.block)}:{before:source.id};
  }
  const last=cells.reduce<Cell|undefined>((a,c)=>!a||c.y+c.height>a.y+a.height?c:a,undefined);
  if(!last)return null;if(point.y>last.y+last.height)return{};
  const cell=cells.find(c=>point.x>=c.x-6&&point.x<=c.x+c.width+6&&point.y>=c.y-6&&point.y<=c.y+c.height+6);
  if(!cell)return null;
  if(s.resize.size==='mini'&&!cell.full)return{row:cell.row,slot:cell.slot};
  const index=this.layout!.rows.findIndex(r=>r.id===cell.row);
  return{before:point.y<cell.y+cell.height/2?cell.row:this.layout!.rows[index+1]?.id};
 }

 private update(advanceDwell=true){
  const s=this.session;if(!s||s.gesture.phase!=='dragging')return;
  const grid=this.options.grid.getBoundingClientRect(),point={x:s.x-grid.x,y:s.y-grid.y},cells=this.cells();
  const bottom=Math.max(0,...cells.map(c=>c.y+c.height));
  const hit=document.elementFromPoint(s.x,s.y);
  const valid=s.x>=0&&s.x<=innerWidth&&s.y>=0&&s.y<=innerHeight&&point.x>=0&&point.x<=grid.width&&point.y>=0&&point.y<=bottom+32&&
   !hit?.closest('.context-bar,.panel-toolbar,header,.block-catalog');
  const zone=valid?resizeZone(point.x,grid.width):null;
  const resized=advanceDwell?s.resize.update(zone,{x:s.x,y:s.y},performance.now()):false;
  const moved=!s.lastHit||point.x!==s.lastHit.x||point.y!==s.lastHit.y;
  s.valid=valid;
  if(valid&&(moved||resized||s.target===null)){
   const target=this.resolve(s,cells,point,resized);
   if(target){
    const before=s.node.getBoundingClientRect();
    try{
     // Targets belong to the current preview, including rows created by an earlier size change.
     let next=change(this.layout!,l=>insert(l,s.block,target,s.resize.size,zone==='right'?1:0));
     if(JSON.stringify(next.rows.map(r=>r.slots))===JSON.stringify(s.origin.rows.map(r=>r.slots)))next=structuredClone(s.origin);
     s.target=target;
     if(JSON.stringify(next.rows)!==JSON.stringify(this.layout!.rows)){
      this.options.animate(()=>{this.layout=next;this.options.render();});this.moveSource(s);if(resized)this.morph(s,before);
     }
    }catch{s.valid=false;}
   }else s.valid=false;
  }
  s.lastHit=point;this.moveSource(s);this.feedback(s,zone);
 }
 private feedback(s:Session,zone:ResizeZone|null){
  const source=this.layout!.rows.find(r=>r.slots.includes(s.block))!;
  const cell=this.cells().find(c=>c.row===source.id&&c.slot===source.slots.indexOf(s.block));
  this.placeholder.hidden=!s.valid||!cell;
  if(cell)Object.assign(this.placeholder.style,{left:`${cell.x}px`,top:`${cell.y}px`,width:`${cell.width}px`,height:`${cell.height}px`});
  for(const [kind,node]of this.zones)node.classList.toggle('active',s.valid&&kind===zone);
  this.status.hidden=!s.valid;this.caption.textContent=this.options.label(s.resize.pending==='center'?'full':s.resize.pending?'mini':s.resize.size);
  this.status.dataset.pending=s.resize.pending??'';this.status.dataset.size=s.resize.size;
  this.progress.style.transform=`scaleX(${s.resize.progress})`;
  this.status.style.transform=`translate(${Math.max(4,Math.min(innerWidth-140,s.x+16))}px,${Math.max(4,Math.min(innerHeight-44,s.y+20))}px)`;
 }
 private tick(time:number){
  const s=this.session;if(!s||s.gesture.phase!=='dragging')return;
  const elapsed=Math.min(.05,(time-s.lastTick)/1000);s.lastTick=time;
  const scroller=document.scrollingElement as HTMLElement|null;
  if(scroller)scroller.scrollTop+=scrollSpeed(s.y,innerHeight)*elapsed;
  this.update();s.frame=requestAnimationFrame(next=>this.tick(next));
 }
 private release(s:Session){
  clearTimeout(s.hold);cancelAnimationFrame(s.frame);s.morph?.cancel();s.morph=null;this.session=null;
  if(this.options.grid.hasPointerCapture(s.pointer))this.options.grid.releasePointerCapture(s.pointer);
  s.node.classList.remove('dragging');delete s.node.dataset.dragActive;this.guides.hidden=true;this.status.hidden=true;
  this.options.toolbar.inert=this.saving;
 }
 private settle(s:Session,mutation:()=>void){
  this.options.animate(()=>{this.release(s);s.node.style.translate='';s.node.style.transformOrigin='';this.layout=null;mutation();this.options.render();});
 }
 private async finish(s:Session){
  const next=this.layout!;
  // Row UUIDs created during preview are not a user-visible change when the slots return to their origin.
  const changed=JSON.stringify(next.rows.map(r=>r.slots))!==JSON.stringify(s.origin.rows.map(r=>r.slots));
  if(!s.valid||!s.target||!changed){this.settle(s,()=>{});return;}
  this.saving=true;
  // Keep the optimistic preview visible until commit owns it, then remove the drag presentation.
  this.settle(s,()=>{this.layout=next;});
  try{await this.options.commit(next,s.origin,s.editing);}
  finally{this.layout=null;this.saving=false;this.options.toolbar.inert=false;this.options.render();}
 }
}
