//
//  check-simulator-commands.mjs
//  MimicPanel
//
//  Created by Василий Маслов on 08.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {transform} from 'esbuild';

// Exercise the production response adapter with the native MCP private envelope.
// Preview fixtures return activities directly and cannot catch lost _meta replies.
const panelSource=await readFile(new URL('./panel.ts',import.meta.url),'utf8');
const adapter=panelSource.slice(panelSource.indexOf('class ToolFailure'),panelSource.indexOf('function releaseRejectedRequest'));
const activity={id:'accepted-command',kind:'action',status:'queued'};
const context=vm.createContext({preview:false,Error,app:{callServerTool:async()=>({content:[],_meta:{'mimic/simulator':activity}})},t:value=>value});
vm.runInContext((await transform(adapter,{loader:'ts',target:'es2022'})).code,context);
for(const name of ['simulator_ui_action','simulator_ui_observe','simulator_ui_viewer_action']){
 const result=await vm.runInContext(`tool(${JSON.stringify(name)},{})`,context);
 assert.equal(result?.id,activity.id,`${name} must preserve the accepted native activity ID`);
}
context.app.callServerTool=async()=>({isError:true,content:[],structuredContent:{code:'occupied',message:'busy'}});
await assert.rejects(vm.runInContext("tool('simulator_ui_action',{})",context),error=>error.code==='occupied');
console.log('PASS: private simulator command activities and native error codes survive the MCP response adapter');

const simulatorSource=await readFile(new URL('./simulator.ts',import.meta.url),'utf8');
const simulatorContext=vm.createContext({module:{exports:{}},require:()=>({}),Error,document:{hidden:false,activeElement:null,body:{}},crypto:{randomUUID:()=> 'new-request'},TextEncoder,setTimeout,clearTimeout,performance});
vm.runInContext((await transform(simulatorSource,{loader:'ts',format:'cjs',target:'es2022'})).code,simulatorContext);
const {SimulatorPanel}=simulatorContext.module.exports;
for(const checkout of [null,{checkoutId:'/fixture'}]){
 const panel=Object.create(SimulatorPanel.prototype),calls=[];
 context.app.callServerTool=async request=>{
  calls.push(request);
  return request.name==='get_simulator_activity'?{content:[],structuredContent:{activity:{...activity,status:'succeeded'}}}:{content:[],_meta:{'mimic/simulator':activity}};
 };
 Object.assign(panel,{generation:1,viewerID:'selected-viewer',session:{id:'selected-session',ready:true},frame:{revision:7},host:{dataset:{}},message:{},keyboard:{},surface:{},visible:true,geometry:0,blocked:()=>false,get:()=>({context:checkout}),update(){},heartbeat:async()=>{},refresh:async()=>{},capture:async()=>{},tool:(name,args)=>context.tool(name,args)});
 for(const action of [{type:'tap',x:12,y:34},{type:'swipe',x:20,y:40,endX:20,endY:90,duration:.25},{type:'text',text:'Я🙂'},{type:'key',key:'backspace'},{type:'key',key:'return'},{type:'home'},{type:'orientation',orientation:'landscapeLeft'}]){
  panel.frame={revision:7};
  assert.equal(await panel.command(action),true);
  assert.equal(panel.host.dataset.lastActionStatus,'succeeded');
 }
 const submitted=calls.filter(call=>call.name!=='get_simulator_activity');
 assert.equal(submitted.length,7,'Each user command is admitted once');
 for(const request of submitted){
  assert.equal(request.arguments.revision,7);
  assert.equal(request.name,'simulator_ui_observe');assert.equal(request.arguments.operation,'simulator_ui_viewer_action');assert.equal(request.arguments.viewerID,'selected-viewer');assert.equal(request.arguments.context,undefined);
 }
 assert.ok(calls.filter(call=>call.name==='get_simulator_activity').every(call=>call.arguments.activityID===activity.id));
 const before=calls.length;panel.frame={revision:7};
 context.app.callServerTool=async request=>{calls.push(request);return {isError:true,content:[],structuredContent:{code:'unknown',message:'uncertain'}};};
 assert.equal(await panel.command({type:'home'}),false);
 assert.equal(calls.length,before+1,'An uncertain command must never be replayed');
 assert.equal(panel.commandError,'uncertain');assert.equal(panel.host.dataset.lastActionCode,'unknown');
}
console.log('PASS: checkout and projectless panel commands share the pinned viewer route, wait for accepted IDs and never replay uncertainty');
