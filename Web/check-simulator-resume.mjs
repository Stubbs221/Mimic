//
//  check-simulator-resume.mjs
//  MimicPanel
//
//  Created by Василий Маслов on 07.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {transform} from 'esbuild';

// Exercise the real visibility/heartbeat methods with deferred native acknowledgements.
const code=(await transform(await readFile(new URL('./simulator.ts',import.meta.url),'utf8'),{loader:'ts',format:'cjs',target:'es2022'})).code;
const context=vm.createContext({module:{exports:{}},require:()=>({}),document:{hidden:false},setTimeout,clearTimeout,TextEncoder,Error,performance});
vm.runInContext(code,context);
const {SimulatorPanel}=context.module.exports;
const flush=async()=>{for(let n=0;n<20;n++)await Promise.resolve();};
function fixture(){
 const heartbeats=[],captures=[],transports=[];let nativeVisible=true,attaches=0;
 const panel=Object.create(SimulatorPanel.prototype);
 Object.assign(panel,{visible:true,attached:true,disposed:false,delivering:false,deliveryEpoch:0,generation:0,geometry:0,capturing:false,session:{id:'session',revision:1},heartbeatChain:Promise.resolve(),keyboard:{value:''},host:{dataset:{}},message:{},get:()=>({simulator:{visible:true}}),update(){},fit(){},setExpanded(){},stopDelivery(){this.deliveryEpoch++;this.delivering=false;},capture:async()=>{assert.equal(nativeVisible,true,'Capture must wait until native visibility is acknowledged');captures.push('fresh');},player:{attach:async(_access,transport,poll)=>{attaches++;transports.push(transport);assert.equal(typeof poll,'function','Default MCP delivery must have a private packet reader');}},tool:async(_name,args)=>{
  if(args.operation==='simulator_ui_viewer_heartbeat')return new Promise(resolve=>heartbeats.push({visible:args.visible,release(){nativeVisible=args.visible;resolve({session:{id:'session',revision:1}});}}));
  assert.equal(args.operation,'simulator_ui_video');return {mode:'video'};
 }});
 return {panel,heartbeats,captures,transports,attaches:()=>attaches};
}
{
 const f=fixture();f.panel.setVisible(false);await flush();assert.equal(f.heartbeats.length,1);assert.equal(f.heartbeats[0].visible,false);
 f.panel.setVisible(true);await flush();assert.equal(f.captures.length,0);assert.equal(f.heartbeats.length,1,'Visibility heartbeats must not overtake each other');
 f.heartbeats[0].release();await flush();assert.equal(f.heartbeats.length,2);assert.equal(f.heartbeats[1].visible,true);assert.equal(f.captures.length,0);
 f.heartbeats[1].release();await flush();assert.equal(f.captures.length,1);assert.equal(f.attaches(),1);assert.deepEqual(f.transports,['mcp']);
}
{
 const f=fixture();f.panel.visible=false;f.panel.setVisible(true);await flush();assert.equal(f.heartbeats.length,1);
 f.panel.setVisible(false);await flush();f.heartbeats[0].release();await flush();
 assert.equal(f.captures.length,0,'A collapsed generation must not fetch or attach video after a late heartbeat');assert.equal(f.attaches(),0);
 assert.equal(f.heartbeats[1].visible,false);f.heartbeats[1].release();await flush();
 f.panel.setVisible(true);await flush();f.heartbeats[2].release();await flush();assert.equal(f.captures.length,1);assert.equal(f.attaches(),1);
}
{
 const f=fixture();f.panel.visible=false;f.panel.setVisible(true);await flush();f.panel.disposed=true;f.panel.stopDelivery();f.heartbeats[0].release();await flush();
 assert.equal(f.captures.length,0);assert.equal(f.attaches(),0);
}
// Exercise actual passive capture failure handling. Recovery is bounded and never
// runs after collapse/disposal or while a device command owns the observation.
for(const reason of ['connectionLost','noSession','invalidResponse']){
 const f=fixture(),connections=[];
 Object.assign(f.panel,{session:{id:'session',deviceID:'selected-device',revision:1},recoveredCapture:false,loading:false,acting:false,benchmarking:false,get:()=>({simulator:{visible:true,busy:false}}),tool:async()=>{throw Object.assign(new Error('lost'),{code:reason});},disconnect:async function(){this.generation++;this.deliveryEpoch++;this.attached=false;this.session=null;},connect:async function(device,recovery){connections.push({device,recovery});this.recoveredCapture=recovery;this.attached=true;this.session={id:'replacement',deviceID:device,revision:1};}});
 await SimulatorPanel.prototype.capture.call(f.panel);
 assert.deepEqual(connections,[{device:'selected-device',recovery:true}]);
 await SimulatorPanel.prototype.capture.call(f.panel);
 assert.equal(connections.length,1,'A permanently unavailable device must not enter a reconnect loop');
 assert.equal(f.panel.message.title,reason);
}
{
 const f=fixture();let rejectRead,reconnects=0;
 Object.assign(f.panel,{session:{id:'session',deviceID:'selected-device',revision:1},loading:false,acting:false,get:()=>({simulator:{visible:true,busy:false}}),tool:()=>new Promise((_,reject)=>{rejectRead=reject;}),connect:async()=>{reconnects++;}});
 const read=SimulatorPanel.prototype.capture.call(f.panel);await flush();
 f.panel.setVisible(false);rejectRead(Object.assign(new Error('lost'),{code:'connectionLost'}));await read;
 assert.equal(reconnects,0,'A late hidden read must not reattach a viewer');
}
// A hidden host can suspend timers until native expires the viewer. Resume's
// heartbeat must recover just like a passive frame, without replaying any input.
for(const reason of ['connectionLost','noSession','invalidResponse']){
 const f=fixture(),connections=[];
 Object.assign(f.panel,{session:{id:'session',deviceID:'selected-device',revision:1},recoveredCapture:false,loading:false,acting:false,benchmarking:false,tool:async()=>{throw Object.assign(new Error('expired'),{code:reason});},disconnect:async function(){this.generation++;this.deliveryEpoch++;this.attached=false;this.session=null;},connect:async function(device,recovery){connections.push({device,recovery});this.recoveredCapture=recovery;this.attached=true;this.session={id:'replacement',deviceID:device,revision:1};}});
 await f.panel.heartbeat();await flush();
 assert.deepEqual(connections,[{device:'selected-device',recovery:true}]);
 await f.panel.heartbeat();await flush();assert.equal(connections.length,1,'Expired heartbeat recovery must be bounded');
 assert.equal(f.panel.host.dataset.connectionLostCode,reason);
}
{
 const f=fixture();let reconnects=0;
 Object.assign(f.panel,{visible:false,session:{id:'session',deviceID:'selected-device',revision:1},tool:async()=>{throw Object.assign(new Error('expired'),{code:'noSession'});},connect:async()=>{reconnects++;}});
 await f.panel.heartbeat();await flush();assert.equal(reconnects,0);assert.equal(f.panel.session.deviceID,'selected-device','Hidden expiry must retain the selection for visible recovery');
}
{
 const f=fixture();let rejectHeartbeat,reconnects=0;
 Object.assign(f.panel,{session:{id:'session',deviceID:'selected-device',revision:1},tool:()=>new Promise((_,reject)=>{rejectHeartbeat=reject;}),connect:async()=>{reconnects++;}});
 const pending=f.panel.heartbeat();await flush();f.panel.disposed=true;rejectHeartbeat(Object.assign(new Error('expired'),{code:'noSession'}));await pending;await flush();assert.equal(reconnects,0);
}
// A queued attach must survive the former 180-poll cutoff and report its actual stage.
{
 const f=fixture(),stages=[];let polls=0;
 context.setTimeout=callback=>{queueMicrotask(callback);return 0;};
 Object.assign(f.panel,{config:{devices:[{id:'selected-device',state:'Booted'}]},update(){stages.push(this.connectionStatus);},tool:async()=>{polls++;return {activity:{id:'attach',deviceID:'selected-device',status:polls<=200?'queued':polls===201?'preparing':polls===202?'running':'succeeded'},state:{activities:polls===1?[{id:'old-command',status:'unknown',queueReleased:false}]:[]}};}});
 await f.panel.wait('attach',0,true);
 assert.equal(polls,203,'Queue waiting must not time out and return to the picker');
 assert.equal(stages[0],'sim.v3.queueBlocked');assert.equal(stages[1],'sim.v3.queued');
 assert.deepEqual(stages.slice(-2),['sim.v2.connecting','sim.v2.connectingDevice']);
 f.panel.tool=async()=>{f.panel.generation++;return {activity:{status:'succeeded'}};};
 await assert.rejects(f.panel.wait('attach',0,true),/sim.v2.changed/);
 f.panel.generation=0;f.panel.tool=async()=>({activity:{status:'unknown'}});
 await assert.rejects(f.panel.wait('attach',0,true),/sim.v2.unknown/);
 context.setTimeout=setTimeout;
}
// Render the real status logic: a disconnected panel has no stream metrics or unrelated busy label.
{
 const f=fixture(),node=()=>({setAttribute(){},hidden:false,textContent:'',style:{}});
 Object.assign(f.panel,{loading:true,connectionStatus:'Ожидание в очереди…',acting:false,frame:null,session:null,mode:'connecting',home:node(),rotate:node(),expand:node(),disconnectButton:node(),notice:{...node(),dataset:{}},title:node(),detail:node(),surface:node(),keyboard:node(),status:node(),viewport:node(),picker:node(),selector:node(),metrics:node(),get:()=>({simulator:{busy:true}}),syncCardTitle(){},blocked:()=>true,showMetrics(){},renderMenu(){},fit(){}});
 SimulatorPanel.prototype.update.call(f.panel);
 assert.equal(f.panel.status.textContent,'Ожидание в очереди…');assert.equal(f.panel.metrics.hidden,true);
 f.panel.loading=false;SimulatorPanel.prototype.update.call(f.panel);
 assert.equal(f.panel.status.textContent,'sim.v2.disconnected');
}
{
 const f=fixture(),node=()=>({setAttribute(){},hidden:false,textContent:'',style:{}});let reads=0,busy=true;
 Object.assign(f.panel,{loading:false,acting:false,frame:null,session:{id:'session',deviceID:'selected-device',revision:2,ready:true},mode:'video',delivering:true,home:node(),rotate:node(),expand:node(),disconnectButton:node(),notice:{...node(),dataset:{}},title:node(),detail:node(),surface:node(),keyboard:node(),status:node(),viewport:node(),picker:node(),selector:node(),metrics:node(),get:()=>({simulator:{busy}}),syncCardTitle(){},blocked:()=>false,showMetrics(){},renderMenu(){},fit(){},videoLabel:()=> 'video',capture:async()=>{reads++;}});
 SimulatorPanel.prototype.update.call(f.panel);assert.equal(reads,0);
 busy=false;SimulatorPanel.prototype.update.call(f.panel);assert.equal(reads,1,'A video viewer must recover its post-command observation after native becomes idle');
 f.panel.delivering=false;SimulatorPanel.prototype.update.call(f.panel);assert.equal(reads,1,'Stopped delivery must not fetch a new observation');
}
console.log('PASS: ordered visibility acknowledgement, fresh MCP resume, lifecycle guards, bounded passive reconnection, deferred command observation, long queue waiting and connection status');
