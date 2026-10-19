// Created by Василий Маслов on 08.10.2026.
/** Old helpers have no appearance field. Invalid polls retain the last valid choice. */
export function resolveAppearance(value:unknown,previous?:'tileGrid'|'legacy'):'tileGrid'|'legacy'{
 return value==='tileGrid'||value==='legacy'?value:previous??'legacy';
}

export type CodexAppearance='tileGrid'|'legacy'|'windows95'|'windowsXP';
export type AppearanceSnapshot={version:1;selection:CodexAppearance;revision:number;persistenceFailed?:boolean};
export const appearances:CodexAppearance[]=['tileGrid','legacy','windows95','windowsXP'];
export function isRetro(value:CodexAppearance|undefined){return value==='windows95'||value==='windowsXP';}

/** A stale state poll can update task data, but can never roll back an acknowledged theme. */
export class AppearanceState {
 snapshot:AppearanceSnapshot|null=null;
 selection:CodexAppearance='legacy';
 accept(value:unknown,legacy:unknown){
  if(value&&typeof value==='object'){
   const next=value as AppearanceSnapshot;
   if(next.version===1&&appearances.includes(next.selection)&&Number.isSafeInteger(next.revision)&&next.revision>=0&&(!this.snapshot||next.revision>this.snapshot.revision||next.revision===this.snapshot.revision&&next.selection===this.snapshot.selection)){
    this.snapshot={...next};this.selection=next.selection;
   }
  }
  if(!this.snapshot)this.selection=resolveAppearance(legacy,this.selection==='tileGrid'?'tileGrid':'legacy');
  return this.selection;
 }
}
