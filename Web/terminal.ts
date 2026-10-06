// Created by Василий Маслов on 06.10.2026.
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
type Tool=(name:string,args?:Record<string,unknown>)=>Promise<any>;
const bytes=(value:string)=>Uint8Array.from(atob(value),c=>c.charCodeAt(0));
const base64=(value:Uint8Array)=>btoa(Array.from(value,b=>String.fromCharCode(b)).join(''));
const utf8=new TextEncoder();
/** One xterm instance survives polls, collapse and layout edits. No plaintext is sent to model context. */
export class PrivateTerminal {
 readonly host=document.createElement('div');
 private terminal=new Terminal({convertEol:false,fontSize:12,scrollback:1500,allowProposedApi:false});
 private fit=new FitAddon();
 private channel:{channelID:string;taskID:string;threadID:string}|null=null;
 private key:CryptoKey|null=null;
 private sent=0;private received=0;private polling=false;private canInput=false;private inputQueue=Promise.resolve();private timer:ReturnType<typeof setInterval>;
 private subscription:ReturnType<Terminal['onData']>;
 private generation=0;private observer:ResizeObserver;
 private taskID:string|null=null;private finished=false;private status='running';private visible=true;
 private message=document.createElement('p');
 constructor(private tool:Tool,private onError:(error:unknown)=>void,private labels={waiting:'Waiting for output…',unavailable:'Output unavailable'}){
  this.host.className='terminal-host';this.terminal.options.disableStdin=true;this.terminal.loadAddon(this.fit);this.terminal.open(this.host);this.message.className='terminal-message';this.host.append(this.message);
  this.subscription=this.terminal.onData(input=>this.enqueue({input}));
  this.observer=new ResizeObserver(()=>{if(this.host.getBoundingClientRect().width>20){this.fit.fit();this.enqueue({columns:this.terminal.cols,rows:this.terminal.rows});}});this.observer.observe(this.host);
  this.timer=setInterval(()=>{if(this.channel&&!this.finished)void this.poll();},700);
 }
 private aad(direction:string,sequence:number){const c=this.channel!;return utf8.encode(`${c.channelID}|${c.taskID}|${c.threadID}|${direction}|${sequence}`);}
 private enqueue(payload:Record<string,unknown>){const channel=this.channel;if(!channel||!this.canInput||!this.visible||this.status!=='running')return;this.inputQueue=this.inputQueue.then(()=>this.channel===channel?this.send(payload):undefined).catch(this.onError);}
 setVisibility(visible:boolean){this.visible=visible;this.host.inert=!visible;this.updateInput();if(!visible&&this.host.contains(document.activeElement))(document.activeElement as HTMLElement)?.blur();}
 setTaskStatus(status:string){this.status=status;this.updateInput();}
 private updateInput(){this.terminal.options.disableStdin=!this.visible||!this.canInput||this.status!=='running';}
 async attach(taskID:string){if(this.taskID===taskID)return;const closing=this.detach(),generation=this.generation;this.taskID=taskID;this.finished=false;this.message.hidden=false;this.message.textContent='';await closing;
  if(generation!==this.generation)return;
  const pair=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},false,['deriveBits']);
  const publicKey=new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey));
  const channel=await this.tool('panel_terminal_open',{taskID,publicKey:base64(publicKey)});
  const peer=await crypto.subtle.importKey('raw',bytes(channel.publicKey),{name:'ECDH',namedCurve:'P-256'},false,[]);
  const shared=await crypto.subtle.deriveBits({name:'ECDH',public:peer},pair.privateKey,256);
  const material=await crypto.subtle.importKey('raw',shared,'HKDF',false,['deriveKey']);
  const key=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:utf8.encode(channel.channelID),info:utf8.encode('mimic-panel-terminal-v1')},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);
  if(generation!==this.generation){await this.tool('panel_terminal_close',{channelID:channel.channelID}).catch(()=>{});return;}this.key=key;
  this.channel=channel;this.sent=0;this.received=0;this.terminal.reset();this.fit.fit();await this.poll();
 }
 private async send(payload:Record<string,unknown>){if(!this.channel||!this.key)return;const channel=this.channel,sequence=this.sent+1,iv=crypto.getRandomValues(new Uint8Array(12));
  const encrypted=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:this.aad('input',sequence)},this.key,utf8.encode(JSON.stringify(payload))));
  const combined=new Uint8Array(iv.length+encrypted.length);combined.set(iv);combined.set(encrypted,iv.length);
  if(this.channel!==channel)return;
  this.sent=sequence;
  try{await this.tool('panel_terminal_send',{channelID:channel.channelID,packet:{sequence,data:base64(combined)}});}catch(e){if(this.channel===channel){this.channel=null;this.key=null;this.canInput=false;this.updateInput();throw e;}}
 }
 private async poll(){if(this.polling||!this.channel||!this.key)return;this.polling=true;const channel=this.channel;try{
  const packet=await this.tool('panel_terminal_poll',{channelID:channel.channelID});if(this.channel!==channel)return;
  if(packet.sequence!==this.received+1)throw new Error('terminal.sequence');const combined=bytes(packet.data);
  const plaintext=await crypto.subtle.decrypt({name:'AES-GCM',iv:combined.slice(0,12),additionalData:this.aad('output',packet.sequence)},this.key,combined.slice(12));
  if(this.channel!==channel)return;
  this.received=packet.sequence;const output=JSON.parse(new TextDecoder().decode(plaintext));if(output.reset)this.terminal.reset();if(output.bytes)this.terminal.write(bytes(output.bytes));
  this.canInput=output.canInput;this.finished=output.finished===true;this.updateInput();
  this.message.hidden=output.outputAvailable!==false||!!output.bytes;
  this.message.textContent=this.finished?this.labels.unavailable:this.labels.waiting;
 }catch(e){if(this.channel===channel){this.channel=null;this.key=null;this.canInput=false;this.updateInput();this.onError(e);}}finally{this.polling=false;}}
 async detach(){this.generation++;this.taskID=null;this.finished=false;const channel=this.channel;this.channel=null;this.key=null;this.canInput=false;this.terminal.options.disableStdin=true;this.terminal.reset();if(channel)await this.tool('panel_terminal_close',{channelID:channel.channelID}).catch(()=>{});}
 async dispose(){clearInterval(this.timer);this.subscription.dispose();this.observer.disconnect();await this.detach();this.terminal.dispose();}
}
