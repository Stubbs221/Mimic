//
//  check-simulator-video.mjs
//  MimicPanel
//
//  Created by Василий Маслов on 07.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {transform} from 'esbuild';

// Disposable deterministic browser boundary: exercise timing and delivery without a simulator.
const code=(await transform(await readFile(new URL('./simulator-video.ts',import.meta.url),'utf8'),{loader:'ts',format:'cjs',target:'es2022'})).code;
function fixture(decodeDelay=0,dequeueBeforeOutput=false){
 let now=100,identifier=0,paints=0,closedFrames=0;const timers=new Map(),listeners=new Set(),sockets=[],failures=[],reports=[];
 const later=(fn,delay=0,interval=0)=>{const id=++identifier;timers.set(id,{fn,time:now+delay,interval});return id;};
 class Socket{static OPEN=1;readyState=1;sent=[];constructor(url){this.url=url;sockets.push(this);}send(value){this.sent.push(value);}close(){this.closed=true;}}
 class Decoder{state='unconfigured';decodeQueueSize=0;constructor(options){this.options=options;}configure(){this.state='configured';}close(){this.state='closed';}decode(chunk){const output=()=>{if(this.state==='closed')return;this.options.output({timestamp:chunk.timestamp,close(){closedFrames++;}});};if(decodeDelay){this.decodeQueueSize++;if(dequeueBeforeOutput){later(()=>{this.decodeQueueSize--;this.ondequeue?.();},1);later(output,decodeDelay);}else later(()=>{this.decodeQueueSize--;output();this.ondequeue?.();},decodeDelay);}else output();}}
 const context=vm.createContext({module:{exports:{}},performance:{now:()=>now},setTimeout:(fn,delay)=>later(fn,delay),clearTimeout:id=>timers.delete(id),setInterval:(fn,delay)=>later(fn,delay,delay),clearInterval:id=>timers.delete(id),requestAnimationFrame:fn=>later(fn,1000/60),cancelAnimationFrame:id=>timers.delete(id),document:{addEventListener:(_,fn)=>listeners.add(fn),removeEventListener:(_,fn)=>listeners.delete(fn)},WebSocket:Socket,VideoDecoder:Decoder,EncodedVideoChunk:class{constructor(value){Object.assign(this,value);}},DOMException,Uint8Array,ArrayBuffer,DataView,atob});
 vm.runInContext(code,context);const api=context.module.exports;
 const canvas={width:0,height:0,dataset:{},getContext:()=>({drawImage(){paints++;}})};
 const player=new api.SimulatorVideoPlayer(canvas,reason=>failures.push(reason),value=>reports.push(value));
 async function advance(milliseconds){for(let n=0;n<8;n++)await Promise.resolve();const end=now+milliseconds;for(;;){const next=[...timers].filter(([,value])=>value.time<=end).sort((a,b)=>a[1].time-b[1].time)[0];if(!next)break;const [id,timer]=next;now=timer.time;if(timer.interval)timer.time+=timer.interval;else timers.delete(id);timer.fn();for(let n=0;n<8;n++)await Promise.resolve();}now=end;for(let n=0;n<8;n++)await Promise.resolve();}
 return {api,player,canvas,sockets,failures,reports,advance,now:()=>now,paints:()=>paints,closedFrames:()=>closedFrames,delay:(fn,ms)=>later(fn,ms),policy(value){for(const listener of [...listeners])listener({timeStamp:now,effectiveDirective:'connect-src',blockedURI:'ws://127.0.0.1:54321',originalPolicy:"connect-src 'none'",disposition:'enforce',...value});}};
}
const access={mode:'video',url:'ws://127.0.0.1:54321',token:'fixture-private-token'};
{
 const f=fixture(),controller=new AbortController(),pending=f.api.probeSecureVideoSocket(controller.signal);
 assert.equal(f.sockets[0].url,'wss://127.0.0.1:47931');f.sockets[0].onopen();f.sockets[0].onmessage({data:'mimic-wss-probe-v1'});
 const result=await pending;assert.equal(result.failure,null);assert.equal(result.stage,'message');assert.ok(f.sockets[0].closed);
 const cancelled=f.api.probeSecureVideoSocket(controller.signal);controller.abort();assert.equal((await cancelled).failure,'cancelled');
}
function packet(sequence,timestamp,keyframe=true){
 const config=keyframe?new Uint8Array([1,100,0,31,255,225,0]):new Uint8Array();const data=new Uint8Array(28+config.length),view=new DataView(data.buffer);data[0]=keyframe?1:0;view.setBigUint64(1,BigInt(sequence));view.setBigUint64(9,BigInt(Math.round(timestamp)));view.setUint32(17,856);view.setUint32(21,1226);view.setUint16(25,config.length);data.set(config,27);data[data.length-1]=1;return Buffer.from(data).toString('base64');
}
{
 const f=fixture();
 const policy=f.api.diagnosticPolicy("default-src 'self'; connect-src ws://user:password@127.0.0.1:*?token=secret#key https://api.example.com/private/path?access_token=secret; script-src 'nonce-secret' 'sha256-secret'; report-uri https://user:password@reports.example.com/private?secret");
 assert.match(policy,/connect-src ws:\/\/127\.0\.0\.1:\*/);assert.match(policy,/default-src 'self'/);assert.doesNotMatch(policy,/password|secret|private|nonce-|sha256-/);
 assert.equal(f.api.diagnosticOrigin('ws://user:password@127.0.0.1:54321/private?secret#secret'),'ws://127.0.0.1:54321');
 const longPolicy=f.api.diagnosticPolicy(`script-src ${Array.from({length:64},(_,i)=>`https://cdn${i}.example.com/${'x'.repeat(80)}`).join(' ')}; style-src ${Array.from({length:64},(_,i)=>`https://style${i}.example.com`).join(' ')}; connect-src 'none'`);
 assert.ok(longPolicy.startsWith("connect-src 'none';"));assert.ok(longPolicy.length<=4096);
 await f.player.attach(access);const socket=f.sockets[0];socket.onerror();
 f.policy({disposition:'report',originalPolicy:"connect-src 'none'; script-src 'nonce-fixture-private-token'"});
 f.policy({disposition:'enforce',originalPolicy:"connect-src 'self' https://example.com/path?secret"});
 f.policy({blockedURI:'ws://127.0.0.1:54322',originalPolicy:'unrelated-policy'});
 f.policy({timeStamp:f.now()-1,originalPolicy:'old-policy'});
 await f.advance(60);assert.equal(f.failures[0],'videoBlockedByCSP');assert.equal(f.player.diagnostics().length,2);assert.equal(f.player.diagnostics()[0].disposition,'report');assert.equal(f.player.diagnostics()[1].disposition,'enforce');
 assert.doesNotMatch(f.canvas.dataset.videoCSP,/fixture-private-token|nonce-|secret/);
 const saved=JSON.stringify(f.player.diagnostics());f.policy({originalPolicy:'late-policy'});assert.equal(JSON.stringify(f.player.diagnostics()),saved);
 await f.player.attach(access,'mcp',()=>new Promise(()=>{}));assert.equal(JSON.stringify(f.player.diagnostics()),saved);f.player.stop();
}
{
 const f=fixture();await f.player.attach(access);f.policy({disposition:'report'});await f.advance(60);assert.equal(f.failures.length,0);assert.equal(f.canvas.dataset.connectionFailure,undefined);f.player.stop();
 await f.player.attach(access);assert.equal(f.player.diagnostics().length,0);f.player.stop();
}
{
 const f=fixture(),pending=[];let calls=0;
 const poll=()=>{calls++;return new Promise(resolve=>pending.push(resolve));};
 await f.player.attach(access,'mcp',poll);await f.advance(500);assert.equal(calls,6);assert.equal(f.player.metrics().maxInFlight,6);
 f.player.stop();await f.player.attach(access,'mcp',poll);await f.advance(200);assert.equal(calls,6,'Replacement generation shares unresolved request cap');
 const responses=f.player.metrics().responses;pending[0]({packets:[packet(1,100000)],serverMicros:100000});await f.advance(34);assert.equal(f.player.metrics().responses,responses);assert.equal(f.paints(),0);assert.equal(calls,7);
 f.player.stop();const metrics=JSON.stringify(f.player.metrics());await f.advance(1000);assert.equal(JSON.stringify(f.player.metrics()),metrics);assert.equal(calls,7);
}
{
 const f=fixture(),pending=[];await f.player.attach(access,'mcp',()=>new Promise(resolve=>pending.push(resolve)));await f.advance(40);
 pending[1]({packets:[packet(1,100000)],serverMicros:120000});await f.advance(20);assert.equal(f.paints(),1);
 pending[0]({packets:[packet(1,100000)],serverMicros:120000});await f.advance(1);assert.equal(f.player.metrics().duplicates,1);
 await f.advance(10);pending[2]({packets:[packet(3,140000,false)],serverMicros:150000});await f.advance(35);assert.equal(f.paints(),1,'Gap delta waits for IDR');assert.equal(f.player.metrics().gaps,1);
 pending[3]({packets:[packet(4,160000)],serverMicros:170000});await f.advance(20);assert.equal(f.paints(),2);
 f.player.stop();assert.equal(f.closedFrames(),2);
}
{
 const f=fixture();await f.player.attach(access);const socket=f.sockets[0];
 // Retained decoded surfaces stay bounded, and stop closes every unpainted frame.
 for(let sequence=1;sequence<=12;sequence++)socket.onmessage({data:Uint8Array.from(Buffer.from(packet(sequence,f.now()*1000),'base64')).buffer});
 assert.equal(f.player.metrics().decoded,12);assert.equal(f.player.metrics().displayDrops,6);assert.equal(f.closedFrames(),6);
 await f.advance(17);assert.equal(f.paints(),1);f.player.stop();assert.equal(f.closedFrames(),12);await f.advance(200);assert.equal(f.paints(),1);
}
// Native reserves disjoint batches before the host delivers their replies. Reply order
// can differ from reservation order even with a healthy, lossless byte transport.
{
 const f=fixture();let sequence=0,reserved=0,calls=0;const history=[];
 const generate=()=>{history.push({sequence:++sequence,encoded:packet(sequence,f.now()*1000,sequence%30===1)});f.delay(generate,1000/30);};generate();
 const poll=after=>{const batch=history.filter(value=>value.sequence>Math.max(after,reserved)).slice(0,12);if(batch.length)reserved=batch.at(-1).sequence;const result={packets:batch.map(value=>value.encoded),serverMicros:f.now()*1000};return new Promise(resolve=>f.delay(()=>resolve(result),++calls%10===1?100:5));};
 await f.player.attach(access,'mcp',poll);await f.advance(2200);f.player.beginMeasurement();await f.advance(10000);f.player.stop();const metrics=f.player.metrics();
 assert.equal(metrics.gaps,0,'Reordered reserved replies must not masquerade as missing H264 frames');
 assert.equal(metrics.duplicates,0);assert.ok(metrics.frames>=298&&metrics.frames<=302,JSON.stringify(metrics));assert.ok(metrics.p95ms<=200,JSON.stringify(metrics));assert.equal(f.failures.length,0);
 console.log(JSON.stringify({fixture:'Reordered disjoint reserved replies / 10-second paint window',...metrics}));
}
for(const [delay,dequeueBeforeOutput] of [[0,false],[5,false],[5,true]]){
 const f=fixture(delay,dequeueBeforeOutput);let sent=false;
 await f.player.attach(access,'mcp',async()=>{const packets=sent?[]:Array.from({length:12},(_,index)=>packet(index+1,f.now()*1000,index===0));sent=true;return {packets,serverMicros:f.now()*1000};});await f.advance(250);f.player.stop();const metrics=f.player.metrics();
 assert.equal(metrics.decoded,12,'A valid full MCP batch waits for bounded decoder capacity');assert.equal(metrics.decodeDrops,0);assert.equal(metrics.recoverySkips,0);assert.equal(f.failures.length,0);assert.equal(f.closedFrames(),12);
 assert.equal(metrics.frames,12,'Decoder capacity must also reserve room for outputs awaiting RAF');assert.equal(metrics.displayDrops,0);
}
{
 const f=fixture();let sequence=0,reserved=0;const history=[];
 const generate=()=>{sequence++;if(sequence!==5)history.push({sequence,encoded:packet(sequence,f.now()*1000,sequence%30===1)});f.delay(generate,1000/30);};generate();
 const poll=after=>{const batch=history.filter(value=>value.sequence>Math.max(after,reserved)).slice(0,12);if(batch.length)reserved=batch.at(-1).sequence;return new Promise(resolve=>f.delay(()=>resolve({packets:batch.map(value=>value.encoded),serverMicros:f.now()*1000}),5));};
 await f.player.attach(access,'mcp',poll);await f.advance(2200);f.player.stop();const metrics=f.player.metrics();
 assert.equal(metrics.gaps,1,'A genuinely missing packet still requires keyframe recovery');assert.ok(metrics.recoverySkips>0);assert.ok(metrics.frames>30);assert.equal(f.failures.length,0);
}
for(const reserve of [false,true]){
 const f=fixture();let serverSequence=0,reserved=0;const packets=[];
 const generate=()=>{packets.push({sequence:++serverSequence,encoded:packet(serverSequence,f.now()*1000,serverSequence%30===1)});f.delay(generate,1000/30);};generate();
 const poll=after=>new Promise(resolve=>f.delay(()=>{const serverMicros=f.now()*1000,batch=packets.filter(value=>value.sequence>Math.max(after,reserve?reserved:0)).slice(-12),result=batch.map(value=>value.encoded);if(reserve&&batch.length)reserved=batch.at(-1).sequence;f.delay(()=>resolve({packets:result,serverMicros}),67);},67));
 await f.player.attach(access,'mcp',poll);await f.advance(2200);assert.notEqual(f.player.firstPaintAt,null);f.player.beginMeasurement();await f.advance(10000);f.player.stop();const metrics=f.player.metrics();
 assert.equal(metrics.durationMs,10000);assert.ok(metrics.frames>=299&&metrics.frames<=301,JSON.stringify(metrics));assert.ok(metrics.p95ms<=200,JSON.stringify(metrics));assert.ok(metrics.maxInFlight<=6&&metrics.maxInFlight>1);assert.ok(metrics.base64Bytes>metrics.bytes);assert.ok(reserve?metrics.duplicates===0:metrics.duplicates>0);assert.equal(metrics.gaps,0);assert.equal(f.failures.length,0);
 const final=JSON.stringify(metrics);await f.advance(2000);assert.equal(JSON.stringify(f.player.metrics()),final);console.log(JSON.stringify({fixture:'134ms RTT / 10-second paint window',reservedDelivery:reserve,...metrics}));
}
console.log('PASS: CSP sanitization, multiple policies, report-only, late events, six-request cap across generations, reordered replies, IDR recovery, final paint metrics.');

// Optional real Chromium CSP events; all traffic remains on a disposable loopback server.
if(process.argv.includes('--browser')){
 const {createServer}=await import('node:http'),{createRequire}=await import('node:module');const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
 const server=createServer((_request,reply)=>{
  reply.setHeader('Content-Type','text/html');
  reply.setHeader('Content-Security-Policy',["connect-src 'none'","connect-src 'self'"]);
  reply.setHeader('Content-Security-Policy-Report-Only','connect-src https://example.invalid');
  reply.end(`<canvas></canvas><script>const module={exports:{}};${code.replaceAll('</script','<\\/script')} const failures=[];const player=new module.exports.SimulatorVideoPlayer(document.querySelector('canvas'),reason=>failures.push(reason));window.fixture={player,failures};player.attach({mode:'video',url:'ws://127.0.0.1:54321',token:'fixture-private-token'});</script>`);
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 let browser;
 try{
  browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});const page=await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForFunction(()=>window.fixture.failures.length>0);
  const result=await page.evaluate(()=>({failure:window.fixture.failures[0],violations:window.fixture.player.diagnostics()}));
  assert.equal(result.failure,'videoBlockedByCSP');assert.ok(result.violations.filter(value=>value.disposition==='enforce').length>=2,JSON.stringify(result));assert.ok(result.violations.some(value=>value.disposition==='report'),JSON.stringify(result));assert.doesNotMatch(JSON.stringify(result),/fixture-private-token/);
  console.log('PASS: real Chromium enforcing and report-only CSP events, including two simultaneous enforcing policies.');
 }finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
}

// Full 90-second latency evidence must retain every paint at the faster source cadence.
for(const fps of [40,48]){
 const f=fixture();let sequence=0,reserved=0;const history=[];
 const generate=()=>{history.push({sequence:++sequence,encoded:packet(sequence,f.now()*1000,sequence%fps===1)});f.delay(generate,1000/fps);};generate();
 const poll=after=>{const batch=history.filter(value=>value.sequence>Math.max(after,reserved)).slice(0,12);if(batch.length)reserved=batch.at(-1).sequence;return Promise.resolve({packets:batch.map(value=>value.encoded),serverMicros:f.now()*1000});};
 await f.player.attach(access,'mcp',poll);await f.advance(2200);f.player.beginMeasurement();await f.advance(90000);f.player.stop();const metrics=f.player.metrics();
 assert.ok(metrics.fps>=fps-.1);assert.equal(metrics.latencySamples,metrics.frames);assert.equal(metrics.maxInFlight,1);assert.equal(metrics.gaps,0);assert.equal(metrics.decodeDrops,0);assert.equal(metrics.displayDrops,0);assert.deepEqual(f.failures,[]);
 console.log(`PASS: synthetic ${fps} FPS, full 90 s paint/latency window (${metrics.frames} samples), unchanged 30 Hz poll scheduler`);
}
