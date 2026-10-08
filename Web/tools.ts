// Created by Василий Маслов on 07.10.2026.
/** Stable families shared with MimicCore.ProjectTool; profile IDs never define navigation. */
export const tools=['generation','localization','proto','format','fullCleanup','derivedDataCleanup'] as const;
export type ToolID=typeof tools[number];
export type ToolsPreferences={revision:number;favorites:ToolID[]};
export const defaultFavorites:ToolID[]=['generation','localization','format'];
export const toolRoles:Record<ToolID,string[]>={generation:['generateUI','generateSicilia','generateGalera'],localization:['localization'],proto:['protocols'],format:['format'],fullCleanup:['fullCleanup'],derivedDataCleanup:['derivedDataCleanup']};
export const toolSymbols:Record<ToolID,string>={generation:'▱',localization:'文',proto:'⑂',format:'≡',fullCleanup:'⌫',derivedDataCleanup:'⌫'};
export function toolForRole(role:string):ToolID|undefined{return tools.find(id=>toolRoles[id].includes(role));}
export function validateFavorites(value:ToolsPreferences):ToolsPreferences{
 if(!Number.isSafeInteger(value.revision)||value.revision<0||value.favorites.length>3||new Set(value.favorites).size!==value.favorites.length||value.favorites.some(id=>!tools.includes(id)))throw new Error('tools.invalid');
 return{revision:value.revision,favorites:value.favorites.length?[...value.favorites]:[...defaultFavorites]};
}
export type ToolTask={id:string;toolID?:ToolID|null;isPreview?:boolean;status:string;createdAt:string;startedAt?:string|null;finishedAt?:string|null;context:{checkoutId:string}};
/** Same priority as ProjectTool.record: running, oldest queued, newest completed, never previews. */
export function toolTask<T extends ToolTask>(records:T[],id:ToolID,checkout:string|undefined):T|undefined{
 const matching=records.filter(record=>record.context.checkoutId===checkout&&record.toolID===id&&!record.isPreview);
 return matching.filter(r=>r.status==='running').sort((a,b)=>a.createdAt.localeCompare(b.createdAt))[0]
  ??matching.filter(r=>r.status==='queued').sort((a,b)=>a.createdAt.localeCompare(b.createdAt))[0]
  ??matching.sort((a,b)=>(b.finishedAt??b.createdAt).localeCompare(a.finishedAt??a.createdAt))[0];
}
export function elapsed(task:ToolTask,now=Date.now()):string{
 if(!task.startedAt)return'';const end=task.finishedAt?Date.parse(task.finishedAt):task.status==='running'?now:NaN;
 if(!Number.isFinite(end))return'';const seconds=Math.max(0,Math.floor((end-Date.parse(task.startedAt))/1000));
 return Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0');
}
export const statusSymbols:Record<string,string>={running:'↻',queued:'◷',succeeded:'✓',failed:'!',cancelled:'×',interrupted:'Ⅱ'};
