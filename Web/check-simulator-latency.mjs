//
//  check-simulator-latency.mjs
//  MimicPanel
//
//  Created by Василий Маслов on 08.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {transform} from 'esbuild';

const code=(await transform(await readFile(new URL('./simulator.ts',import.meta.url),'utf8'),{loader:'ts',format:'cjs',target:'es2022'})).code;
function fixture(){
 let now=0,next=0;const timers=new Map(),listeners={},actions=[];
 const later=(fn,ms)=>{const id=++next;timers.set(id,{fn,at:now+ms});return id;};
 const doc={hidden:false,activeElement:null,body:{}};
 const context=vm.createContext({module:{exports:{}},require:()=>({}),document:doc,crypto:{randomUUID:()=> 'manual-id'},TextEncoder,Error,performance:{now:()=>now},setTimeout:later,clearTimeout:id=>timers.delete(id)});
 vm.runInContext(code,context);const {SimulatorPanel}=context.module.exports,panel=Object.create(SimulatorPanel.prototype),state={busy:false,activities:[]};
 Object.assign(panel,{viewerID:'viewer',generation:0,deliveryEpoch:0,geometry:0,visible:true,session:{id:'session',ready:true},frame:{revision:1,width:400,height:800},acting:false,loading:false,benchmarking:false,wheel:null,wheelTimer:null,wheelCommand:false,manualActivityID:null,host:{dataset:{}},keyboard:{addEventListener(){},focus(){}},surface:{clientHeight:800,getBoundingClientRect:()=>({left:0,top:0,width:200,height:400}),addEventListener:(name,fn)=>{listeners[name]=fn;}},get:()=>({simulator:state,blocked:false})});
 let release;
 panel.command=async function(action){assert.equal(this.acting,false,'Only one native command at a time');actions.push({at:now,action});this.acting=true;await new Promise(resolve=>{release=resolve;});this.acting=false;return true;};
 panel.bindInput();
 const flush=async()=>{for(let n=0;n<20;n++)await Promise.resolve();};
 async function advance(ms){const end=now+ms;for(;;){const item=[...timers].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];if(!item)break;now=item[1].at;timers.delete(item[0]);item[1].fn();await flush();}now=end;await flush();}
 const wheel=(dy=10)=>{let prevented=false;listeners.wheel({clientX:100,clientY:200,deltaX:0,deltaY:dy,deltaMode:0,ctrlKey:false,preventDefault(){prevented=true;}});return prevented;};
 return {panel,state,doc,actions,wheel,advance,flush,finish:async()=>{release();await flush();},context};
}
{
 const f=fixture();assert.equal(f.wheel(),true);assert.equal(f.actions.length,1);assert.equal(f.actions[0].at,0,'Leading wheel dispatch does not wait for the gesture to end');assert.equal(f.actions[0].action.duration,.08);
 for(let n=0;n<49;n++){await f.advance(16);f.wheel(100);}
 assert.equal(f.actions.length,1,'A long gesture cannot create a native backlog');assert.ok(Math.abs(f.panel.wheel.dy)<=360);
 await f.finish();await f.advance(16);assert.equal(f.actions.length,2,'One current remainder follows completion');await f.finish();
}
for(const invalidation of ['hidden','agent','revision','geometry','expired']){
 const f=fixture();f.wheel();await f.advance(10);f.wheel();
 if(invalidation==='hidden')f.doc.hidden=true;
 if(invalidation==='agent'){f.state.busy=true;f.state.activities=[{id:'agent',status:'running'}];}
 if(invalidation==='revision')f.panel.frame.revision++;
 if(invalidation==='geometry')f.panel.geometry++;
 if(invalidation==='expired')await f.advance(250);
 await f.finish();await f.advance(20);assert.equal(f.actions.length,1,`${invalidation} must discard pending movement`);assert.equal(f.panel.wheel,null);
}
{
 const f=fixture();f.state.busy=true;f.state.activities=[{id:'MANUAL-ID',status:'running'}];f.panel.manualActivityID='manual-id';assert.equal(f.panel.externalSimulatorBusy(),false);
 f.state.activities.push({id:'agent',status:'queued'});assert.equal(f.panel.externalSimulatorBusy(),true);
}
// Exercise the real command's post-completion revision rebase, not just the wheel scheduler.
{
 const f=fixture(),prototype=f.context.module.exports.SimulatorPanel.prototype;let finishNative,calls=0;
 Object.assign(f.panel,{command:prototype.command,update(){},heartbeat:async()=>{},refresh:async()=>{},capture:async function(){this.frame={revision:2,width:400,height:800};this.geometry++;},message:{},tool:async(name,args)=>{
  if(name==='get_simulator_activity')return new Promise(resolve=>{finishNative=()=>resolve({activity:{status:'succeeded'}});});
  calls++;return {id:args.requestID};
 }});
 f.wheel();await f.flush();f.wheel();finishNative();await f.flush();
 assert.equal(f.panel.wheel.revision,2,'Only successful native completion rebases the remainder');
 assert.equal(f.panel.wheel.geometry,f.panel.geometry);await f.advance(16);assert.equal(calls,2);finishNative();await f.flush();
}
for(const completeAt of [20,150,510,900]){
 const f=fixture();let completed=false,polls=0;f.panel.tool=async()=>{polls++;return {activity:{status:completed?'succeeded':'running'}};};
 f.context.setTimeout(()=>{completed=true;},completeAt);
 const wait=f.panel.wait('activity');await f.flush();await f.advance(1500);await wait;assert.ok(polls<=7);
}
console.log('PASS: immediate wheel, one bounded remainder, stale/hidden/agent discard, manual busy identity and adaptive completion polling');
