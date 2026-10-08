//
//  check-simulator-input.mjs
//  MimicPanel
//
//  Created by Василий Маслов on 08.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {transform} from 'esbuild';
import vm from 'node:vm';
import {randomUUID} from 'node:crypto';
const source=await readFile(new URL('./simulator-input.ts',import.meta.url),'utf8');
const context=vm.createContext({module:{exports:{}},crypto:{randomUUID},setTimeout,clearTimeout,setInterval,clearInterval,requestAnimationFrame:cb=>setTimeout(cb,2),cancelAnimationFrame:clearTimeout});
vm.runInContext((await transform(source,{loader:'ts',format:'cjs',target:'es2022'})).code,context);
const {SimulatorContinuousInput}=context.module.exports;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn){for(let n=0;n<200&&!fn();n++)await sleep(5);assert.ok(fn(),'event stream did not settle');}
const access={sessionID:randomUUID(),generation:randomUUID(),width:402,height:874,orientation:'portrait'};
const point={x:200,y:700,timestamp:1};
{
 const events=[];let release;
 const input=new SimulatorContinuousInput('viewer',async(op,args)=>{
  if(op==='simulator_ui_input')return access;
  if(op==='simulator_ui_input_event'){events.push(args.event);if(args.event.phase==='down')await new Promise(r=>release=r);return{accepted:true,sequence:args.event.sequence};}
 },()=>{},()=>{});
 await input.prepare();assert.equal(input.down(point),true);
 for(let n=0;n<100;n++)input.move({...point,y:600-n});input.up({...point,y:450});
 await sleep(20);assert.equal(events.length,1,'No parallel move/up while down is in flight');
 release();await until(()=>!input.active);
 assert.deepEqual(events.map(e=>e.phase),['down','move','up']);assert.equal(events[1].y,450);
 assert.deepEqual(events.map(e=>e.sequence),[1,2,3]);
 assert.ok(events.every(e=>!('width'in e)&&!('orientation'in e)));
}
{
 const events=[];
 const input=new SimulatorContinuousInput('viewer',async(op,args)=>{
  if(op==='simulator_ui_input')return access;
  if(op==='simulator_ui_input_event'){events.push(args.event);await sleep(10);return{accepted:true,sequence:args.event.sequence};}
 },()=>{},()=>{});
 await input.prepare();for(let n=0;n<60;n++){input.wheel({...point,timestamp:n+1},0,3);await sleep(2);}
 await until(()=>!input.active);
 assert.equal(events[0].phase,'down');assert.equal(events.at(-1).phase,'up');
 assert.ok(events.length<60,'Wheel coalescing must bound event delivery');
 assert.equal(events.at(-1).y,520,'All signed wheel deltas survive coalescing');
}
{
 const operations=[],errors=[];
 const input=new SimulatorContinuousInput('viewer',async(op)=>{operations.push(op);if(op==='simulator_ui_input')return access;if(op==='simulator_ui_input_event')throw new Error('uncertain');},e=>{if(e)errors.push(e);},()=>{});
 await input.prepare();input.down(point);await until(()=>!input.active);
 input.move(point);input.up(point);assert.equal(input.down(point),false);
 assert.equal(operations.filter(x=>x==='simulator_ui_input_event').length,1);
 assert.equal(operations.filter(x=>x==='simulator_ui_input_cancel').length,1);
 assert.equal(errors.length,1);assert.equal(input.ready,false);
}
console.log('PASS: ordered down/latest move/up, bounded wheel deltas, and no replay after uncertainty');
