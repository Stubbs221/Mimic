// Created by Василий Маслов on 07.10.2026.
export type BranchOperation={id:string;checkout:string;sourceBranch:string;targetBranch:string;phase:string;holdsCheckout:boolean;delivery:string;ownerThreadID?:string|null;stashName?:string|null;stashSHA?:string|null;error?:string|null};
type BranchState={context:{checkoutId:string}|null;branchRebase?:boolean;branchSwitch?:BranchOperation|null;checkoutLocked?:boolean};
type Dependencies={tool:(name:string,args?:Record<string,unknown>)=>Promise<any>;t:(key:string)=>string;refresh:()=>Promise<void>;canSend:()=>boolean;send:(prompt:string)=>Promise<unknown>;open:(url:string)=>Promise<unknown>;error:(error:unknown)=>void;preview:boolean};

/** DOM identity survives polling; a native reservation prevents two panels from sending the same handoff. */
export class BranchSwitchPanel {
 readonly preference=document.createElement('label');
 readonly checkbox=document.createElement('input');
 readonly status=document.createElement('div');
 private readonly text=document.createElement('span');
 private readonly detail=document.createElement('span');
 private readonly backup=document.createElement('span');
 private readonly openButton=document.createElement('button');
 private readonly cancelButton=document.createElement('button');
 private state:BranchState={context:null};
 private polling=false;
 private saving=false;
 constructor(private readonly dependencies:Dependencies){
  const {t}=dependencies;
  this.preference.className='branch-rebase';this.preference.title=t('branch.rebase.help');
  this.checkbox.type='checkbox';this.checkbox.setAttribute('aria-label',t('branch.rebase'));this.checkbox.dataset.action='branch-rebase';
  this.preference.append(this.checkbox,document.createTextNode(t('branch.rebase')));
  this.checkbox.onchange=()=>void this.savePreference();
  this.status.className='branch-progress';this.status.setAttribute('role','status');
  this.openButton.type=this.cancelButton.type='button';this.openButton.className=this.cancelButton.className='quiet';
  this.openButton.textContent=t('branch.codex.open');
  this.openButton.onclick=()=>{const thread=this.state.branchSwitch?.ownerThreadID;if(thread)void dependencies.open('codex://threads/'+encodeURIComponent(thread)).catch(dependencies.error);};
  this.cancelButton.onclick=()=>{const op=this.state.branchSwitch;if(op)void dependencies.tool('panel_cancel_branch_switch',{operationID:op.id}).then(dependencies.refresh).catch(dependencies.error);};
  this.backup.className='branch-backup';this.detail.className='muted';
  this.status.append(this.text,this.openButton,this.cancelButton,this.detail,this.backup);
 }
 update(state:BranchState,busy=false){
  this.state=state;this.checkbox.checked=!!state.branchRebase;this.checkbox.disabled=!state.context||!!state.checkoutLocked||busy||this.saving;
  const op=state.branchSwitch;
  this.status.hidden=!op||op.phase==='succeeded'&&!op.stashSHA;
  if(!op)return;
  this.status.dataset.phase=op.phase;this.text.textContent=this.dependencies.t('branch.phase.'+op.phase);
  this.detail.textContent=[op.phase==='awaitingAgent'?this.dependencies.t('branch.delivery.'+op.delivery):'',op.error].filter(Boolean).join(' · ');
  this.detail.hidden=!this.detail.textContent;
  this.openButton.hidden=!op.ownerThreadID;
  this.cancelButton.hidden=!op.holdsCheckout||!!op.ownerThreadID&&op.phase!=='needsReview';
  this.cancelButton.disabled=busy;this.cancelButton.textContent=this.dependencies.t(op.phase==='needsReview'?'branch.review.acknowledge':'cancel');
  this.backup.hidden=!op.stashName;this.backup.textContent=op.stashName?this.dependencies.t('branch.stash.backup')+' '+op.stashName:'';this.backup.title=op.stashName??'';
 }
 private async savePreference(){
  if(this.saving)return;
  this.saving=true;const enabled=this.checkbox.checked;this.checkbox.disabled=true;
  try{await this.dependencies.tool('panel_branch_preferences',{context:this.state.context,enabled});await this.dependencies.refresh();}
  catch(error){this.dependencies.error(error);}
  finally{this.saving=false;this.update(this.state);}
 }
 async poll(){
  if(this.polling||this.dependencies.preview||!this.state.context)return;
  this.polling=true;
  try{
   await this.dependencies.tool('panel_branch_heartbeat',{canSend:this.dependencies.canSend()&&document.visibilityState==='visible'});
   if(!this.dependencies.canSend())return;
   const handoff=await this.dependencies.tool('panel_branch_delivery');
   if(!handoff?.operationID)return;
   let sent=false;
   try{const result=await this.dependencies.send(handoff.prompt) as {isError?:boolean}|undefined;if(result?.isError)throw new Error(this.dependencies.t('branch.delivery.unknown'));sent=true;}
   finally{await this.dependencies.tool('panel_branch_delivery_result',{operationID:handoff.operationID,sent});}
  }catch(error){this.dependencies.error(error);}
  finally{this.polling=false;}
 }
}
