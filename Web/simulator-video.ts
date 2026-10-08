//
//  simulator-video.ts
//  MimicPanel
//
//  Created by Василий Маслов on 07.10.2026.
export type VideoAccess={mode:'video'|'snapshots';url?:string;token?:string;reason?:string};
export type VideoMetrics={transport:'websocket'|'mcp';width:number;height:number;frames:number;fps:number;p95ms:number|null;clockRTTms:number|null;bytes:number;gaps:number;displayDrops:number;durationMs:number;requests:number;responses:number;maxInFlight:number;duplicates:number;base64Bytes:number;meanRTTms:number|null;maxRTTms:number|null;latencySamples:number;packets:number;decoded:number;recoverySkips:number;decodeDrops:number;reordered:number};
export type VideoPolicyViolation={originalPolicy:string;effectiveDirective:string;blockedURI:string;disposition:string;stage:string};
type Poll=(after:number)=>Promise<{packets:string[];serverMicros:number}>;

/** A development-only TLS handshake check. No device frames, grants or commands cross this socket. */
export function probeSecureVideoSocket(signal:AbortSignal):Promise<{transport:string;stage:string;failure:string|null;durationMs:number;cspViolations:VideoPolicyViolation[]}> {
 const url='wss://127.0.0.1:47931',started=performance.now(),violations:VideoPolicyViolation[]=[];
 return new Promise(resolve=>{
  let socket:WebSocket|null=null,stage='starting',finished=false;
  const finish=(failure:string|null)=>{
   if(finished)return;finished=true;clearTimeout(timer);document.removeEventListener('securitypolicyviolation',policy);signal.removeEventListener('abort',abort);
   if(socket){socket.onopen=null;socket.onmessage=null;socket.onerror=null;socket.onclose=null;socket.close();}
   resolve({transport:'wss-probe',stage,failure,durationMs:performance.now()-started,cspViolations:violations});
  };
  const policy=(event:SecurityPolicyViolationEvent)=>{
   if(event.timeStamp<started||event.effectiveDirective!=='connect-src'||diagnosticOrigin(event.blockedURI)!==url)return;
   if(violations.length<16)violations.push({originalPolicy:diagnosticPolicy(event.originalPolicy),effectiveDirective:'connect-src',blockedURI:url,disposition:event.disposition==='report'?'report':'enforce',stage});
  };
  const failed=()=>{setTimeout(()=>finish(violations.some(value=>value.disposition==='enforce')?'videoBlockedByCSP':'tlsOrNetworkFailure'),50);};
  const abort=()=>finish('cancelled'),timer=setTimeout(()=>finish('timeout'),5000);
  document.addEventListener('securitypolicyviolation',policy);signal.addEventListener('abort',abort,{once:true});
  if(signal.aborted){abort();return;}
  try{socket=new WebSocket(url);socket.onopen=()=>{stage='open';};socket.onmessage=event=>{if(event.data==='mimic-wss-probe-v1'){stage='message';finish(null);}else finish('unexpectedMessage');};socket.onerror=failed;socket.onclose=failed;}catch{failed();}
 });
}

