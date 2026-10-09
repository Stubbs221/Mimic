// Created by Василий Маслов on 06.10.2026.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const {build}=require('./node_modules/esbuild');
const bundle=await build({entryPoints:[new URL('./terminal.ts',import.meta.url).pathname],bundle:true,write:false,format:'iife',globalName:'MimicTerminal'});
const server=createServer((request,response)=>{response.setHeader('Content-Type',request.url==='/terminal.js'?'application/javascript':'text/html');response.end(request.url==='/terminal.js'?bundle.outputFiles[0].text:'<div id="root" style="width:440px;height:280px"></div><script src="/terminal.js"></script>');});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage();await page.goto(`http://127.0.0.1:${server.address().port}/`);
 const result=await page.evaluate(async()=>{
  const channels=new Map(),inputs=[],errors=[],closed=[];let lateOpen=true,outputMode='normal';
  const decode=value=>Uint8Array.from(atob(value),c=>c.charCodeAt(0)),encode=value=>btoa(Array.from(value,b=>String.fromCharCode(b)).join('')),utf8=new TextEncoder(),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  async function tool(name,args){
   if(name==='panel_terminal_open'){
    const pair=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},false,['deriveBits']),peer=await crypto.subtle.importKey('raw',decode(args.publicKey),{name:'ECDH',namedCurve:'P-256'},false,[]),shared=await crypto.subtle.deriveBits({name:'ECDH',public:peer},pair.privateKey,256),material=await crypto.subtle.importKey('raw',shared,'HKDF',false,['deriveKey']),id=crypto.randomUUID(),threadID='fixture-thread';
    const key=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:utf8.encode(id),info:utf8.encode('mimic-panel-terminal-v1')},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);
    channels.set(id,{id,taskID:args.taskID,threadID,key,sent:0});if(args.taskID==='slow'&&lateOpen)await pause(200);
    return{channelID:id,taskID:args.taskID,threadID,publicKey:encode(new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey)))};
   }
   if(name==='panel_terminal_close'){closed.push(args.channelID);channels.delete(args.channelID);return{};}
   const channel=channels.get(args.channelID);
   if(name==='panel_terminal_poll'){
    const sequence=++channel.sent,iv=crypto.getRandomValues(new Uint8Array(12)),aad=utf8.encode(`${channel.id}|${channel.taskID}|${channel.threadID}|output|${sequence}`),data=utf8.encode(JSON.stringify({bytes:outputMode==='first'?btoa('FIRST REAL OUTPUT\r\n'+Array.from({length:100},(_,i)=>'row '+i+'\r\n').join('')):outputMode==='normal'&&sequence===1?btoa(channel.taskID+'\r\n'):'',reset:false,canInput:true,outputAvailable:outputMode==='normal'||outputMode==='first',finished:outputMode==='finished'})),cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad},channel.key,data)),combined=new Uint8Array(12+cipher.length);combined.set(iv);combined.set(cipher,12);return{sequence,data:encode(combined)};
   }
   if(name==='panel_terminal_send'){
    const packet=args.packet,combined=decode(packet.data),aad=utf8.encode(`${channel.id}|${channel.taskID}|${channel.threadID}|input|${packet.sequence}`),plain=await crypto.subtle.decrypt({name:'AES-GCM',iv:combined.slice(0,12),additionalData:aad},channel.key,combined.slice(12)),value=JSON.parse(new TextDecoder().decode(plain));if(value.input)inputs.push({task:channel.taskID,input:value.input});return{};
   }
  }
  const terminal=new MimicTerminal.PrivateTerminal(tool,error=>errors.push(String(error)));document.querySelector('#root').append(terminal.host);
  const slow=terminal.attach('slow');await pause(40);await terminal.attach('current');await slow;
  const identity=terminal.channel.taskID,discarded=closed.length;
  let release;terminal.inputQueue=new Promise(resolve=>release=resolve);terminal.terminal.input('OLD-TASK-INPUT',true);await terminal.attach('next');release();await pause(100);
  terminal.terminal.input('CURRENT-TASK-INPUT',true);await pause(100);
  const nextIdentity=terminal.channel.taskID;
  terminal.setBootstrapPlaceholder({example:'Пример вывода',queued:'Ожидание запуска…',waiting:'Ожидание вывода…',unavailable:'Вывод этого запуска недоступен'},'tvos');
  outputMode='empty';terminal.setTaskStatus('queued');await terminal.attach('empty');
  const queued=terminal.placeholder.host.innerText;
  terminal.setTaskStatus('running');const waiting=terminal.placeholder.host.innerText;
  const noExampleInBuffer=!terminal.terminal.buffer.active.getLine(0)?.translateToString().includes('mimic bootstrap');
  const screen=terminal.host.querySelector('.xterm');outputMode='first';await terminal.poll();await pause(100);
  const firstHidden=terminal.placeholder.host.hidden;terminal.terminal.scrollToLine(10);const scroll=terminal.terminal.buffer.active.viewportY;
  outputMode='empty';await terminal.poll();terminal.setVisibility(false);terminal.setVisibility(true);terminal.setBootstrapPresentation(12,true);await pause(50);
  const emptyHidden=terminal.placeholder.host.hidden,retainedScroll=terminal.terminal.buffer.active.viewportY===scroll;
  outputMode='finished';await terminal.poll();terminal.setTaskStatus('succeeded');const finishedHidden=terminal.placeholder.host.hidden;
  const sameScreen=terminal.host.querySelector('.xterm')===screen;
  await terminal.attach('restored-no-output');const unavailable=terminal.placeholder.host.innerText;
  await terminal.dispose();
  return{identity,nextIdentity,discarded,inputs,errors,remaining:channels.size,queued,waiting,noExampleInBuffer,firstHidden,emptyHidden,finishedHidden,retainedScroll,sameScreen,unavailable};
 });
 assert.equal(result.identity,'current','late open must not replace the current task');assert(result.discarded>=1,'stale server subscription must close');assert.equal(result.nextIdentity,'next');assert.deepEqual(result.inputs,[{task:'next',input:'CURRENT-TASK-INPUT'}],'queued input must never cross task identity');assert.equal(result.remaining,0);assert.deepEqual(result.errors,[]);
 assert.equal(result.queued,'Ожидание запуска…');assert.equal(result.waiting,'Ожидание вывода…');assert(result.noExampleInBuffer);assert(result.firstHidden&&result.emptyHidden&&result.finishedHidden);assert(result.sameScreen&&result.retainedScroll);assert(result.unavailable.includes('$ mimic bootstrap tvos')&&result.unavailable.includes('Вывод этого запуска недоступен'));
 await page.setViewportSize({width:440,height:500});
 await page.evaluate(async()=>{
  document.body.style.height='2200px';
  const root=document.querySelector('#root');root.style.height='280px';root.style.background='#282738';
  const terminal=new MimicTerminal.PrivateTerminal(async()=>({}),error=>{throw error;});root.append(terminal.host);
  terminal.host.style.height='280px';terminal.host.style.position='relative';terminal.host.style.overflow='hidden';
  const style=document.createElement('style');style.textContent='.terminal-selectable[data-selected=false] .xterm{pointer-events:none}';document.head.append(style);
  terminal.setBootstrapPlaceholder({example:'Example',queued:'Queued',waiting:'Waiting',unavailable:'Unavailable'},'ios');
  terminal.hasOutput=true;terminal.updatePlaceholder();
  terminal.terminal.write(Array.from({length:200},(_,i)=>'ROW '+i+'\r\n').join(''));
  window.wheelFixture=terminal;
  await new Promise(resolve=>setTimeout(resolve,100));terminal.terminal.scrollToTop();
 });
 const host=page.locator('.terminal-host').last();await host.hover();
 const initial=await page.evaluate(()=>window.wheelFixture.terminal.buffer.active.viewportY);
 await page.mouse.wheel(0,120);await page.waitForTimeout(200);
 assert((await page.evaluate(()=>window.scrollY))>0,'inactive terminal permits panel scrolling');
 assert.equal(await page.evaluate(()=>window.wheelFixture.terminal.buffer.active.viewportY),initial,'inactive wheel leaves terminal scrollback unchanged');
 await host.click();const selectedScroll=await page.evaluate(()=>window.scrollY);
 assert.equal(await host.getAttribute('data-selected'),'true');
 await page.mouse.wheel(0,120);await page.waitForTimeout(200);
 assert((await page.evaluate(()=>window.wheelFixture.terminal.buffer.active.viewportY))>initial,'selected terminal scrolls its buffer');
 assert.equal(await page.evaluate(()=>window.scrollY),selectedScroll,'selected terminal owns wheel instead of panel');
 await page.mouse.click(420,450);assert.equal(await host.getAttribute('data-selected'),'false','outside click clears selection');
 await page.evaluate(()=>window.wheelFixture.dispose());
 console.log('PASS: late terminal open discarded, stale subscription closed, queued input isolated per task, encrypted input, first-output placeholder removal, empty polls, scroll retention and dispose');
}finally{await browser.close();server.close();}
