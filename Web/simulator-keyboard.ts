//
//  simulator-keyboard.ts
//  MimicPanel
//
//  Created by Василий Маслов on 13.10.2026.
export type KeyboardAction={type:'text';text:string}|{type:'key';key:string};
type Item={action:KeyboardAction;bytes:number};

/** Committed text and keys share one bounded, ordered stream. Only unsent
 * adjacent text is merged; an uncertain operation is never replayed. */
export class SimulatorKeyboardInput {
 private items:Item[]=[];
 private bytes=0;
 private running=false;
 private generation=0;
 private encoder=new TextEncoder();
 constructor(private send:(action:KeyboardAction)=>Promise<boolean>,private idle:()=>void){}
 get active(){return this.running||this.items.length>0;}
 text(value:string){
  const bytes=this.encoder.encode(value).length;
  if(!value)return true;
  if(this.bytes+bytes>1_048_576||this.items.length>=1024)return false;
  const tail=this.items.at(-1);
  if(tail?.action.type==='text'){tail.action.text+=value;tail.bytes+=bytes;}
  else this.items.push({action:{type:'text',text:value},bytes});
  this.bytes+=bytes;void this.drain();return true;
 }
 key(key:string){if(this.items.length>=1024)return false;this.items.push({action:{type:'key',key},bytes:0});void this.drain();return true;}
 reset(){this.generation++;this.items=[];this.bytes=0;}
 private async drain(){
  if(this.running)return;
  this.running=true;const generation=this.generation;
  try{
   while(this.items.length&&generation===this.generation){
    const item=this.items[0];let action=item.action,bytes=item.bytes;
    if(action.type==='text'){
     let text='',size=0;
     for(const scalar of action.text){const length=this.encoder.encode(scalar).length;if(size+length>8192)break;text+=scalar;size+=length;}
     action={type:'text',text};bytes=size;
     item.action={type:'text',text:item.action.type==='text'?item.action.text.slice(text.length):''};item.bytes-=bytes;
     if(!item.bytes)this.items.shift();
    }else this.items.shift();
    let accepted=false;try{accepted=await this.send(action);}catch{}
    if(generation!==this.generation)break;
    this.bytes-=bytes;
    if(!accepted){this.reset();break;}
   }
  }finally{
   this.running=false;
   if(this.items.length)void this.drain();else this.idle();
  }
 }
}
