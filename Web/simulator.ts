// Created by Василий Маслов on 07.10.2026.
import ru from './ru.json';
const t=(key:string)=>(ru as Record<string,string>)[key]??key;
import {SimulatorContinuousInput} from './simulator-input';
import {SimulatorVideoPlayer,probeSecureVideoSocket,type VideoAccess,type VideoMetrics} from './simulator-video';
export type SimulatorContext={checkoutId:string;branch:string;sha:string;xcode:string;appleTarget:unknown;profileID:string|null;profileRevision:string|null};
export type SimulatorSession={id:string;deviceID:string;context:SimulatorContext;revision:number|null;ready:boolean};
export type SimulatorActivity={id:string;kind:string;status:string;errorCode?:string;deviceID?:string;queueReleased:boolean};
export type SimulatorState={session:SimulatorSession|null;activities:SimulatorActivity[];busy:boolean;visible?:boolean;protocolVersion?:number;version?:string;inputOwner?:string|null};
export type Frame={sessionID:string;revision:number;width:number;height:number;image:string;mimeType:string;targets?:unknown[]};
type Device={id:string;name:string;runtime:string;state:string;deviceTypeIdentifier?:string};
type DeviceProfile={model:string;width?:number;height?:number;radii?:number[];chromeIdentifier?:string;maskIdentifier?:string};
type Config={deviceProfiles?:Record<string,DeviceProfile>;capabilities?:{keys:string[]};context:SimulatorContext;version:string;visible:boolean;workspaceAuthorized:boolean;devices:Device[];recentIDs?:string[];authorizationPending?:boolean};
type Tool=(name:string,args?:Record<string,unknown>)=>Promise<any>;
type Snapshot={context:SimulatorContext|null;simulator?:SimulatorState;blocked:boolean};
const el=<K extends keyof HTMLElementTagNameMap>(tag:K,cls='',text='')=>{const node=document.createElement(tag);node.className=cls;node.textContent=text;return node;};
const icons={home:'<path d="m3 10 9-7 9 7v11h-6v-7H9v7H3Z"/>',rotate:'<path d="M20 8a9 9 0 1 0 1 9M20 2v6h-6"/><rect x="9" y="8" width="6" height="10" rx="1"/>',expand:'<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/>',menu:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>'};
/** Split by Unicode scalars, never in the middle of a UTF-8 sequence or surrogate pair. */
export function textChunks(value:string,limit=8192){const chunks:string[]=[];let chunk='',size=0;const encoder=new TextEncoder();for(const scalar of value){const bytes=encoder.encode(scalar).length;if(size+bytes>limit){chunks.push(chunk);chunk='';size=0;}chunk+=scalar;size+=bytes;}if(chunk)chunks.push(chunk);return chunks;}
/** Known families receive a bezel only; the captured image supplies real cutouts. Unknown identifiers stay neutral. */
export function deviceBody(identifier:string){const model=identifier.split('.').at(-1)??'';if(/^iPhone-(?:X(?:R|S|s)?|1[1-8](?:-|$)|Air(?:-|$))/.test(model))return 'iphone';if(/^iPhone-(?:SE|[5-8])/.test(model))return 'iphone-classic';if(/^iPad(?:-|Pro|Air|Mini|mini)/.test(model)&&/[0-9]|generation|inch/i.test(model))return 'ipad';return 'neutral';}
/** Each instance owns a viewer; DOM, focus and selection survive ordinary state polling. */
export class SimulatorPanel {
 readonly viewerID=crypto.randomUUID();
 private config:Config|null=null;private contextKey='';private xcodeKey='';private session:SimulatorSession|null=null;private frame:Frame|null=null;
 private visible=false;private attached=false;private loading=false;private acting=false;private generation=0;private geometry=0;private disposed=false;
 private imageSource:'auto'|'mcp'|'websocket'|'snapshots'='auto';private inputSource:'hid'|'apple'='hid';private inputSuspended=false;
 private sourceControls=el('div','sim-sources');private sourceButtons:HTMLButtonElement[]=[];private touch:SimulatorContinuousInput;private switchingSource=false;private hidFailure='';private videoSocketURL:string|null=null;
 private mode:'connecting'|'video'|'snapshots'='connecting';private delivering=false;private deliveryEpoch=0;private snapshotTimer:ReturnType<typeof setTimeout>|null=null;
 private heartbeatTimer:ReturnType<typeof setInterval>;private textTimer:ReturnType<typeof setTimeout>|null=null;private pendingText='';private composing=false;
 private heartbeatChain:Promise<void>=Promise.resolve();
 private recoveredCapture=false;private connectionStatus:string|null=null;private commandError:string|null=null;
 private orientation='portrait';private expanded=false;private previousFocus:HTMLElement|null=null;private isolated:HTMLElement[]=[];
 private inputNotice=el('p','sim-input-notice');private metrics=el('div','sim-metrics');private detail=el('span','sim-detail');private profile:DeviceProfile|undefined;private masks:Record<string,string>|null=null;private resizeObserver:ResizeObserver;private benchmarking=false;private benchmarkFailure='';private lastVideoMetrics:VideoMetrics|null=null;private videoDiagnostics=el('pre','sim-video-diagnostics');private videoSizeKey='';private snapshotCount=0;private snapshotStart=0;private snapshotLatencies:number[]=[];private inputChain:Promise<void>=Promise.resolve();
 private cardTitle:HTMLButtonElement|null=null;private cardAnchor:Comment|null=null;
 private secureProbe:AbortController|null=null;
 private title=el('strong','sim-name',t('sim.v2.title'));private status=el('span','sim-state');private message=el('p','sim-message');
 private picker=el('details','sim-picker');private selector=el('button','sim-switch',t('sim.v2.choose'));private search=el('input','sim-search');private choices=el('div','sim-choices');
 private menu=el('details','sim-menu');private menuList=el('div','sim-menu-list');
 private heading=el('strong','sim-heading',t('sim.v2.title'));private disconnectButton=el('button','sim-disconnect',t('sim.v2.disconnect'));
 private notice=el('p','sim-notice');private diagnostics=el('details','sim-diagnostics');private diagnosticActions=el('div','sim-diagnostic-actions');
 private menuChecks:(()=>void)[]=[];
 private viewport=el('div','sim-viewport');private body=el('div','sim-device neutral');private surface=el('div','sim-surface');
 private image=el('img','simulator-image');private canvas=el('canvas','simulator-video');private keyboard=el('input','sim-keyboard');
 private home:HTMLButtonElement;private rotate:HTMLButtonElement;private expand:HTMLButtonElement;private player:SimulatorVideoPlayer;
 private drag:{pointer:number;x:number;y:number;time:number;geometry:number;revision:number;rect:DOMRect}|null=null;
 private wheel:{x:number;y:number;dx:number;dy:number;geometry:number;revision:number;at:number}|null=null;private wheelTimer:ReturnType<typeof setTimeout>|null=null;
 private wheelCommand=false;private manualActivityID:string|null=null;
 constructor(readonly host:HTMLElement,private tool:Tool,private get:()=>Snapshot,private refresh:()=>Promise<void>){
  host.classList.add('simulator-v2');
  this.touch=new SimulatorContinuousInput(this.viewerID,(op,args)=>this.call(op,args),error=>{if(error){this.hidFailure=t('sim.source.hidUnavailable');this.host.dataset.hidFailure=String((error as {code?:string})?.code??'connectionLost');}this.update();},()=>void this.touchEnded());
  this.buildSourceControls();
  const header=el('div','sim-header'),identity=el('div','sim-identity'),actions=el('div','sim-actions');header.append(this.heading,this.menu);identity.append(this.selector,this.disconnectButton);
  this.status.setAttribute('role','status');this.message.setAttribute('role','status');
  this.search.type='search';this.search.placeholder=t('sim.v2.searchPlaceholder');this.search.setAttribute('aria-label',t('sim.v2.search'));this.search.oninput=()=>this.renderChoices();
  this.picker.id='sim-picker-'+this.viewerID;this.selector.type='button';this.selector.setAttribute('aria-controls',this.picker.id);this.selector.replaceChildren(this.title,el('span','sim-chevron','⌄'));this.picker.ontoggle=()=>{this.selector.setAttribute('aria-expanded',String(this.picker.open));if(this.picker.open&&!this.config)void this.load();this.fit();};
  this.disconnectButton.type='button';this.disconnectButton.onclick=()=>void this.disconnect();
  this.home=this.icon('home','Home',()=>void this.command({type:'home'}));this.rotate=this.icon('rotate',t('sim.v2.rotate'),()=>void this.command({type:'orientation',orientation:this.orientation==='portrait'?'landscapeLeft':'portrait'}));this.expand=this.icon('expand',t('sim.v2.expand'),()=>this.setExpanded(!this.expanded));
  const menuTitle=el('summary','sim-icon');menuTitle.title=t('sim.v2.menu');menuTitle.setAttribute('aria-label',t('sim.v2.menu'));menuTitle.innerHTML=this.svg('menu');this.menu.append(menuTitle);
  // Keep the menu in normal flow: it must never cover device choices or screen input.
  this.menuList.id='sim-menu-'+this.viewerID;this.menuList.hidden=true;menuTitle.setAttribute('aria-controls',this.menuList.id);this.menu.ontoggle=()=>{this.menuList.hidden=!this.menu.open;if(this.menu.open){this.picker.open=false;this.renderMenu();}this.fit();};
  actions.append(this.home,this.rotate);this.selector.onclick=()=>{this.menu.open=false;this.picker.open=!this.picker.open;};const disclosure=el('summary');disclosure.hidden=true;this.picker.append(disclosure,this.search,this.choices);
  const diagnosticTitle=el('summary','',t('sim.v4.diagnostics'));this.diagnostics.append(diagnosticTitle,this.detail,this.metrics,this.diagnosticActions,this.videoDiagnostics);this.diagnostics.ontoggle=()=>this.fit();this.notice.setAttribute('role','status');
  this.surface.tabIndex=0;this.surface.setAttribute('role','application');this.surface.setAttribute('aria-label',t('sim.v2.screen'));this.surface.title=t('sim.v2.screen');
  this.image.alt=t('sim.v2.screenImage');this.image.draggable=false;this.image.hidden=true;this.canvas.hidden=true;this.canvas.setAttribute('aria-hidden','true');
  this.keyboard.type='text';this.keyboard.autocomplete='off';this.keyboard.spellcheck=false;this.keyboard.setAttribute('aria-label',t('sim.v2.input'));this.keyboard.tabIndex=-1;
  this.surface.append(this.image,this.canvas,this.keyboard);this.body.append(this.surface);this.viewport.append(this.body);this.inputNotice.setAttribute('role','status');this.videoDiagnostics.hidden=true;host.append(header,identity,this.menuList,this.status,this.picker,actions,this.sourceControls,this.notice,this.message,this.inputNotice,this.viewport,this.diagnostics);
  this.player=new SimulatorVideoPlayer(this.canvas,reason=>{if(this.benchmarking)this.benchmarkFailure=reason;else this.fallback(reason);},metrics=>{this.lastVideoMetrics=metrics;this.canvas.dataset.metrics=JSON.stringify(metrics);this.showMetrics(metrics);},()=>{if(this.mode==='video')return;this.mode='video';this.canvas.hidden=false;this.image.hidden=true;this.message.textContent=this.commandError??'';this.update();});
  this.surface.onfocus=()=>{if(!this.blocked())this.keyboard.focus({preventScroll:true});};
  this.bindInput();this.resizeObserver=new ResizeObserver(()=>this.fit());this.resizeObserver.observe(this.viewport);
  window.addEventListener('focus',this.focusInput);window.addEventListener('blur',this.blurInput);document.addEventListener('visibilitychange',this.visibilityChanged);window.addEventListener('keydown',this.escape,true);window.addEventListener('resize',this.resized);
  this.heartbeatTimer=setInterval(()=>void this.heartbeat(),10000);this.renderMenu();this.update();
 }
 /** Move the existing collapse control into the retained simulator header; avoid a second card title. */
 setCardHeader(title:HTMLButtonElement|null,_collapse:()=>void){if(title===this.cardTitle)return;if(this.cardTitle&&this.cardAnchor){this.cardAnchor.replaceWith(this.cardTitle);this.cardTitle.querySelector('.block-name')!.textContent=t('sim.v2.title');this.cardAnchor=null;}this.cardTitle=title;this.heading.hidden=!!title;if(title){this.cardAnchor=document.createComment('simulator-header');title.replaceWith(this.cardAnchor);this.heading.before(title);this.syncCardTitle();}}

 // MARK: - Explicit image and input sources (approved Figma V2, 201:507)
 private buildSourceControls(){
  const image=el('div','sim-source-group'),input=el('div','sim-source-group');
  image.setAttribute('role','group');image.setAttribute('aria-label',t('sim.source.image'));input.setAttribute('role','group');input.setAttribute('aria-label',t('sim.source.input'));
  image.append(el('span','sim-source-label',t('sim.source.image')));input.append(el('span','sim-source-label',t('sim.source.input')));
  const images=el('div','sim-source-image-options'),inputs=el('div','sim-source-input-options');
  for(const [value,key] of [['auto','sim.source.auto'],['mcp','sim.source.mcp'],['websocket','sim.source.websocket'],['snapshots','sim.source.snapshots']] as const){const b=el('button','sim-source-option',t(key));b.type='button';b.dataset.imageSource=value;b.onclick=()=>void this.changeSource(value,this.inputSource);images.append(b);this.sourceButtons.push(b);}
  for(const [value,key] of [['hid','sim.source.hid'],['apple','sim.source.apple']] as const){const b=el('button','sim-source-option',t(key));b.type='button';b.dataset.inputSource=value;b.onclick=()=>void this.changeSource(this.imageSource,value);b.title=t(value==='hid'?'sim.source.hidHint':'sim.source.appleHint');inputs.append(b);this.sourceButtons.push(b);}
  image.append(images);input.append(inputs);this.sourceControls.append(image,input);
 }
 private syncSourceControls(){
  this.sourceControls.hidden=!this.session;this.host.dataset.imageSource=this.imageSource;this.host.dataset.inputSource=this.inputSource;this.host.dataset.hidActive=String(this.touch?.active??false);this.host.dataset.hidReady=String(this.touch?.ready??false);
  for(const b of this.sourceButtons){const selected=b.dataset.imageSource?b.dataset.imageSource===this.imageSource:b.dataset.inputSource===this.inputSource;b.setAttribute('aria-pressed',String(selected));b.disabled=this.loading||this.switchingSource||this.acting||this.benchmarking;}
  const socket=this.sourceButtons.find(b=>b.dataset.imageSource==='websocket');if(socket&&!this.socketAllowed(this.videoSocketURL??undefined)){socket.disabled=true;socket.title=t('sim.source.socketUnavailable');}
  if(this.inputSource==='hid'&&this.hidFailure)this.inputNotice.textContent=this.hidFailure;
 }
 private socketAllowed(url?:string){
  if(!url)return false;let domains:unknown;try{domains=JSON.parse(this.host.dataset.hostConnectDomains??'[]');}catch{return false;}
  return Array.isArray(domains)&&domains.some(d=>typeof d==='string'&&(url?d===new URL(url).origin:/^wss?:\/\//.test(d)));
 }
 private async changeSource(image:typeof this.imageSource,input:typeof this.inputSource){
  if(this.switchingSource||image===this.imageSource&&input===this.inputSource)return;
  this.switchingSource=true;this.update();
  try{await this.touch.cancel();this.hidFailure='';this.inputNotice.textContent='';
   if(image===this.imageSource){this.inputSource=input;this.switchingSource=false;await this.heartbeat();await this.capture();await this.prepareTouch();return;}
   this.stopDelivery();this.imageSource=image;this.inputSource=input;delete this.host.dataset.sourceFailure;await this.call('simulator_ui_video_stop',{viewerID:this.viewerID});this.switchingSource=false;await this.resume();}
  catch(error){this.message.textContent=this.error(error);}finally{this.switchingSource=false;this.update();}
 }
 private touchPreparation:Promise<void>|null=null;
 private prepareTouch(){if(this.touchPreparation)return this.touchPreparation;const preparing=this.prepareTouchOnce();this.touchPreparation=preparing;void preparing.finally(()=>{if(this.touchPreparation===preparing)this.touchPreparation=null;});return preparing;}
 private async prepareTouchOnce(){
  if(this.inputSource!=='hid'||!this.session||!this.frame||!this.visible||document.hidden||this.disposed||this.hidFailure||this.touch.active||this.inputSuspended||this.acting||this.switchingSource||this.loading||this.get().blocked||this.externalSimulatorBusy())return;
  if(this.touch.ready&&this.touch.matches(this.session.id,this.frame.width,this.frame.height,this.orientation))return;
  try{if(this.touch.ready)await this.touch.cancel();await this.touch.prepare();this.hidFailure='';delete this.host.dataset.hidFailure;}catch(error){if((error as {code?:string})?.code==='occupied')return;this.hidFailure=t('sim.source.hidUnavailable');this.host.dataset.hidFailure=String((error as {code?:string})?.code??'unavailable');}this.update();
 }
 private async touchEnded(){
  this.hidPointerEnding=false;this.frame=null;await this.heartbeat();await this.refresh();await this.capture();await this.prepareTouch();if(this.visible&&!document.hidden)this.update();
 }
 private syncCardTitle(){const name=this.cardTitle?.querySelector('.block-name');if(name)name.textContent=t('sim.v2.title');}
 private svg(name:keyof typeof icons){return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+icons[name]+'</svg>';}
 private icon(name:keyof typeof icons,label:string,action:()=>void){const button=el('button','sim-icon');button.type='button';button.title=label;button.setAttribute('aria-label',label);button.innerHTML=this.svg(name);button.onclick=action;return button;}
 private call(operation:string,args:Record<string,unknown>={}){return this.tool('simulator_ui_observe',{operation,...args});}
 private visibilityChanged=()=>{if(document.hidden){this.stopDelivery();void this.heartbeat();}else if(this.visible)void this.resume();else void this.heartbeat();};
 private resized=()=>this.fit();
 private escape=(event:KeyboardEvent)=>{if(event.key!=='Escape'||!this.visible)return;if(this.menu.open||this.picker.open){event.preventDefault();event.stopImmediatePropagation();if(this.menu.open){this.menu.open=false;this.menuList.hidden=true;this.fit();this.menu.querySelector('summary')?.focus();}else if(this.session){this.picker.open=false;this.selector.focus();}else{this.search.blur();this.cardTitle?.focus();}return;}if(this.expanded){event.preventDefault();event.stopImmediatePropagation();this.setExpanded(false);}};
 setVisible(value:boolean){value=value&&this.get().simulator?.visible===true;if(value===this.visible)return;this.visible=value;if(value)void this.resume();else{this.setExpanded(false);this.stopDelivery();void this.heartbeat();this.pendingText='';this.keyboard.value='';}this.update();}
 invalidate(){const key=JSON.stringify(this.get().context);if(key===this.contextKey)return;const xcode=this.get().context?.xcode??'',changed=xcode!==this.xcodeKey;this.contextKey=key;this.xcodeKey=xcode;this.config=null;if(this.session&&changed){void this.disconnect();}else if(this.visible)void this.load();}
 summary(){return this.session?this.title.textContent??t('sim.v2.connected'):t('sim.v2.select');}
 update(){
  this.syncCardTitle();const state=this.get().simulator;
  // Global metadata can describe another panel in the same chat. A viewer heartbeat owns this selection.
  if(state?.session&&state.session.deviceID===this.session?.deviceID&&state.session.id===this.session?.id&&Number(state.session.revision)>=Number(this.session.revision)){if(this.session?.revision!==state.session.revision){this.geometry++;this.drag=null;if(this.touch.active)void this.touch.cancel().catch(()=>{});}this.session={...state.session};}
  // Agent commands invalidate command observations, even while passive H.264 continues to arrive.
  if(this.frame&&this.frame.revision!==this.session?.revision&&!state?.busy&&!this.acting){this.geometry++;this.drag=null;this.frame=null;void this.capture(false);}
  // A post-command read can be deferred by another viewer's capture. H.264 does
  // not poll snapshots, so retry the missing observation when native becomes idle.
  if(!this.frame&&this.session&&this.mode==='video'&&this.delivering&&!state?.busy&&!this.loading&&!this.acting&&!this.benchmarking)void this.capture();
  if(this.frame&&!this.touch.ready&&!this.touch.active)void this.prepareTouch();
  const blocked=this.blocked();for(const button of [this.home,this.rotate])button.disabled=blocked;this.expand.disabled=!this.session;
  this.surface.setAttribute('aria-disabled',String(blocked||this.inputSource==='hid'&&!this.touch.ready));this.surface.tabIndex=this.session?0:-1;
  this.keyboard.setAttribute('aria-disabled',String(blocked));this.host.dataset.mode=this.mode;
  this.status.textContent=this.loading?(this.connectionStatus??t('sim.v2.connecting')):this.session?`${t('sim.v2.connected')} · ${t(this.mode==='video'?'sim.v2.video':this.mode==='snapshots'?'sim.v4.frames':'sim.v2.connecting')}`:t('sim.v2.disconnected');
  this.viewport.hidden=!this.session;for(const control of [this.home,this.rotate,this.expand,this.disconnectButton])control.hidden=!this.session;this.disconnectButton.disabled=this.acting||this.loading||this.benchmarking||state?.busy===true||this.get().blocked;this.host.dataset.connected=String(!!this.session);if(!this.session&&!this.loading)this.picker.open=true;this.selector.disabled=this.loading||this.acting||this.benchmarking;if(!this.session)this.title.textContent=t('sim.v2.choose');this.selector.title=this.session?`${this.title.textContent} · ${this.detail.textContent}`:t('sim.v2.choose');this.selector.setAttribute('aria-label',t('sim.v2.choose'));
  const busy=!!this.session&&(this.externalSimulatorBusy()||this.get().blocked||this.benchmarking);this.notice.textContent=busy?t(this.benchmarking?'sim.v4.diagnosticBusy':'sim.v4.busy'):this.session&&this.mode==='snapshots'&&this.imageSource==='auto'?t('sim.v4.fallback'):'';this.notice.dataset.kind=busy?'busy':'fallback';this.message.hidden=this.message.textContent===t('sim.v2.videoUnavailable');
  this.metrics.hidden=!this.session;if(this.mode!=='video')this.showMetrics();this.syncSourceControls();this.renderMenu();this.fit();
 }
 /** The shared queue includes this panel's own operation; it is not an agent lock. */
 ownsManualActivity(id:string){return this.manualActivityID?.toLowerCase()===id.toLowerCase();}
 private externalSimulatorBusy(){const state=this.get().simulator;if(state?.inputOwner?.toLowerCase()===this.viewerID.toLowerCase()&&this.touch.active)return false;return state?.busy===true&&(!this.manualActivityID||!state.activities?.some(a=>this.ownsManualActivity(a.id))||state.activities.some(a=>!this.ownsManualActivity(a.id)&&(['queued','preparing','running'].includes(a.status)||a.status==='unknown'&&!a.queueReleased)));}
 private blocked(){const reason=!this.visible||document.hidden?'hidden':!this.session?'noSession':!this.frame||!this.session.ready&&!this.touch.active?'observation':this.loading?'connecting':this.acting?'command':this.benchmarking?'diagnostic':this.switchingSource?'source':this.get().blocked||this.externalSimulatorBusy()?'busy':'';this.host.dataset.inputBlockedReason=reason;return !!reason;}
 private async load(){
  if(this.loading||this.disposed||this.get().simulator?.visible!==true)return;
  const context=this.get().context,key=JSON.stringify(context);this.loading=true;this.message.textContent=t('sim.v2.loadingDevices');this.update();
  try{const config=await this.call('simulator_ui_devices',{context}) as Config;if(key!==JSON.stringify(this.get().context))return;this.config=config;this.renderChoices();this.message.textContent=config.devices.length?'':t('sim.v2.noDevices');}
  catch(error){this.message.textContent=this.error(error);}finally{this.loading=false;this.update();}
  if(!this.session&&this.config){const running=this.config.devices.filter(d=>d.state==='Booted');if(running.length===1&&this.config.workspaceAuthorized)void this.connect(running[0].id);else{this.picker.open=true;if(!this.config.workspaceAuthorized)this.message.textContent=this.config.authorizationPending?t('sim.v2.awaitWorkspace'):t('sim.v2.needsWorkspace');}}
 }
 private renderChoices(){
  const query=this.search.value.trim().toLocaleLowerCase(),devices=this.config?.devices??[],recent=new Set(this.config?.recentIDs??[]);
  const selected=devices.filter(d=>query?`${this.model(d)} ${d.name} ${d.runtime} ${d.id}`.toLocaleLowerCase().includes(query):d.state==='Booted'||recent.has(d.id));
  this.choices.replaceChildren();
  if(!this.config?.workspaceAuthorized){const authorize=el('button','',t('sim.v2.chooseWorkspace'));authorize.onclick=()=>void this.authorize();this.choices.append(authorize);}
  const groups=query?[[t('sim.v3.results'),selected] as const]:[[t('sim.v3.running'),selected.filter(d=>d.state==='Booted')] as const,[t('sim.v3.recent'),selected.filter(d=>d.state!=='Booted')] as const];
  for(const [label,items] of groups){if(!items.length)continue;this.choices.append(el('h3','sim-group',label));for(const device of items){const button=el('button','sim-choice');button.type='button';button.dataset.device=device.id;const duplicate=devices.filter(d=>this.model(d)===this.model(device)&&d.name===device.name&&d.runtime===device.runtime).length>1;button.append(el('strong','',this.model(device)),el('span','',`${device.name} · ${device.runtime} · ${device.state==='Booted'?t('sim.v2.booted'):t('sim.v2.boot')}${duplicate?' · '+device.id:''}`));button.onclick=()=>void this.connect(device.id);this.choices.append(button);}}
  if(!selected.length)this.choices.append(el('p','muted',query?t('sim.v2.noMatches'):t('sim.v2.noRecent')));
 }
 private model(device:Device){return this.config?.deviceProfiles?.[device.deviceTypeIdentifier??'']?.model??device.deviceTypeIdentifier?.split('.').at(-1)?.replaceAll('-',' ')??t('sim.v2.device');}
 private async authorize(){if(this.loading)return;this.loading=true;this.message.textContent=t('sim.v2.workspacePrompt');this.update();try{this.config=await this.call('simulator_ui_authorize',{context:this.get().context});while(this.config?.authorizationPending&&!this.disposed){await new Promise(resolve=>setTimeout(resolve,500));this.config=await this.call('simulator_ui_devices',{context:this.get().context});}}catch(error){this.message.textContent=this.error(error);}finally{this.loading=false;this.config=null;await this.load();}}
 private async connect(deviceID:string,recovery=false){
  if(this.loading||this.acting||this.disposed)return;
  this.recoveredCapture=recovery;this.commandError=null;delete this.host.dataset.connectionLostCode;
  if(!this.config?.workspaceAuthorized){await this.authorize();if(!this.config?.workspaceAuthorized)return;}
  this.loading=true;this.stopDelivery();const generation=++this.generation;this.geometry++;this.frame=null;this.session=null;this.masks=null;this.surface.style.maskImage='';this.surface.style.borderRadius='';this.body.style.borderRadius='';this.connectionStatus=t('sim.v2.connecting');this.message.textContent='';this.picker.open=false;this.update();
  try{const result=await this.call('simulator_ui_attach',{viewerID:this.viewerID,deviceID,context:this.get().context,requestID:crypto.randomUUID()});this.attached=true;if(result.activity)await this.wait(result.activity.id,generation,true);if(generation!==this.generation)return;const own=await this.call('simulator_ui_viewer_heartbeat',{viewerID:this.viewerID,visible:this.visible&&!document.hidden});this.session=own.session;if(!this.session)throw new Error(t('sim.v2.missingSession'));const device=this.config?.devices.find(d=>d.id===deviceID);this.title.textContent=device?this.model(device):t('sim.v2.device');this.detail.textContent=device?`${device.name} · ${device.runtime}`:'';this.profile=this.config?.deviceProfiles?.[device?.deviceTypeIdentifier??''];this.body.className='sim-device '+(this.profile?.width?'profile':'neutral');try{const masks=await this.call('simulator_ui_masks',{viewerID:this.viewerID});if(generation!==this.generation)return;this.masks=masks;}catch{this.masks=null;}this.mode='connecting';this.message.textContent='';}
  catch(error){if(generation===this.generation)this.message.textContent=this.error(error);}finally{if(generation===this.generation){this.loading=false;this.connectionStatus=null;this.update();if(this.session&&this.visible)void this.resume();}}
 }
 /** Queue time is unbounded; only the native operation decides completion. Disconnect invalidates this wait. */
 private async wait(id:string,generation=this.generation,connecting=false){const deadline=performance.now()+90000;for(let n=0;connecting||performance.now()<deadline;n++){const result=await this.tool('get_simulator_activity',{activityID:id});if(generation!==this.generation||this.disposed)throw new Error(t('sim.v2.changed'));const activity=result.activity as SimulatorActivity;if(activity.status==='succeeded')return;if(!['queued','preparing','running'].includes(activity.status))throw new Error(activity.status==='unknown'?t('sim.v2.unknown'):activity.errorCode??t('sim.v2.commandFailed'));if(connecting){const uncertain=(result.state?.activities as SimulatorActivity[]|undefined)?.some(a=>a.id!==id&&a.status==='unknown'&&!a.queueReleased);this.connectionStatus=activity.status==='queued'?t(uncertain?'sim.v3.queueBlocked':'sim.v3.queued'):activity.status==='preparing'?t('sim.v2.connecting'):t(this.config?.devices.find(d=>d.id===activity.deviceID)?.state==='Booted'?'sim.v2.connectingDevice':'sim.v3.booting');this.update();}await new Promise(resolve=>setTimeout(resolve,connecting||activity.status==='queued'?500:Math.min(500,50*2**Math.min(n,4))));}throw new Error(t('sim.v2.commandPending'));}
 /** Visibility changes must reach native in order; a frame requested while native is hidden is rejected. */
 private heartbeat(){
  const generation=this.generation;
  const pending=this.heartbeatChain.then(async()=>{
   if(!this.attached||this.disposed||generation!==this.generation)return;
   try{
    const own=await this.call('simulator_ui_viewer_heartbeat',{viewerID:this.viewerID,visible:this.visible&&!document.hidden});
    if(generation!==this.generation||!this.attached||this.disposed)return;
    if(this.session?.id!==own.session?.id||this.session?.revision!==own.session?.revision){this.geometry++;this.drag=null;}
    this.session=own.session;this.update();
   }catch(error){
    if(generation!==this.generation||!this.attached||this.disposed)return;
    const code=(error as {code?:unknown})?.code;
    if(typeof code==='string'&&['noSession','connectionLost','invalidResponse'].includes(code)&&!this.acting&&!this.loading&&!this.benchmarking){
     if(!this.visible||document.hidden){this.stopDelivery();return;}
     void this.recoverPassive(code);return;
    }
    this.stopDelivery();this.attached=false;this.session=null;this.frame=null;this.message.textContent=t('sim.v2.connectionLost');
    this.host.dataset.connectionLostCode=typeof code==='string'&&/^[a-zA-Z][a-zA-Z0-9]{0,63}$/.test(code)?code:'unavailable';this.message.title=this.host.dataset.connectionLostCode;this.update();
   }
  });
  this.heartbeatChain=pending;return pending;
 }
 /** A host can suspend hidden timers beyond the native viewer lease. Renew a passive
  * connection once; never await this inside the heartbeat chain or replay a command. */
 private async recoverPassive(code:string){
  const deviceID=this.session?.deviceID,recover=!!deviceID&&!this.recoveredCapture&&!this.loading&&!this.acting&&!this.benchmarking;
  this.recoveredCapture=true;await this.disconnect();
  if(recover&&this.visible&&!document.hidden&&!this.disposed){await this.connect(deviceID!,true);}else{this.message.textContent=t('sim.v2.connectionLost');this.message.title=code;this.host.dataset.connectionLostCode=code;this.update();}
 }
 private async resume(){
  if(!this.visible||document.hidden||this.delivering||this.disposed)return;if(!this.session){if(!this.config)await this.load();return;}
  this.delivering=true;const epoch=++this.deliveryEpoch;await this.heartbeat();if(epoch!==this.deliveryEpoch||!this.delivering||!this.session||this.disposed||!this.visible||document.hidden)return;while(this.capturing&&epoch===this.deliveryEpoch)await new Promise(resolve=>setTimeout(resolve,30));await this.capture();if(epoch!==this.deliveryEpoch||!this.delivering)return;
  if(this.imageSource==='snapshots'){this.mode='snapshots';this.image.hidden=!this.frame;this.canvas.hidden=true;this.scheduleCapture();this.update();await this.prepareTouch();return;}
  try{const access=await this.call('simulator_ui_video',{viewerID:this.viewerID}) as VideoAccess;if(epoch!==this.deliveryEpoch||!this.delivering||!this.visible||document.hidden||this.disposed)return;this.videoSizeKey='';this.fit();this.videoSocketURL=access.url??null;this.syncSourceControls();if(this.imageSource==='websocket'&&!this.socketAllowed(access.url))throw new Error('hostConnectionUnavailable');await this.player.attach(access,this.imageSource==='websocket'?'websocket':'mcp',after=>this.call('simulator_ui_video_poll',{viewerID:this.viewerID,after,token:access.token}));}catch{if(epoch===this.deliveryEpoch)this.fallback('videoUnavailable');}
  if(epoch===this.deliveryEpoch&&this.delivering)await this.prepareTouch();
 }
 /** Explicit local diagnostic; both attempts share one helper, animation and encoded resolution. */
 private async compareVideo(durationMs=10000,transports:readonly ('websocket'|'mcp')[]=['websocket','mcp']){
  if(!this.session||!this.visible||this.benchmarking)return;
  this.stopDelivery();const epoch=this.deliveryEpoch;
  await this.heartbeat();if(!this.session||!this.visible||document.hidden||epoch!==this.deliveryEpoch)return;
  while(this.capturing&&this.visible&&epoch===this.deliveryEpoch)await new Promise(resolve=>setTimeout(resolve,30));
  await this.capture();if(!this.frame||!this.visible||epoch!==this.deliveryEpoch){void this.resume();return;}
  this.delivering=true;this.benchmarking=true;this.update();
  const results:unknown[]=[];this.videoDiagnostics.hidden=false;this.videoDiagnostics.textContent=t('sim.v3.benchmarking');
  try{
   for(const transport of transports){
    if(!this.visible||document.hidden||epoch!==this.deliveryEpoch)break;
    this.benchmarkFailure='';this.lastVideoMetrics=null;
    const access=await this.call('simulator_ui_video',{viewerID:this.viewerID}) as VideoAccess;
    if(!this.visible||document.hidden||epoch!==this.deliveryEpoch)break;
    this.mode='connecting';this.canvas.hidden=true;this.image.hidden=!this.frame;this.update();this.videoSizeKey='';this.fit();const started=performance.now();
    await this.player.attach(access,transport,after=>this.call('simulator_ui_video_poll',{viewerID:this.viewerID,after,token:access.token}));
    while(this.player.firstPaintAt===null&&!this.benchmarkFailure&&performance.now()-started<8500){if(!await this.benchmarkWait(50,epoch))break;}
    let measured=false;
    if(this.player.firstPaintAt!==null&&!this.benchmarkFailure&&await this.benchmarkWait(2000,epoch)){
     this.player.beginMeasurement();measured=await this.benchmarkWait(durationMs,epoch);
    }
    const interrupted=!this.visible||document.hidden||epoch!==this.deliveryEpoch;
    if(interrupted){this.player.stop();break;}
    this.player.stop();const metrics=this.player.metrics();
    results.push({transport,warmupMs:2000,totalDurationMs:Math.round(performance.now()-started),failure:this.benchmarkFailure||(!measured?'videoStartupTimeout':null),metrics,cspViolations:transport==='websocket'?this.player.diagnostics():[],qualified:measured&&!this.benchmarkFailure&&metrics.durationMs>=durationMs&&metrics.fps>=40&&metrics.latencySamples===metrics.frames&&metrics.p95ms!==null&&metrics.p95ms<=200});
    this.videoDiagnostics.textContent=JSON.stringify(results,null,2);
   }
  }catch(error){this.videoDiagnostics.textContent=this.error(error);}
  finally{this.benchmarking=false;if(this.visible&&epoch===this.deliveryEpoch){this.stopDelivery();void this.resume();}this.update();}
 }
 private async probeSecureVideo(){
  this.secureProbe?.abort();const controller=new AbortController();this.secureProbe=controller;
  this.videoDiagnostics.hidden=false;this.videoDiagnostics.textContent=t('sim.v3.benchmarking');
  const result=await probeSecureVideoSocket(controller.signal);
  if(this.secureProbe===controller&&!controller.signal.aborted&&!this.disposed){this.videoDiagnostics.textContent=JSON.stringify(result,null,2);this.secureProbe=null;}
 }
 /** Hidden or replaced viewers never complete a qualification window. */
 private async benchmarkWait(milliseconds:number,epoch:number){
  const deadline=performance.now()+milliseconds;
  while(performance.now()<deadline){
   if(!this.visible||document.hidden||this.disposed||epoch!==this.deliveryEpoch||this.benchmarkFailure)return false;
   await new Promise(resolve=>setTimeout(resolve,Math.min(50,Math.max(1,deadline-performance.now()))));
  }
  return this.visible&&!document.hidden&&!this.disposed&&epoch===this.deliveryEpoch&&!this.benchmarkFailure;
 }
 private fallback(reason:string){if(!this.visible||document.hidden||!this.delivering)return;if(this.imageSource!=='auto'){this.player.stop();this.mode='connecting';this.canvas.hidden=true;this.image.hidden=true;this.message.hidden=false;this.message.textContent=t('sim.source.unavailable');this.message.title=reason;this.host.dataset.sourceFailure=reason;this.update();return;}void this.call('simulator_ui_video_stop',{viewerID:this.viewerID}).catch(()=>{});this.mode='snapshots';this.canvas.hidden=true;this.image.hidden=!this.frame;this.message.textContent=this.commandError??t('sim.v2.videoUnavailable');this.message.title=reason;this.update();this.scheduleCapture();}
 private scheduleCapture(){if(this.snapshotTimer)clearTimeout(this.snapshotTimer);if(this.delivering&&this.mode==='snapshots')this.snapshotTimer=setTimeout(async()=>{await this.capture();this.scheduleCapture();},350);}
 private capturing=false;
 private async capture(refresh=true){if(this.capturing||this.touch?.active||!this.attached||!this.visible||document.hidden||this.acting||this.get().simulator?.busy)return;this.capturing=true;const requested=performance.now();const epoch=this.deliveryEpoch,generation=this.generation;
  try{const frame=await this.call('simulator_ui_frame',{viewerID:this.viewerID,refresh}) as Frame;if(generation!==this.generation||epoch!==this.deliveryEpoch||!this.visible)return;
   if(frame.sessionID!==this.session?.id||frame.mimeType!=='image/jpeg'||!Number.isFinite(frame.width)||!Number.isFinite(frame.height)||frame.width<=0||frame.height<=0)throw new Error(t('sim.v2.invalidFrame'));
   if(this.frame&&(frame.width!==this.frame.width||frame.height!==this.frame.height||frame.revision!==this.frame.revision)){this.geometry++;this.drag=null;}
   const image=new Image();image.src='data:image/jpeg;base64,'+frame.image;await image.decode();if(generation!==this.generation||epoch!==this.deliveryEpoch||!this.visible)return;
   if(this.mode!=='video'){await new Promise<void>(resolve=>requestAnimationFrame(()=>resolve()));if(generation!==this.generation||epoch!==this.deliveryEpoch||!this.visible)return;this.snapshotStart||=requested;this.snapshotCount++;this.snapshotLatencies.push(performance.now()-requested);if(this.snapshotLatencies.length>120)this.snapshotLatencies.shift();}this.frame=frame;this.session.revision=frame.revision;this.session.ready=true;if(frame.width>frame.height&&!this.orientation.startsWith('landscape'))this.orientation='landscapeLeft';else if(frame.height>frame.width&&this.orientation.startsWith('landscape'))this.orientation='portrait';this.image.src=image.src;this.image.hidden=this.mode==='video'||!!this.host.dataset.sourceFailure&&this.imageSource!=='auto';void this.prepareTouch();this.message.textContent=this.commandError??(this.host.dataset.sourceFailure&&this.imageSource!=='auto'?t('sim.source.unavailable'):this.mode==='snapshots'&&this.imageSource==='auto'?t('sim.v2.videoUnavailable'):'');this.update();
  }catch(error){if(generation===this.generation&&epoch===this.deliveryEpoch&&this.visible){const code=error instanceof Error&&'code'in error?String(error.code):'';if(['noSession','connectionLost','invalidResponse'].includes(code)){
    await this.recoverPassive(code);
   }else if(!this.get().simulator?.busy)this.message.textContent=this.error(error);}}finally{this.capturing=false;}
 }
 private stopDelivery(){void this.touch?.cancel().catch(()=>{});this.secureProbe?.abort();this.secureProbe=null;this.deliveryEpoch++;this.delivering=false;this.player.stop();this.snapshotCount=0;this.snapshotStart=0;this.snapshotLatencies=[];if(this.snapshotTimer)clearTimeout(this.snapshotTimer);this.snapshotTimer=null;this.drag=null;this.frame=null;this.clearWheel();this.player.freeze(false);}
 private async command(action:Record<string,unknown>,allowText=false){
  if(this.inputSuspended)return false;
  // Keep observations fresh without starting a helper between cancellation and Apple admission.
  this.inputSuspended=true;try{
  if(this.touch?.active||action.type==='orientation'&&this.inputSource==='hid'){try{await this.touch.cancel();await this.heartbeat();await this.capture();}catch{return false;}}
  if(this.blocked())return false;const keepFocus=document.activeElement===this.keyboard||document.activeElement===this.surface;const original=this.frame!,session=this.session!,revision=original.revision,generation=this.generation,epoch=this.deliveryEpoch,started=performance.now();let succeeded=false;
  this.acting=true;this.manualActivityID=crypto.randomUUID();this.commandError=null;this.host.dataset.lastActionStatus='pending';delete this.host.dataset.lastActionCode;this.pendingText=allowText?this.pendingText:'';this.update();
  try{const activity=await this.call('simulator_ui_viewer_action',{viewerID:this.viewerID,revision,requestID:this.manualActivityID,action});if(generation!==this.generation)return false;if(!activity||typeof activity.id!=='string')throw new Error(t('sim.v2.commandFailed'));this.manualActivityID=activity.id;await this.wait(activity.id,generation);if(generation!==this.generation)return false;if(action.type==='orientation'){this.orientation=String(action.orientation);this.geometry++;this.drag=null;}await this.heartbeat();if(generation!==this.generation)return false;this.frame=null;this.host.dataset.lastActionStatus='succeeded';this.host.dataset.manualCompletionMs=String(performance.now()-started);succeeded=true;return true;}
  catch(error){if(generation===this.generation){this.commandError=this.error(error);this.message.textContent=this.commandError;this.host.dataset.lastActionStatus='failed';const code=(error as {code?:unknown})?.code;this.host.dataset.lastActionCode=typeof code==='string'&&/^[a-zA-Z][a-zA-Z0-9]{0,63}$/.test(code)?code:'unavailable';}return false;}finally{if(generation===this.generation){await this.refresh();if(generation===this.generation){this.acting=false;await this.capture(false);this.manualActivityID=null;
    // Only our confirmed scroll may rebase recent coalesced motion onto its fresh observation.
    if(this.wheelCommand&&this.wheel){if(succeeded&&epoch===this.deliveryEpoch&&this.session?.id===session.id&&this.frame?.revision===revision+1&&this.frame.width===original.width&&this.frame.height===original.height&&performance.now()-this.wheel.at<=200){this.wheel.geometry=this.geometry;this.wheel.revision=this.frame.revision;}else this.clearWheel();}
    this.update();if(keepFocus&&this.visible&&document.activeElement===document.body)this.keyboard.focus({preventScroll:true});}}}
  }finally{this.inputSuspended=false;void this.prepareTouch();}
 }
 /** Retain focused buttons during polling; refresh only their availability. */
 private renderMenu(){
  if(!this.menuChecks.length){
   const close=()=>{this.menu.open=false;this.menuList.hidden=true;this.menu.querySelector('summary')?.focus();};
   const item=(label:string,action:()=>void,disabled:()=>boolean,target=this.menuList)=>{const button=el('button','',label);button.type='button';button.onclick=()=>{if(disabled())return;if(target===this.menuList)close();action();};target.append(button);this.menuChecks.push(()=>{button.disabled=disabled();});};
   this.expand.textContent=t('sim.v2.expand');this.expand.onclick=()=>{close();this.setExpanded(!this.expanded);};this.menuList.append(this.expand);
   item(t('sim.v2.install'),()=>void this.install(),()=>!this.session||!this.get().context||this.blocked());item(t('sim.v2.reconnect'),()=>{const id=this.session?.deviceID;if(id)void this.connect(id);},()=>!this.session||this.loading||this.acting||this.benchmarking);item(t('sim.v2.refresh'),()=>void this.capture(),()=>!this.session||this.blocked());
   for(const [value,label]of [['portrait',t('sim.v2.portrait')],['landscapeLeft',t('sim.v2.landscapeLeft')],['landscapeRight',t('sim.v2.landscapeRight')],['portraitUpsideDown',t('sim.v2.upsideDown')]])item(label,()=>void this.command({type:'orientation',orientation:value}),()=>this.blocked());
   item(t('sim.v2.refreshDevices'),()=>{this.config=null;void this.load();},()=>this.loading||this.acting);item(t('sim.v2.workspace'),()=>void this.authorize(),()=>this.loading||this.acting);
   const diagnosticBlocked=()=>!this.session||this.loading||this.acting||this.benchmarking;
   item(t('sim.v3.compareVideo'),()=>void this.compareVideo(),diagnosticBlocked,this.diagnosticActions);
   item(t('sim.v3.longMCPVideo'),()=>void this.compareVideo(90000,['mcp']),diagnosticBlocked,this.diagnosticActions);
   item(t('sim.v3.probeWSS'),()=>void this.probeSecureVideo(),()=>this.benchmarking||this.secureProbe!==null,this.diagnosticActions);
  }
  for(const check of this.menuChecks)check();
 }
 private async install(){if(this.blocked()||!this.session||!this.get().context)return;this.acting=true;this.update();try{const activity=await this.tool('install_simulator_app',{context:this.get().context,sessionID:this.session.id,requestID:crypto.randomUUID()});await this.wait(activity.id);await this.heartbeat();this.frame=null;}catch(error){this.message.textContent=this.error(error);}finally{this.acting=false;await this.refresh();await this.capture(false);this.update();}}
 private async disconnect(){this.generation++;this.loading=false;this.connectionStatus=null;this.stopDelivery();this.geometry++;this.session=null;this.frame=null;this.image.hidden=true;this.canvas.hidden=true;if(this.attached){this.attached=false;try{await this.call('simulator_ui_detach',{viewerID:this.viewerID});}catch{}}this.title.textContent=t('sim.v2.title');this.detail.textContent='';this.profile=undefined;this.message.textContent='';this.update();}
 private videoLabel(){return t(this.canvas.dataset.videoTransport==='mcp'?'sim.v3.videoMCP':'sim.v3.videoWebSocket');}
 private showMetrics(metrics?:VideoMetrics){if(!this.session){this.metrics.textContent=t('sim.v2.disconnected')+' · — FPS · — мс';return;}const sorted=[...this.snapshotLatencies].sort((a,b)=>a-b),fps=metrics?(metrics.frames>=30?metrics.fps:null):(this.snapshotCount>=3?this.snapshotCount/Math.max(.001,(performance.now()-this.snapshotStart)/1000):null),latency=metrics?.p95ms??(sorted.length>=3?sorted[Math.ceil(sorted.length*.95)-1]:null);this.metrics.textContent=`${this.mode==='video'?this.videoLabel():this.session?t('sim.v2.snapshots'):t('sim.v2.disconnected')} · ${fps!==null&&Number.isFinite(fps)?fps.toFixed(1):'—'} FPS · ${metrics?'≈ p95':t('sim.v3.requestPaint')} ${latency===null?'—':Math.round(latency)+' мс'}`;}
 private fit(){if(!this.frame)return;const mask=this.masks?.[this.orientation];this.surface.style.maskImage=mask?`url(data:image/png;base64,${mask})`:'';this.surface.style.maskSize='100% 100%';const style=getComputedStyle(this.body),borderX=parseFloat(style.borderLeftWidth)+parseFloat(style.borderRightWidth),borderY=parseFloat(style.borderTopWidth)+parseFloat(style.borderBottomWidth),chrome=Array.from(this.host.children).filter(child=>child!==this.viewport&&!child.hasAttribute('hidden')).reduce((total,child)=>{const css=getComputedStyle(child);return total+(child as HTMLElement).offsetHeight+(parseFloat(css.marginTop)||0)+(parseFloat(css.marginBottom)||0);},0),available=Math.max(120,Math.min(680,innerHeight-chrome-(this.expanded?32:64))),width=Math.max(80,this.viewport.clientWidth-24-borderX),scale=Math.min(width/this.frame.width,(available-24-borderY)/this.frame.height);const radii=this.profile?.radii;if(radii?.length===4){const oriented=this.orientation==='landscapeLeft'?[radii[1],radii[2],radii[3],radii[0]]:this.orientation==='landscapeRight'?[radii[3],radii[0],radii[1],radii[2]]:this.orientation==='portraitUpsideDown'?[radii[2],radii[3],radii[0],radii[1]]:radii;this.surface.style.borderRadius=oriented.map(r=>Math.max(0,r*scale)+'px').join(' ');this.body.style.borderRadius=oriented.map(r=>Math.max(0,r*scale)+5+'px').join(' ');}this.body.style.width=Math.max(1,this.frame.width*scale)+'px';this.body.style.height=Math.max(1,this.frame.height*scale)+'px';this.viewport.style.height=Math.min(available,this.frame.height*scale+borderY+24)+'px';if(this.delivering&&this.config?.capabilities){const width=Math.max(2,Math.min(4096,Math.ceil(this.surface.clientWidth*devicePixelRatio))),height=Math.max(2,Math.min(4096,Math.ceil(this.surface.clientHeight*devicePixelRatio))),key=width+'x'+height;if(key!==this.videoSizeKey){this.videoSizeKey=key;this.host.dataset.videoRequestedSize=key;void this.call('simulator_ui_video_size',{viewerID:this.viewerID,width,height}).then(()=>{delete this.host.dataset.videoSizeFailure;}).catch(error=>{if(this.videoSizeKey===key)this.videoSizeKey='';this.host.dataset.videoSizeFailure=this.error(error);});}}}
 private setExpanded(value:boolean){if(value===this.expanded)return;this.expanded=value;this.host.classList.toggle('sim-maximized',value);this.expand.title=value?t('sim.v2.shrink'):t('sim.v2.expand');this.expand.textContent=this.expand.title;this.expand.setAttribute('aria-label',this.expand.title);this.expand.setAttribute('aria-pressed',String(value));if(value){this.previousFocus=document.activeElement as HTMLElement;let node:HTMLElement|null=this.host;while(node?.parentElement){for(const sibling of Array.from(node.parentElement.children))if(sibling!==node&&sibling instanceof HTMLElement&&!sibling.inert){sibling.inert=true;this.isolated.push(sibling);}node=node.parentElement;}this.surface.focus({preventScroll:true});}else{for(const sibling of this.isolated)sibling.inert=false;this.isolated=[];this.previousFocus?.focus({preventScroll:true});}this.fit();}
 // MARK: - Image-relative gestures and committed text input
 private point(x:number,y:number,rect=this.surface.getBoundingClientRect()){const frame=this.frame!;return{x:Math.max(0,Math.min(frame.width-.01,(x-rect.left)/rect.width*frame.width)),y:Math.max(0,Math.min(frame.height-.01,(y-rect.top)/rect.height*frame.height))};}
 private hidPointerEnding=false;
 private focusInput=()=>{if(this.visible&&!document.hidden)void this.touchEnded();};
 private blurInput=()=>{if(this.touch.active)void this.touch.cancel().then(()=>this.touchEnded()).catch(()=>{});this.drag=null;this.clearWheel();this.player.freeze(false);};
 private bindInput(){
  this.surface.onpointerdown=event=>{if(this.inputSource==='hid'){if(event.button!==0||this.blocked()||!this.touch.ready||this.touch.active)return;event.preventDefault();this.keyboard.focus({preventScroll:true});this.hidPointerEnding=false;if(this.touch.down({...this.point(event.clientX,event.clientY),timestamp:event.timeStamp}))this.surface.setPointerCapture(event.pointerId);return;}if(event.button!==0||this.blocked())return;event.preventDefault();this.keyboard.focus({preventScroll:true});this.drag={pointer:event.pointerId,x:event.clientX,y:event.clientY,time:performance.now(),geometry:this.geometry,revision:this.frame!.revision,rect:this.surface.getBoundingClientRect()};this.surface.setPointerCapture(event.pointerId);this.player.freeze(true);};
  this.surface.onpointermove=event=>{if(this.inputSource==='hid'&&this.surface.hasPointerCapture(event.pointerId))this.touch.move({...this.point(event.clientX,event.clientY),timestamp:event.timeStamp});};
  this.surface.onpointercancel=()=>{if(this.touch.active)void this.touch.cancel().then(()=>this.touchEnded()).catch(()=>{});this.drag=null;this.player.freeze(false);};this.surface.onlostpointercapture=()=>{if(this.touch.active&&!this.hidPointerEnding)void this.touch.cancel().then(()=>this.touchEnded()).catch(()=>{});this.drag=null;this.player.freeze(false);};
  this.surface.onpointerup=event=>{if(this.inputSource==='hid'){this.hidPointerEnding=true;this.touch.up({...this.point(event.clientX,event.clientY),timestamp:event.timeStamp});return;}const drag=this.drag;this.drag=null;this.player.freeze(false);if(!drag||drag.pointer!==event.pointerId||drag.geometry!==this.geometry||drag.revision!==this.frame?.revision||this.blocked())return;const start=this.point(drag.x,drag.y,drag.rect),end=this.point(event.clientX,event.clientY,drag.rect);void this.command(Math.hypot(event.clientX-drag.x,event.clientY-drag.y)<6?{type:'tap',...end}:{type:'swipe',...start,endX:end.x,endY:end.y,duration:Math.max(.05,Math.min(2,(performance.now()-drag.time)/1000))});};
  this.surface.addEventListener('wheel',event=>{
   if(event.ctrlKey)return;
   if(this.inputSource==='hid'){if(this.blocked()||!this.touch.ready)return;event.preventDefault();const rect=this.surface.getBoundingClientRect(),frame=this.frame!,factor=event.deltaMode===1?16:event.deltaMode===2?rect.height:1;this.touch.wheel({...this.point(event.clientX,event.clientY),timestamp:event.timeStamp},event.deltaX*factor/rect.width*frame.width,event.deltaY*factor/rect.height*frame.height);return;}
   const canAccumulate=this.wheelCommand&&this.acting&&this.visible&&!document.hidden&&this.frame&&!this.loading&&!this.benchmarking&&!this.get().blocked&&!this.externalSimulatorBusy();
   if(!canAccumulate&&this.blocked()){this.clearWheel();return;}event.preventDefault();
   const frame=this.frame!,rect=this.surface.getBoundingClientRect(),point=this.point(event.clientX,event.clientY),factor=event.deltaMode===1?16:event.deltaMode===2?rect.height:1,now=performance.now();
   if(!this.wheel||now-this.wheel.at>200)this.wheel={...point,dx:0,dy:0,geometry:this.geometry,revision:frame.revision,at:now};
   // Keep one current remainder, bounded to less than a screen. Never queue wheel commands.
   this.wheel.dx=Math.max(-frame.width*.45,Math.min(frame.width*.45,this.wheel.dx+event.deltaX*factor/rect.width*frame.width));this.wheel.dy=Math.max(-frame.height*.45,Math.min(frame.height*.45,this.wheel.dy+event.deltaY*factor/rect.height*frame.height));this.wheel.at=now;
   if(!this.wheelCommand&&!this.wheelTimer)void this.flushWheel();
  },{passive:false});
  this.keyboard.addEventListener('compositionstart',()=>{this.composing=true;});this.keyboard.addEventListener('compositionend',()=>{this.composing=false;this.collectText();});this.keyboard.oninput=()=>{if(!this.composing)this.collectText();};
  this.keyboard.onpaste=event=>{event.preventDefault();if(this.blocked())return;this.enqueueText(event.clipboardData?.getData('text/plain')??'');};
  this.keyboard.onkeydown=event=>{if(event.isComposing||this.composing||event.key==='Tab')return;const key=({Backspace:'backspace',Enter:'return',Delete:'forwardDelete'} as Record<string,string>)[event.key];if(key){event.preventDefault();if(!this.config?.capabilities?.keys.includes(key)){this.inputNotice.textContent=t('sim.v2.unsupportedKey').replace('{key}',event.key);return;}if(this.blocked())return;this.inputNotice.textContent='';this.inputChain=this.inputChain.then(async()=>{await this.flushTextNow();if(!this.blocked())await this.command({type:'key',key},true);});}else if(event.key.startsWith('Arrow')||event.key==='Home'||event.key==='End'){event.preventDefault();this.inputNotice.textContent=t('sim.v2.unsupportedKey').replace('{key}',event.key);}};
 }
 /** Immediate leading dispatch; only the next bounded remainder waits one frame. */
 private async flushWheel(){
  this.wheelTimer=null;const wheel=this.wheel;this.wheel=null;
  if(!wheel||performance.now()-wheel.at>200||wheel.geometry!==this.geometry||wheel.revision!==this.frame?.revision||this.blocked())return;
  const frame=this.frame!,endX=Math.max(0,Math.min(frame.width-.01,wheel.x-wheel.dx)),endY=Math.max(0,Math.min(frame.height-.01,wheel.y-wheel.dy));if(Math.hypot(endX-wheel.x,endY-wheel.y)<.01)return;
  this.host.dataset.wheelDispatchMs=String(performance.now()-wheel.at);this.wheelCommand=true;
  try{if(!await this.command({type:'swipe',x:wheel.x,y:wheel.y,endX,endY,duration:.08}))this.clearWheel();}
  finally{this.wheelCommand=false;if(this.wheel&&!this.blocked())this.wheelTimer=setTimeout(()=>void this.flushWheel(),16);else this.clearWheel();}
 }
 private clearWheel(){this.wheel=null;if(this.wheelTimer)clearTimeout(this.wheelTimer);this.wheelTimer=null;}
 private collectText(){const text=this.keyboard.value;this.keyboard.value='';this.enqueueText(text);}
 private enqueueText(text:string){if(!text||this.blocked())return;if(new TextEncoder().encode(this.pendingText+text).length>1_048_576){this.message.textContent=t('sim.v2.pasteTooLarge');return;}this.pendingText+=text;if(this.textTimer)clearTimeout(this.textTimer);this.textTimer=setTimeout(()=>void this.flushText(),250);}
 private async flushText(){this.inputChain=this.inputChain.then(()=>this.flushTextNow());await this.inputChain;}
 private async flushTextNow(){if(this.composing||this.blocked()){this.pendingText='';return;}const text=this.pendingText;this.pendingText='';const generation=this.generation;for(const chunk of textChunks(text)){if(generation!==this.generation||this.blocked())break;if(!await this.command({type:'text',text:chunk},true))break;}}
 private error(error:unknown){return error instanceof Error?error.message:t('sim.v2.connectionFailed');}
 async dispose(){this.disposed=true;this.resizeObserver.disconnect();this.setExpanded(false);clearInterval(this.heartbeatTimer);if(this.textTimer)clearTimeout(this.textTimer);window.removeEventListener('focus',this.focusInput);window.removeEventListener('blur',this.blurInput);document.removeEventListener('visibilitychange',this.visibilityChanged);window.removeEventListener('keydown',this.escape,true);window.removeEventListener('resize',this.resized);await this.disconnect();}
}
