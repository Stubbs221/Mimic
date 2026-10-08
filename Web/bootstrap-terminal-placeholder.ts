// Created by Василий Маслов on 08.10.2026.
export type BootstrapPlaceholderState='idle'|'queued'|'running'|'unavailable'|null;
export type BootstrapPlaceholderLabels={example:string;queued:string;waiting:string;unavailable:string};

/** A presentation layer, never written to xterm or included in task output. */
export class BootstrapTerminalPlaceholder {
 readonly host=document.createElement('div');
 private content=document.createElement('div');
 private header=document.createElement('div');
 private sample=document.createElement('div');
 private state=document.createElement('div');
 private observer:ResizeObserver;
 private signature='';
 constructor(private labels:BootstrapPlaceholderLabels){
  this.host.className='bootstrap-placeholder';this.content.className='bootstrap-placeholder-content';
  this.header.className='bootstrap-placeholder-header';this.header.textContent='BOOTSTRAP / TERMINAL · '+labels.example;
  this.sample.className='bootstrap-placeholder-sample';this.sample.setAttribute('aria-hidden','true');
  this.state.className='bootstrap-placeholder-state';this.host.setAttribute('role','status');
  this.content.append(this.header,this.sample,this.state);this.host.append(this.content);
  this.observer=new ResizeObserver(()=>this.layout());this.observer.observe(this.host);
 }
 update(state:BootstrapPlaceholderState,platform:'ios'|'tvos'){
  const signature=`${state}-${platform}`;if(this.signature===signature){this.layout();return;}this.signature=signature;
  this.host.hidden=state===null;
  const example=state==='idle'||state==='unavailable';this.header.hidden=this.sample.hidden=!example;
  this.sample.textContent=`$ mimic bootstrap ${platform}\n✓ Dependencies ready\n› Waiting for launch`;
  const message=state==='queued'?this.labels.queued:state==='running'?this.labels.waiting:state==='unavailable'?this.labels.unavailable:'';
  this.state.textContent=message;this.state.hidden=!message;
  this.host.setAttribute('aria-label',[example?this.labels.example:'',message].filter(Boolean).join('. '));
  this.layout();
 }
 private layout(){
  if(this.host.hidden||!this.host.clientHeight)return;
  // Reduce decoration before sacrificing the real state, including with enlarged text.
  for(const density of ['full','command','label','state']){
   this.host.dataset.density=density;
   if(this.content.scrollHeight<=this.host.clientHeight-24)break;
  }
 }
 dispose(){this.observer.disconnect();}
}
