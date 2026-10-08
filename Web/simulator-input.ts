//
//  simulator-input.ts
//  MimicPanel
//
//  Created by Василий Маслов on 08.10.2026.
export type TouchAccess={sessionID:string;generation:string;width:number;height:number;orientation:string};
type Point={x:number;y:number;timestamp:number};
type Phase='down'|'move'|'up'|'cancel'|'heartbeat';
type Call=(operation:string,args:Record<string,unknown>)=>Promise<any>;
type Contact={id:string;sequence:number;point:Point;latest:Point|null;ending:'up'|'cancel'|null;wheel:boolean;dx:number;dy:number};

/** One in-flight event, one replaceable movement and one terminal event. Up is
 * ordered after the latest move; a failed send retires the session without replay. */
export class SimulatorContinuousInput {
 private access:TouchAccess|null=null;
 private contact:Contact|null=null;
 private pending:Promise<void>|null=null;
 private raf=0;
 private heartbeat:ReturnType<typeof setInterval>|null=null;
 private wheelEnd:ReturnType<typeof setTimeout>|null=null;
 private generation=0;
 private failed=false;
 private cancelling:Promise<void>|null=null;
 constructor(private viewerID:string,private call:Call,private changed:(error?:unknown)=>void,private ended:()=>void){}
 get active(){return this.contact!==null||this.pending!==null||this.cancelling!==null;}
 matches(sessionID:string,width:number,height:number,orientation:string){return this.access?.sessionID===sessionID&&this.access.width===width&&this.access.height===height&&this.access.orientation===orientation;}
 get ready(){return !!this.access&&!this.failed&&!this.cancelling;}
 async prepare(){
  await this.cancelling;
  const generation=++this.generation;this.access=null;this.failed=false;
  const access=await this.call('simulator_ui_input',{viewerID:this.viewerID}) as TouchAccess;
  if(generation!==this.generation)return;
  if(!access?.sessionID||!access.generation||!(access.width>0)||!(access.height>0))throw new Error('invalidResponse');
  this.access=access;this.changed();
 }
 down(point:Point,wheel=false){
  if(!this.ready||this.active)return false;
  this.contact={id:crypto.randomUUID(),sequence:0,point,latest:null,ending:null,wheel,dx:0,dy:0};
  this.heartbeat=setInterval(()=>{if(this.contact&&!this.pending&&!this.contact.latest&&!this.contact.ending)void this.send('heartbeat',this.contact.point);},300);
  void this.send('down',point);this.changed();return true;
 }
 move(point:Point){if(!this.contact||this.contact.ending)return;this.contact.latest=point;this.schedule();}
 up(point:Point){if(!this.contact||this.contact.ending)return;this.contact.latest=point;this.contact.ending='up';this.schedule();}
 /** Preserve signed wheel deltas through RAF coalescing. Replacing the target
  * with the original cursor on each event would erase accumulated scrolling. */
 wheel(point:Point,dx:number,dy:number){
  if(!this.contact&&!this.down(point,true))return;
  const c=this.contact;if(!c||!c.wheel||c.ending)return;
  const a=this.access!;c.dx=Math.max(-a.width,Math.min(a.width,c.dx+dx));c.dy=Math.max(-a.height,Math.min(a.height,c.dy+dy));
  c.point.timestamp=point.timestamp;this.schedule();
  if(this.wheelEnd)clearTimeout(this.wheelEnd);
  this.wheelEnd=setTimeout(()=>{this.wheelEnd=null;if(this.contact?.wheel){this.contact.ending='up';this.schedule();}},120);
 }
 private schedule(){if(!this.raf)this.raf=requestAnimationFrame(()=>{this.raf=0;this.pump();});}
 private pump(){
  const c=this.contact;if(!c||this.pending||!this.access||this.cancelling)return;
  if(c.wheel&&(Math.abs(c.dx)>.01||Math.abs(c.dy)>.01)){
   const a=this.access,dx=Math.max(-a.width*.2,Math.min(a.width*.2,c.dx)),dy=Math.max(-a.height*.2,Math.min(a.height*.2,c.dy));c.dx-=dx;c.dy-=dy;
   c.latest={x:Math.max(.001,Math.min(a.width-.001,c.point.x-dx)),y:Math.max(.001,Math.min(a.height-.001,c.point.y-dy)),timestamp:c.point.timestamp};
  }
  if(c.latest){const point=c.latest;c.latest=null;void this.send('move',point);}
  else if(c.ending)void this.send(c.ending,c.point);
 }
 private async send(phase:Phase,point:Point){
  const c=this.contact,a=this.access,generation=this.generation;if(!c||!a||this.pending||this.failed)return;
  const event={...a,gestureID:c.id,sequence:++c.sequence,phase,...point};
  // Geometry is granted separately; only the event contract crosses this route.
  const {width:_width,height:_height,orientation:_orientation,...payload}=event;
  const sending=this.call('simulator_ui_input_event',{viewerID:this.viewerID,event:payload}).then(reply=>{
   if(!reply?.accepted||reply.sequence!==payload.sequence)throw new Error('invalidResponse');
   if(this.contact===c)c.point=point;
  });
  this.pending=sending;
  try{await sending;}
  catch(error){
   if(generation===this.generation){this.failed=true;this.access=null;this.contact=null;this.clearTimers();this.changed(error);void this.cancel().catch(()=>{});}
  }finally{
   if(this.pending===sending)this.pending=null;
   if(generation===this.generation&&this.contact===c){
    if(phase==='up'||phase==='cancel'){this.contact=null;this.clearTimers();this.changed();this.ended();}
    else if(c.latest||c.ending||c.dx||c.dy)this.schedule();
   }
  }
 }
 private clearTimers(){if(this.raf)cancelAnimationFrame(this.raf);this.raf=0;if(this.heartbeat)clearInterval(this.heartbeat);this.heartbeat=null;if(this.wheelEnd)clearTimeout(this.wheelEnd);this.wheelEnd=null;}
 /** The cancellation endpoint closes the helper, including an uncertain event.
  * Wait for confirmation before admitting a new source or gesture. */
 cancel():Promise<void>{
  if(this.cancelling)return this.cancelling;
  ++this.generation;this.access=null;this.contact=null;this.clearTimers();
  const previous=this.pending;
  const cancellation=(async()=>{try{await previous;}catch{}await this.call('simulator_ui_input_cancel',{viewerID:this.viewerID});})();
  this.cancelling=cancellation;
  void cancellation.finally(()=>{if(this.cancelling===cancellation)this.cancelling=null;this.changed();}).catch(()=>{});
  return cancellation;
 }
}
