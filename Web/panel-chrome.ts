// Created by Василий Маслов on 08.10.2026.
type Context={checkoutId:string;branch:string;sha:string;xcode:string;profileID:string|null;profileRevision:string|null};
type Activity={type:'task'|'build'|'run';id:string;title:string;status:string;needsInput?:boolean};
type Presentation={tiled:boolean;context:Context|null;busy:boolean;locked:boolean;stale:boolean;editing:boolean;rebase:boolean;catalogOpen:boolean;historyOpen:boolean;activity:Activity|null;progress?:string;needsBinding?:boolean};
type Dependencies={t:(key:string)=>string;preference:HTMLElement;branches:()=>void;switchBranch:(branch:string)=>void;refresh:()=>void;newAction:()=>void;history:()=>void;edit:()=>void;setup:(operation:string)=>void;bind:()=>void;select:(activity:Activity)=>void};
type Popup='branches'|'context'|'settings'|'menu';

function node<K extends keyof HTMLElementTagNameMap>(tag:K,className='',text=''){const n=document.createElement(tag);n.className=className;n.textContent=text;return n;}
function icon(name:string){const n=node('span','chrome-icon chrome-icon-'+name);n.setAttribute('aria-hidden','true');return n;}

/** C1 owns presentation only. Existing panel handlers retain task, checkout and request identities. */
export class PanelChrome {
 readonly host=node('section','panel-chrome');
 private readonly identity=node('button','chrome-project');
 private readonly project=node('span','chrome-project-name');
 private readonly branch=node('button','chrome-branch');
 private readonly branchName=node('span','chrome-branch-name');
 private readonly rebase=node('span','chrome-rebase','R');
 private readonly actions=node('div','chrome-actions');
 private readonly status=node('button','chrome-status');
 private readonly popup=node('section','chrome-popover');
 private readonly popupBody=node('div','chrome-popover-body');
 private readonly popupTitle=node('h2');
 private readonly search=node('input','chrome-branch-search');
 private readonly select=node('select');
 private readonly switchButton:HTMLButtonElement;
 private readonly branchBody=node('div','chrome-branch-picker');
 private readonly actionButton:HTMLButtonElement;
 private readonly historyButton:HTMLButtonElement;
 private readonly settingsButton:HTMLButtonElement;
 private readonly menuButton:HTMLButtonElement;
 private state:Presentation|null=null;
 private opened:Popup|null=null;
 private trigger:HTMLButtonElement|null=null;
 private branchList:string[]=[];
 private contextSignature='';
 private branchContext='';

