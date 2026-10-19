// Created by Василий Маслов on 12.10.2026.
import {appearances,type AppearanceSnapshot,type CodexAppearance} from './appearance';

/** Inert previews and a local save state are independent of task admission and project binding. */
export class AppearancePicker {
 readonly host=document.createElement('section');
 private options=new Map<CodexAppearance,HTMLButtonElement>();
 private message=document.createElement('p');
 private saving=false;
 private snapshot:AppearanceSnapshot|null=null;
 constructor(private t:(key:string)=>string,private save:(value:CodexAppearance,revision:number)=>Promise<AppearanceSnapshot>,private supported:(value:CodexAppearance)=>Promise<boolean>){
  this.host.className='appearance-picker';this.host.setAttribute('role','radiogroup');this.host.setAttribute('aria-label',t('setup.appearance'));
  for(const value of appearances){
   const button=document.createElement('button');button.type='button';button.className='appearance-choice';button.dataset.appearanceChoice=value;button.setAttribute('role','radio');
   const preview=document.createElement('span');preview.className='appearance-miniature';preview.dataset.previewAppearance=value;preview.setAttribute('aria-hidden','true');
   const title=document.createElement('span');title.textContent=t('appearance.'+value);button.append(preview,title);
   button.onclick=()=>void this.choose(value);
   button.onkeydown=event=>{if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End'].includes(event.key))return;event.preventDefault();const index=appearances.indexOf(value),next=event.key==='Home'?0:event.key==='End'?appearances.length-1:(index+(['ArrowLeft','ArrowUp'].includes(event.key)?-1:1)+appearances.length)%appearances.length;this.options.get(appearances[next])!.focus();void this.choose(appearances[next]);};
   this.options.set(value,button);this.host.append(button);
  }
  this.message.className='appearance-message';this.message.setAttribute('role','status');this.host.append(this.message);
 }
 update(snapshot:AppearanceSnapshot|null){
  this.snapshot=snapshot;
  for(const [value,button]of this.options){const selected=snapshot?.selection===value;button.setAttribute('aria-checked',String(selected));button.tabIndex=selected||!snapshot&&value==='tileGrid'?0:-1;button.disabled=this.saving||!snapshot;}
  if(!this.saving&&snapshot?.persistenceFailed)this.message.textContent=this.t('appearance.recovery');
  if(!this.saving&&!snapshot)this.message.textContent=this.t('appearance.updateRequired');
 }
 private async choose(value:CodexAppearance){
  if(this.saving||!this.snapshot)return;
  const revision=this.snapshot.revision,focused=document.activeElement as HTMLElement;
  this.saving=true;this.message.textContent=this.t('appearance.saving');this.update(this.snapshot);
  try{
   if(!await this.supported(value))throw new Error(this.t('appearance.fontMissing'));
   const saved=await this.save(value,revision);this.message.textContent='';this.snapshot=saved;
  }catch(error){this.message.textContent=error instanceof Error?error.message:this.t('appearance.saveFailed');}
  finally{this.saving=false;this.update(this.snapshot);if(focused?.isConnected)focused.focus({preventScroll:true});}
 }
}
