// Created by Василий Маслов on 06.10.2026.
/** Input-only hold state, independent of DOM capture and layout persistence. */
export class HoldGesture {
 phase:'idle'|'waiting'|'dragging'|'cancelled'='idle';
 private origin={x:0,y:0};private deadline=0;
 press(x:number,y:number,time:number,eligible=true){if(!eligible||this.phase!=='idle')return;this.origin={x,y};this.deadline=time+350;this.phase='waiting';}
 move(x:number,y:number){if(this.phase==='waiting'&&Math.hypot(x-this.origin.x,y-this.origin.y)>8)this.phase='cancelled';return this.phase==='dragging';}
 activate(time:number){if(this.phase!=='waiting'||time<this.deadline)return false;this.phase='dragging';return true;}
 release(){const result={drop:this.phase==='dragging',click:this.phase==='waiting'};this.phase='idle';return result;}
}
export function scrollSpeed(y:number,height:number){if(y<48)return -400*Math.min(1,Math.max(0,(48-y)/48));if(y>height-48)return 400*Math.min(1,Math.max(0,(y-height+48)/48));return 0;}

/** Same zone boundaries and stationary dwell contract as native PanelDragResize. */
export type ResizeZone='left'|'center'|'right';
export function resizeZone(x:number,width:number):ResizeZone|null{if(width<=0||x<0||x>width)return null;return x<=width*.2?'left':x>=width*.8?'right':'center';}
export class DragResize {
 private last:{x:number;y:number};private moved=false;private pending:ResizeZone|null=null;private anchor={x:0,y:0};private started=0;
 constructor(public size:'full'|'mini',pointer:{x:number;y:number}){this.last={...pointer};}
 update(zone:ResizeZone|null,pointer:{x:number;y:number},time:number){
  if(pointer.x!==this.last.x||pointer.y!==this.last.y)this.moved=true;this.last={...pointer};
  const requested=zone==='center'?'full':'mini';
  if(!this.moved||zone===null||requested===this.size){this.pending=null;return false;}
  if(zone!==this.pending||Math.hypot(pointer.x-this.anchor.x,pointer.y-this.anchor.y)>8){this.pending=zone;this.anchor={...pointer};this.started=time;return false;}
  if(time-this.started<1000)return false;this.size=requested;this.pending=null;return true;
 }
}