 constructor(private readonly dependencies:Dependencies){
  const {t}=dependencies;
  const heading=node('h1','chrome-identity'),row=node('div','chrome-row');
  this.identity.type='button';this.identity.append(node('span','chrome-brand',t('title')),this.project);heading.append(this.identity);
  this.identity.onclick=()=>this.toggle('context',this.identity);
  this.identity.setAttribute('aria-label',t('context.details'));this.identity.title=t('context.details');
  this.branch.type='button';this.branch.append(icon('branch'),this.branchName,icon('chevron'),this.rebase);
  this.branch.setAttribute('aria-label',t('branch.local'));this.branch.onclick=dependencies.branches;
  this.rebase.title=t('branch.rebase');this.rebase.setAttribute('aria-label',t('branch.rebase'));
  this.actionButton=this.iconButton('plus',t('newAction'),()=>{this.close(false);dependencies.newAction();});
  this.historyButton=this.iconButton('history',t('history'),()=>{this.close(false);dependencies.history();});
  this.settingsButton=this.iconButton('gear',t('settings'),()=>this.toggle('settings',this.settingsButton));
  this.menuButton=this.iconButton(null,t('chrome.menu'),()=>this.toggle('menu',this.menuButton));
  this.menuButton.textContent='⋯';this.menuButton.classList.add('chrome-more');
  this.actions.append(this.actionButton,this.historyButton,this.settingsButton,this.menuButton);
  row.append(heading,this.branch,this.actions);
  this.status.type='button';this.status.onclick=()=>{if(this.state?.activity)dependencies.select(this.state.activity);};
  const live=node('div','chrome-status-region');live.setAttribute('role','status');live.append(this.status);
  this.popup.id='mimic-chrome-popover';this.popup.hidden=true;this.popup.setAttribute('role','region');
  const popupHeader=node('div','chrome-popover-heading'),close=this.textButton(t('chrome.close'),()=>this.close());
  close.classList.add('chrome-close');close.textContent='×';close.setAttribute('aria-label',t('chrome.close'));
  popupHeader.append(this.popupTitle,close);this.popup.append(popupHeader,this.popupBody);
  for(const button of [this.identity,this.branch,this.settingsButton,this.menuButton]){button.setAttribute('aria-controls',this.popup.id);button.setAttribute('aria-expanded','false');}
  this.host.append(row,live,this.popup);this.host.hidden=true;
  this.search.type='search';this.search.placeholder=t('search');this.search.setAttribute('aria-label',t('branch.search'));
  this.search.oninput=()=>this.renderBranches();this.select.setAttribute('aria-label',t('branch.local'));
  this.select.onchange=()=>this.updateSwitch();
  this.switchButton=this.textButton(t('branch.switch'),()=>dependencies.switchBranch(this.select.value));
  this.switchButton.className='primary';this.switchButton.dataset.action='branch-switch';
  this.branchBody.append(this.search,this.select,dependencies.preference,this.switchButton);
  // Capture Escape before the grid's window handler, preserving an active layout draft.
  window.addEventListener('keydown',event=>{if(event.key==='Escape'&&this.opened){event.preventDefault();event.stopImmediatePropagation();this.close();}},true);
  document.addEventListener('pointerdown',event=>{if(this.opened&&event.target instanceof Node&&!this.host.contains(event.target))this.close(false);});
 }

 update(state:Presentation){
  const previous=this.state;this.state=state;this.host.hidden=!state.tiled;
  if(!state.tiled){this.close(false);return;}
  const branchContext=JSON.stringify([state.context?.checkoutId,state.context?.branch]);
  if(previous&&branchContext!==this.branchContext){
   this.close(false);this.branchList=[];this.search.value='';this.select.value='';
  }
  this.branchContext=branchContext;
  if(state.editing&&!previous?.editing)this.close(false);
  const project=state.context?.checkoutId.split('/').filter(Boolean).at(-1)??this.dependencies.t('noCheckout');
  this.project.textContent='· '+project;this.project.title=state.context?.checkoutId??project;
  this.branchName.textContent=state.context?.branch??this.dependencies.t('branch.local');
  this.branch.title=state.context?.branch??this.dependencies.t('branch.local');
  this.branch.setAttribute('aria-description',state.rebase?this.dependencies.t('branch.rebase'):'');this.rebase.hidden=!state.rebase;
  this.branch.disabled=!state.context||state.busy||state.locked||state.stale||state.editing;
  this.actionButton.disabled=!state.context||state.busy||state.locked||state.stale||state.editing;
  this.historyButton.disabled=state.editing;this.settingsButton.disabled=state.editing;this.menuButton.disabled=state.editing;
  this.actionButton.setAttribute('aria-pressed',String(state.catalogOpen));this.historyButton.setAttribute('aria-pressed',String(state.historyOpen));
  const activity=state.activity,attention=activity?.needsInput?'input':activity?.status??'ready';
  this.status.dataset.status=state.locked?'locked':state.editing?'editing':attention;
  this.status.disabled=!activity||state.editing||state.locked;
  this.status.textContent=state.editing?this.dependencies.t('chrome.editing'):state.locked?this.dependencies.t('chrome.locked'):activity?activity.title+' · '+this.dependencies.t(activity.needsInput?'notification.input':activity.status):state.context?state.progress??this.dependencies.t('ready'):this.dependencies.t('chrome.noProject');
  this.status.title=this.status.textContent;
  this.updateSwitch();
  if(this.opened==='context')this.renderContext();
  if(this.opened==='settings')for(const b of Array.from(this.popupBody.querySelectorAll<HTMLButtonElement>('[data-setup]')))b.disabled=state.busy||!['profile','notifications','appearance'].includes(b.dataset.setup!)&&!state.context;
 }

