// Created by Василий Маслов on 06.10.2026.
import tokens from '../Sources/MimicCore/Resources/panel-design-tokens.json';
export const dragHoldMS=tokens.metrics.dragHoldMS;
/** Input-only hold state, independent of DOM capture and layout persistence. */
export class HoldGesture {
 phase:'idle'|'waiting'|'dragging'|'cancelled'='idle';
 private origin={x:0,y:0};private deadline=0;
 press(x:number,y:number,time:number,eligible=true){if(!eligible||this.phase!=='idle')return;this.origin={x,y};this.deadline=time+dragHoldMS;this.phase='waiting';}
 move(x:number,y:number){if(this.phase==='waiting'&&Math.hypot(x-this.origin.x,y-this.origin.y)>12)this.phase='cancelled';return this.phase==='dragging';}
 activate(time:number){if(this.phase!=='waiting'||time<this.deadline)return false;this.phase='dragging';return true;}
 release(){const result={drop:this.phase==='dragging',click:this.phase==='waiting'};this.phase='idle';return result;}
}
export function scrollSpeed(y:number,height:number){if(y<48)return -400*Math.min(1,Math.max(0,(48-y)/48));if(y>height-48)return 400*Math.min(1,Math.max(0,(y-height+48)/48));return 0;}

/** Window/viewport coordinates keep document scrolling out of the dwell tolerance. */
export type ResizeZone='left'|'center'|'right';
export function resizeZone(x:number,width:number):ResizeZone|null{if(width<=0||x<0||x>width)return null;return x<=width*.3?'left':x>=width*.7?'right':'center';}
export class DragResize {
 pending:ResizeZone|null=null;progress=0;private anchor={x:0,y:0};private started=0;
 constructor(public size:'full'|'mini',_pointer:{x:number;y:number}){}
 update(zone:ResizeZone|null,pointer:{x:number;y:number},time:number){
  const requested=zone==='center'?'full':'mini';
  if(zone===null||requested===this.size){this.pending=null;this.progress=0;return false;}
  if(zone!==this.pending||Math.hypot(pointer.x-this.anchor.x,pointer.y-this.anchor.y)>50){this.pending=zone;this.anchor={...pointer};this.started=time;this.progress=0;return false;}
  this.progress=Math.min(1,Math.max(0,(time-this.started)/500));
  if(this.progress<1)return false;this.size=requested;this.pending=null;this.progress=0;return true;
 }
}