/** Diagnostics retain network origins, never URL credentials, paths, queries or fragments. */
export function diagnosticOrigin(value:string):string {
 const match=/^([a-z][a-z\d+.-]*):\/\/([^/?#\s]+)/i.exec(value);
 if(!match)return ['inline','eval','self','none'].includes(value)?value:'[redacted]';
 const host=match[2].split('@').at(-1)!;
 if(!/^(?:\*\.)?[a-z\d.*-]+(?::(?:\d+|\*))?$/i.test(host))return '[redacted]';
 return `${match[1].toLowerCase()}://${host.toLowerCase()}`;
}
/** Preserve directive/source structure while removing nonces, hashes and unknown opaque values. */
export function diagnosticPolicy(value:string):string {
 return value.slice(0,16384).split(';').slice(0,64).map(part=>{
  const [directive,...sources]=part.trim().split(/\s+/);
  if(!/^[a-z-]+$/i.test(directive??''))return '';
  return [directive,...sources.slice(0,64).map(source=>{
   if(/^'(nonce-|sha(?:256|384|512)-)/i.test(source))return "'[redacted]'";
   if(/^'(?:self|none|unsafe-inline|unsafe-eval|strict-dynamic|unsafe-hashes|report-sample|wasm-unsafe-eval)'$/.test(source)||source==='*'||/^[a-z][a-z\d+.-]*:$/i.test(source))return source;
   if(source.includes('://'))return diagnosticOrigin(source);
   if(/^(?:\*\.)?(?:localhost|[a-z\d*-]+(?:\.[a-z\d*-]+)+)(?::(?:\d+|\*))?$/i.test(source))return source;
   return '[redacted]';
  })].join(' ');
 // Host policies can contain kilobytes of CDN sources before the failing directive.
 // Keep connect-src first so the bounded report always retains the relevant evidence.
 }).filter(Boolean).sort((a,b)=>Number(b.startsWith('connect-src '))-Number(a.startsWith('connect-src '))).join('; ').slice(0,4096);
}

/** The stream carries AVCC H.264, never DOM, commands or model-visible tool output. */
export class SimulatorVideoPlayer {
 private socket:WebSocket|null=null;
 private decoder:VideoDecoder|null=null;
 private generation=0;
 private after=0;
 private needsKeyframe=true;
 private signature='';
 // Outstanding requests outlive stop(): a replacement generation must share this cap.
 private outstanding=new Set<symbol>();
 private packetQueue=new Map<number,Uint8Array>();private packetQueueBytes=0;private gapWaiters:Set<symbol>|null=null;
 private timer:ReturnType<typeof setTimeout>|null=null;
 private pingTimer:ReturnType<typeof setInterval>|null=null;
 private startupTimer:ReturnType<typeof setTimeout>|null=null;
 private failureTimer:ReturnType<typeof setTimeout>|null=null;
 private policyListener:((event:SecurityPolicyViolationEvent)=>void)|null=null;
 private policyFailure='';
 private violations:VideoPolicyViolation[]=[];
 private started=0;private stoppedAt:number|null=null;private lastFrame=0;private firstPaint:number|null=null;
 private offset=0;private bestRTT=Infinity;
 // Keep the entire 90 s qualification window above 40 FPS, with a bounded live history.
 private latencies:number[]=[];
 private count=0;private bytes=0;private gaps=0;private duplicates=0;private base64Bytes=0;
 private packetCount=0;private decoded=0;private recoverySkips=0;private decodeDrops=0;private reordered=0;
 private requests=0;private responses=0;private maxInFlight=0;private rttTotal=0;private rttCount=0;private maxRTT=0;
 private displayDrops=0;private paintRequest:number|null=null;private paintFrames:VideoFrame[]=[];private pendingFrames=0;
 private frozen=false;
 private transport:'websocket'|'mcp'='websocket';
 private output:CanvasRenderingContext2D;
 constructor(readonly canvas:HTMLCanvasElement,private onFailure:(reason:string)=>void,private onMetrics:(metrics:VideoMetrics)=>void=()=>{},private onFrame:()=>void=()=>{}){this.output=canvas.getContext('2d',{alpha:false})!;}
 freeze(value:boolean){this.frozen=value;}
 get firstPaintAt(){return this.firstPaint;}
 diagnostics(){return this.violations.map(value=>({...value}));}
 /** Begin a complete paint interval without discarding decoder state or clock calibration. */
 beginMeasurement(){this.started=performance.now();this.count=0;this.bytes=0;this.gaps=0;this.duplicates=0;this.base64Bytes=0;this.displayDrops=0;this.latencies=[];this.requests=0;this.responses=0;this.maxInFlight=this.outstanding.size;this.rttTotal=0;this.rttCount=0;this.maxRTT=0;this.packetCount=0;this.decoded=0;this.recoverySkips=0;this.decodeDrops=0;this.reordered=0;}
 metrics():VideoMetrics {
  const durationMs=Math.max(0,(this.stoppedAt??performance.now())-this.started),sorted=[...this.latencies].sort((a,b)=>a-b);
  return {transport:this.transport,width:this.canvas.width,height:this.canvas.height,frames:this.count,fps:this.count/Math.max(.001,durationMs/1000),p95ms:sorted.length>=30?sorted[Math.min(sorted.length-1,Math.ceil(sorted.length*.95)-1)]:null,clockRTTms:Number.isFinite(this.bestRTT)?this.bestRTT:null,bytes:this.bytes,gaps:this.gaps,displayDrops:this.displayDrops,durationMs,requests:this.requests,responses:this.responses,maxInFlight:this.maxInFlight,duplicates:this.duplicates,base64Bytes:this.base64Bytes,meanRTTms:this.rttCount?this.rttTotal/this.rttCount:null,maxRTTms:this.rttCount?this.maxRTT:null,latencySamples:sorted.length,packets:this.packetCount,decoded:this.decoded,recoverySkips:this.recoverySkips,decodeDrops:this.decodeDrops,reordered:this.reordered};
 }
 async attach(access:VideoAccess,transport:'websocket'|'mcp'='websocket',poll?:Poll){
  this.stop();this.stoppedAt=null;this.firstPaint=null;this.bestRTT=Infinity;this.after=0;this.needsKeyframe=true;this.signature='';this.frozen=false;this.beginMeasurement();
  this.policyFailure='';delete this.canvas.dataset.connectionFailure;this.canvas.dataset.connectionStage='starting';const generation=this.generation;this.transport=transport;this.canvas.dataset.videoTransport=transport;
  if(access.mode!=='video'||typeof VideoDecoder==='undefined'){this.fail(access.reason??'videoDecoderUnavailable');return;}
  this.lastFrame=performance.now();
  if(transport==='mcp'){
   if(!poll){this.fail('videoUnavailable');return;}
   // Fixed dispatch cadence, bounded overlap, and no catch-up queue after a delayed tick.
   const tick=()=>{
    if(generation!==this.generation)return;
    if(performance.now()-this.lastFrame>8000){this.fail('videoStalled');return;}
    this.timer=setTimeout(tick,1000/30);
    if(this.outstanding.size>=6||this.packetQueue.size)return;
    const request=Symbol(),start=performance.now();this.outstanding.add(request);this.requests++;this.maxInFlight=Math.max(this.maxInFlight,this.outstanding.size);
    void (async()=>{
     try{
      const result=await poll(this.after);if(generation!==this.generation)return;
      this.responses++;this.clock(start,result.serverMicros);
      if(!Array.isArray(result.packets)||result.packets.length>12||result.packets.some(value=>typeof value!=='string')||result.packets.reduce((sum,value)=>sum+value.length,0)>600048){this.fail('videoPacketInvalid');return;}
      for(const encoded of result.packets){if(generation!==this.generation)break;this.base64Bytes+=encoded.length;this.enqueuePacket(Uint8Array.from(atob(encoded),c=>c.charCodeAt(0)));}
     }catch{if(generation===this.generation)this.fail('videoDisconnected');}
     finally{this.outstanding.delete(request);if(generation===this.generation)this.drainPackets();}
    })();
   };
   tick();return;
  }
  this.violations=[];delete this.canvas.dataset.videoCSP;
  if(!access.url||!/^ws:\/\/127\.0\.0\.1:\d+$/.test(access.url)||!access.token){this.fail('videoAccessInvalid');return;}
  const origin=access.url,attemptStarted=performance.now();
  this.policyListener=event=>{
   if(generation!==this.generation||event.timeStamp<attemptStarted||event.effectiveDirective!=='connect-src'||diagnosticOrigin(event.blockedURI)!==origin)return;
   const violation={originalPolicy:diagnosticPolicy(event.originalPolicy),effectiveDirective:'connect-src',blockedURI:diagnosticOrigin(event.blockedURI),disposition:event.disposition==='report'?'report':'enforce',stage:this.canvas.dataset.connectionStage==='open'?'open':'starting'};
   if(this.violations.length<16&&!this.violations.some(value=>JSON.stringify(value)===JSON.stringify(violation)))this.violations.push(violation);
   this.canvas.dataset.videoCSP=JSON.stringify(this.violations);
   if(event.disposition==='enforce'){this.policyFailure='videoBlockedByCSP';this.canvas.dataset.connectionFailure=this.policyFailure;}
  };
  document.addEventListener('securitypolicyviolation',this.policyListener);
  // SecurityPolicyViolation and socket error events can be queued in either order.
  const connectionFailure=(reason:string)=>{if(generation!==this.generation||this.failureTimer)return;this.failureTimer=setTimeout(()=>{this.failureTimer=null;if(generation===this.generation)this.fail(this.policyFailure||reason);},50);};
  let socket:WebSocket;
  try{socket=new WebSocket(access.url);}catch(error){connectionFailure(error instanceof DOMException?'videoSecurityError:'+error.name:'videoConnectionFailed');return;}
  this.socket=socket;socket.binaryType='arraybuffer';
  this.startupTimer=setTimeout(()=>{if(generation===this.generation&&this.firstPaint===null)this.fail('videoStartupTimeout');},8000);
  socket.onopen=()=>{
   if(generation!==this.generation)return;this.canvas.dataset.connectionStage='open';socket.send(JSON.stringify({token:access.token}));
   const ping=()=>{if(performance.now()-this.lastFrame>8000){this.fail('videoStalled');return;}if(socket.readyState===WebSocket.OPEN)socket.send(JSON.stringify({ping:performance.now()}));};ping();this.pingTimer=setInterval(ping,1000);
  };
  socket.onmessage=event=>{
   if(generation!==this.generation)return;
   if(typeof event.data==='string'){try{const value=JSON.parse(event.data);if(typeof value.pong==='number'&&typeof value.serverMicros==='number')this.clock(value.pong,value.serverMicros);}catch{}return;}
   if(event.data instanceof ArrayBuffer)this.receive(new Uint8Array(event.data));
  };
  socket.onerror=()=>connectionFailure('videoConnectionBlocked');
  socket.onclose=event=>connectionFailure('videoDisconnected:'+event.code);
 }
 private clock(start:number,serverMicros:number){
  const end=performance.now(),rtt=end-start;
  if(!Number.isFinite(start)||!Number.isFinite(serverMicros)||serverMicros<=0||rtt<0)return;
  this.rttCount++;this.rttTotal+=rtt;this.maxRTT=Math.max(this.maxRTT,rtt);
  if(rtt<this.bestRTT){this.bestRTT=rtt;this.offset=serverMicros-(start+end)*500;}
 }
 /** Reservations order native batches, not host replies. Retain a gap until all
  * requests already in flight have replied; only then can it mean missing history.
  * Pausing dispatch while packets wait for ordering or decoder capacity bounds
  * storage by six wire-sized batches without discarding a valid GOP. */
 private enqueuePacket(packet:Uint8Array){
  if(packet.length<27||packet.length>512000){this.fail('videoPacketInvalid');return;}
  const sequence=Number(new DataView(packet.buffer,packet.byteOffset,packet.byteLength).getBigUint64(1));
  if(!Number.isSafeInteger(sequence)){this.fail('videoPacketInvalid');return;}
  if(sequence<=this.after||this.packetQueue.has(sequence)){this.duplicates++;return;}
  if(this.packetQueue.size>=72||this.packetQueueBytes+packet.length>2700000){this.fail('videoPacketInvalid');return;}
  this.packetQueue.set(sequence,packet);this.packetQueueBytes+=packet.length;
 }
 private drainPackets(){
  const generation=this.generation;
  for(const sequence of [...this.packetQueue.keys()].sort((a,b)=>a-b)){
   // Codec dequeue can precede output. Reserve a surface for every submitted
   // frame until output/paint releases it, keeping the existing six-surface bound.
   if(this.decoder?.state==='configured'&&(this.decoder.decodeQueueSize>=3||this.pendingFrames+this.paintFrames.length>=6))return;
   const packet=this.packetQueue.get(sequence)!;
   if((this.after?sequence!==this.after+1:packet[0]!==1)){
    if(!this.gapWaiters){this.gapWaiters=new Set(this.outstanding);this.reordered++;}
    if([...this.gapWaiters].some(request=>this.outstanding.has(request)))return;
   }
   this.gapWaiters=null;this.packetQueue.delete(sequence);this.packetQueueBytes-=packet.length;this.receive(packet);
   if(generation!==this.generation)return;
  }
 }
 private receive(packet:Uint8Array){
  if(packet.length<27||packet.length>512000){this.fail('videoPacketInvalid');return;}
  const header=new DataView(packet.buffer,packet.byteOffset,packet.byteLength),keyframe=packet[0]===1,sequence=Number(header.getBigUint64(1)),timestamp=Number(header.getBigUint64(9)),width=header.getUint32(17),height=header.getUint32(21),length=header.getUint16(25);
  if(!Number.isSafeInteger(sequence)||!Number.isSafeInteger(timestamp)||!width||!height||width>4096||height>4096||length+27>=packet.length){this.fail('videoPacketInvalid');return;}
  if(sequence<=this.after){this.duplicates++;return;}
  if(this.after&&sequence!==this.after+1){this.gaps+=sequence-this.after-1;this.needsKeyframe=true;}
  this.after=sequence;this.bytes+=packet.length;this.packetCount++;
  if(this.needsKeyframe&&!keyframe){this.recoverySkips++;return;}
  const config=packet.slice(27,27+length),signature=width+'x'+height+':'+Array.from(config).join(',');
  if(keyframe&&length){
   if(config[0]!==1||config.length<7){this.fail('videoPacketInvalid');return;}
   if(signature!==this.signature||!this.decoder){
    if(this.decoder&&this.decoder.state!=='closed')this.decoder.close();this.pendingFrames=0;this.signature=signature;this.canvas.width=width;this.canvas.height=height;
    const generation=this.generation;this.decoder=new VideoDecoder({output:frame=>{
     if(generation!==this.generation){frame.close();return;}
     this.pendingFrames--;this.decoded++;this.lastFrame=performance.now();if(this.frozen){frame.close();return;}
     // MCP can deliver several consecutive frames together. Present them on separate
     // refreshes instead of replacing every frame before RAF. Bound retained surfaces
     // and discard the oldest only for an unpaced source such as WebSocket.
     if(this.paintFrames.length>=6){this.paintFrames.shift()!.close();this.displayDrops++;}this.paintFrames.push(frame);
     if(this.paintRequest===null)this.paintRequest=requestAnimationFrame(()=>this.paint(generation));
    },error:()=>{if(generation===this.generation)this.fail('videoDecoderUnavailable');}});
    // A wire-sized batch may exceed decoder capacity; resume its ordered tail
    // as the codec consumes input instead of dropping it and waiting for an IDR.
    this.decoder.ondequeue=()=>{if(generation===this.generation)this.drainPackets();};
    // The tested macOS hardware decoder batches output despite optimizeForLatency.
    // Software decoding preserves the same bitstream while avoiding that presentation delay.
    try{this.decoder.configure({codec:'avc1.'+Array.from(config.slice(1,4),x=>x.toString(16).padStart(2,'0')).join(''),description:config.buffer,optimizeForLatency:true,hardwareAcceleration:'prefer-software'});}
    catch{this.fail('videoDecoderUnavailable');return;}
   }
   this.needsKeyframe=false;
  }
  if(!this.decoder||this.decoder.state!=='configured')return;
  if(this.decoder.decodeQueueSize>3){this.decodeDrops++;this.needsKeyframe=true;return;}
  this.pendingFrames++;
  try{this.decoder.decode(new EncodedVideoChunk({type:keyframe?'key':'delta',timestamp,data:packet.slice(27+length)}));}catch{this.pendingFrames--;this.needsKeyframe=true;}
 }
 private paint(generation:number){
  this.paintRequest=null;const frame=this.paintFrames.shift();if(!frame)return;
  try{
   if(generation!==this.generation||this.frozen)return;
   this.output.drawImage(frame,0,0,this.canvas.width,this.canvas.height);this.count++;this.firstPaint??=performance.now();
   if(this.startupTimer)clearTimeout(this.startupTimer);this.startupTimer=null;
   if(Number.isFinite(this.bestRTT)){const latency=(performance.now()*1000+this.offset-frame.timestamp)/1000;if(latency>=0&&latency<10000){this.latencies.push(latency);if(this.latencies.length>12000)this.latencies.shift();}}
   this.onFrame();if(this.count===1||this.count%30===0)this.onMetrics(this.metrics());
  }finally{
   frame.close();
   if(generation===this.generation){
    // A painted frame releases one reserved surface; let ordered encoded input
    // advance without waiting for a codec dequeue that may have already fired.
    this.drainPackets();
    if(this.paintFrames.length&&this.paintRequest===null)this.paintRequest=requestAnimationFrame(()=>this.paint(generation));
   }
  }
 }
 private fail(reason:string){this.canvas.dataset.connectionFailure=reason;this.stop();this.onFailure(reason);}
 /** Tear down delivery, retaining a frozen final measurement and sanitized CSP evidence. */
 stop(){
  if(this.stoppedAt===null){this.stoppedAt=performance.now();if(this.started)this.onMetrics(this.metrics());}
  if(this.policyListener)document.removeEventListener('securitypolicyviolation',this.policyListener);this.policyListener=null;this.generation++;
  if(this.timer)clearTimeout(this.timer);if(this.pingTimer)clearInterval(this.pingTimer);if(this.startupTimer)clearTimeout(this.startupTimer);if(this.failureTimer)clearTimeout(this.failureTimer);
  this.timer=null;this.pingTimer=null;this.startupTimer=null;this.failureTimer=null;
  this.packetQueue.clear();this.packetQueueBytes=0;this.gapWaiters=null;this.pendingFrames=0;
  if(this.paintRequest!==null)cancelAnimationFrame(this.paintRequest);this.paintRequest=null;for(const frame of this.paintFrames)frame.close();this.paintFrames=[];
  const socket=this.socket;this.socket=null;if(socket){socket.onopen=null;socket.onclose=null;socket.onerror=null;socket.onmessage=null;socket.close();}
  if(this.decoder&&this.decoder.state!=='closed')this.decoder.close();this.decoder=null;
 }
}