 /** Moving the existing preference keeps its pending save and shared checkout setting intact. */
 toggleBranches(){
  const opened=this.toggle('branches',this.branch);
  if(opened){this.branchBody.insertBefore(this.dependencies.preference,this.switchButton);this.setBranches(this.branchList);}
  return opened;
 }
 setBranches(branches:string[]){this.branchList=branches;this.renderBranches();}
 close(restoreFocus=true){
  if(!this.opened)return;
  const trigger=this.trigger;this.opened=null;this.popup.hidden=true;trigger?.setAttribute('aria-expanded','false');
  if(restoreFocus&&trigger&&!trigger.disabled)trigger.focus();
 }

 private iconButton(name:string|null,label:string,action:()=>void){const b=this.textButton(label,action);b.className='chrome-icon-button';b.setAttribute('aria-label',label);b.title=label;if(name)b.replaceChildren(icon(name));return b;}
 private textButton(label:string,action:()=>void){const b=node('button','',label);b.type='button';b.onclick=action;return b;}
 private toggle(kind:Popup,trigger:HTMLButtonElement){
  if(this.opened===kind){this.close();return false;}
  this.close(false);this.opened=kind;this.trigger=trigger;this.popup.hidden=false;trigger.setAttribute('aria-expanded','true');
  const title=this.dependencies.t(kind==='branches'?'branch.local':kind==='context'?'context.details':kind==='settings'?'settings':'chrome.menu');
  this.popupTitle.textContent=title;this.popup.setAttribute('aria-label',title);this.popupBody.replaceChildren();
  if(kind==='branches')this.popupBody.append(this.branchBody);
  if(kind==='context')this.renderContext(true);
  if(kind==='settings')for(const operation of ['profile','xcode','target','credentials','notifications','appearance']){
   const b=this.textButton(this.dependencies.t('setup.'+operation),()=>this.dependencies.setup(operation));b.dataset.setup=operation;this.popupBody.append(b);
  }
  if(kind==='menu')for(const [label,action]of [[this.dependencies.t('refresh'),this.dependencies.refresh],[this.dependencies.t('context.details'),()=>this.toggle('context',this.menuButton)],[this.dependencies.t('layout.edit'),this.dependencies.edit]] as const){
   this.popupBody.append(this.textButton(label,()=>{this.close();action();}));
  }
  if(this.state)this.update(this.state);
  (this.popupBody.querySelector('input,select,button') as HTMLElement|null)?.focus();return true;
 }
 private renderBranches(){
  const previous=this.select.value,query=this.search.value.toLocaleLowerCase();
  const list=this.branchList.filter(branch=>branch.toLocaleLowerCase().includes(query));
  this.select.replaceChildren(new Option(this.dependencies.t('branch.local'),''),...list.map(branch=>new Option(branch,branch)));
  if(list.includes(previous))this.select.value=previous;
  this.updateSwitch();
 }
 private updateSwitch(){const blocked=!this.state?.context||this.state.busy||this.state.locked||this.state.stale||this.state.editing;this.search.disabled=this.select.disabled=blocked;this.switchButton.disabled=blocked||!this.select.value;}
 private renderContext(force=false){
  const context=this.state?.context,signature=JSON.stringify([context,this.state?.needsBinding]);if(!force&&signature===this.contextSignature)return;
  this.contextSignature=signature;const dl=node('dl','chrome-context');
  for(const [title,value]of [[this.dependencies.t('chrome.checkout'),context?.checkoutId],[this.dependencies.t('branch'),context?.branch],['Xcode',context?.xcode],[this.dependencies.t('chrome.sha'),context?.sha],[this.dependencies.t('chrome.profile'),[context?.profileID,context?.profileRevision].filter(Boolean).join(' · ')]])if(value)dl.append(node('dt','',title),node('dd','',value));
  this.popupBody.replaceChildren(dl);
  if(!context||this.state?.needsBinding)this.popupBody.append(node('p','',this.dependencies.t('chrome.noProject')),this.textButton(this.dependencies.t('binding.request'),this.dependencies.bind));
 }
}
