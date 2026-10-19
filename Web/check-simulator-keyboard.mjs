//
//  check-simulator-keyboard.mjs
//  MimicPanel
//
//  Created by Василий Маслов on 13.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {transform} from 'esbuild';
const source=await readFile(new URL('./simulator-keyboard.ts',import.meta.url),'utf8');
const context=vm.createContext({module:{exports:{}},TextEncoder});
vm.runInContext((await transform(source,{loader:'ts',format:'cjs',target:'es2022'})).code,context);
const {SimulatorKeyboardInput}=context.module.exports;
const flush=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
{
 const actions=[];let release,idle=0;
 const input=new SimulatorKeyboardInput(async action=>{actions.push(action);if(actions.length===1)await new Promise(resolve=>release=resolve);return true;},()=>idle++);
 assert.equal(input.text('А'),true);assert.equal(actions.length,1,'Committed text starts without debounce');
 input.text('😀');input.key('backspace');input.text('Б');input.key('return');
 assert.equal(actions.length,1,'Only one keyboard operation is in flight');release();await flush();
 assert.deepEqual(actions.map(a=>a.type==='text'?a.text:a.key),['А','😀','backspace','Б','return']);assert.equal(idle,1);
}
{
 const actions=[];const input=new SimulatorKeyboardInput(async action=>{actions.push(action);return true;},()=>{});
 const text='Я😀'.repeat(4000);input.text(text);await flush();
 assert.equal(actions.map(a=>a.text).join(''),text);
 assert.ok(actions.every(a=>new TextEncoder().encode(a.text).length<=8192&&!/[\uD800-\uDBFF]$/.test(a.text)));
}
{
 let release;const actions=[];const input=new SimulatorKeyboardInput(async action=>{actions.push(action);await new Promise(resolve=>release=resolve);return false;},()=>{});
 input.text('А');for(let i=0;i<100;i++)input.text('Б');input.key('return');
 assert.equal(input.text('x'.repeat(1_048_576)),false,'Limit includes the in-flight text');
 release();await flush();assert.equal(actions.length,1,'Unknown input is not replayed and the unsent tail is retired');assert.equal(input.active,false);
}
{
 let release;const actions=[];const input=new SimulatorKeyboardInput(async action=>{actions.push(action);if(actions.length===1)await new Promise(resolve=>release=resolve);return true;},()=>{});
 input.text('А');input.text('Б');input.reset();release();await flush();assert.equal(actions.length,1,'Hidden/replaced sessions discard their unsent tail');
}
// Exercise the actual panel admission while its own Apple command is outstanding.
{
 const panelContext=vm.createContext({module:{exports:{}},require:()=>({}),Error,TextEncoder,JSON,document:{hidden:false,activeElement:null,body:{}},crypto:{randomUUID:()=>crypto.randomUUID()},performance,setTimeout,clearTimeout});
 vm.runInContext((await transform(await readFile(new URL('./simulator.ts',import.meta.url),'utf8'),{loader:'ts',format:'cjs',target:'es2022'})).code,panelContext);
 const panel=Object.create(panelContext.module.exports.SimulatorPanel.prototype),actions=[];
 let release,revision=1,captures=0,heartbeats=0,refreshes=0;
 Object.assign(panel,{generation:0,deliveryEpoch:0,visible:true,disposed:false,viewerID:'viewer',inputSource:'apple',session:{id:'session',revision,ready:true},frame:{revision,width:402,height:874},manualActivities:new Set(),host:{dataset:{}},message:{},keyboard:{},surface:{},update(){},get:()=>({blocked:false,simulator:{busy:!!panel.manualActivityID,activities:panel.manualActivityID?[{id:panel.manualActivityID,status:'running'}]:[]}}),heartbeat:async()=>heartbeats++,refresh:async()=>refreshes++,capture:async()=>captures++,tool:async(name,args)=>{
  if(name==='get_simulator_activity')return {activity:{id:args.activityID,status:'succeeded'},state:{session:{id:'session',revision:++revision,ready:true}}};
  actions.push(args.action);if(actions.length===1)await new Promise(resolve=>release=resolve);return {id:args.requestID};
 }});
 panel.keyboardInput=new SimulatorKeyboardInput(async action=>{panel.keyboardSending=true;try{return await panel.command(action,true);}finally{panel.keyboardSending=false;}},()=>{});
 panel.enqueueText('А');assert.equal(actions.length,1);
 for(let i=0;i<100;i++)panel.enqueueText('Я');panel.keyboardInput.key('backspace');panel.enqueueText('Б');
 release();await flush();await flush();
 assert.deepEqual(actions.map(a=>a.type==='text'?a.text:a.key),['А','Я'.repeat(100),'backspace','Б']);
 assert.equal(captures+heartbeats+refreshes,0,'Completed command metadata advances the stream without a screenshot/heartbeat/state cycle');
 assert.equal(panel.frame.revision,5);
}
console.log('PASS: immediate Unicode text, lossless ordered keys, scalar-safe chunks, bounded buffering and no replay after uncertainty/reset');
