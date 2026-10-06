// Created by Василий Маслов on 06.10.2026.
/** Serialized counterpart of MimicCore.PanelLayout. Mutations return validated transaction values. */
export const catalog=['bootstrap','utils','builds','ci','simulators','generateUI','generateSicilia','generateGalera','localization','protocols','format','fullCleanup','derivedDataCleanup','uiTests','qualityGates','beta'] as const;
export type Block=typeof catalog[number];
export type Row={id:string;slots:(Block|null)[]};
export type Layout={version:number;revision:number;rows:Row[]};
export type InsertionTarget={row:string;slot:number}|{before?:string};
export const standard=():Layout=>({version:1,revision:0,rows:[['bootstrap'],['utils','builds'],['ci','simulators']].map(slots=>({id:crypto.randomUUID(),slots:slots as Block[]}))});
export function validate(layout:Layout){const blocks=layout.rows.flatMap(row=>row.slots.filter(Boolean));if(layout.version!==1||!Number.isSafeInteger(layout.revision)||layout.revision<0||layout.rows.length>catalog.length||new Set(layout.rows.map(r=>r.id)).size!==layout.rows.length||layout.rows.some(r=>![1,2].includes(r.slots.length)||!r.slots.some(Boolean))||new Set(blocks).size!==blocks.length||blocks.some(b=>!catalog.includes(b as Block)))throw new Error('layout.invalid');return layout;}
export function change(layout:Layout,operation:(value:Layout)=>void){const next=structuredClone(layout);operation(next);return validate(next);}
export function remove(layout:Layout,block:Block){for(const row of layout.rows)row.slots=row.slots.map(b=>b===block?null:b);layout.rows=layout.rows.filter(r=>r.slots.some(Boolean));}
export function add(layout:Layout,block:Block,size:'full'|'mini'='full',before?:string){if(layout.rows.some(r=>r.slots.includes(block)))throw new Error('layout.duplicate');const index=before?layout.rows.findIndex(r=>r.id===before):layout.rows.length;if(index<0)throw new Error('layout.invalid');layout.rows.splice(index,0,{id:crypto.randomUUID(),slots:size==='full'?[block]:[block,null]});}
export function move(layout:Layout,block:Block,before?:string,slot?:number){const row=layout.rows.find(r=>r.slots.includes(block));if(!row)throw new Error('layout.invalid');if(slot!==undefined){const target=layout.rows.find(r=>r.id===before);if(!target||target.slots.length!==2||![0,1].includes(slot)||target.slots[slot]!==null||row.slots.length!==2)throw new Error('layout.occupied');remove(layout,block);target.slots[slot]=block;}else{if(row.id===before)return;const size=row.slots.length===1?'full':'mini';remove(layout,block);add(layout,block,size,before);}}
export function resize(layout:Layout,block:Block,size:'full'|'mini'){const row=layout.rows.find(r=>r.slots.includes(block));if(!row)throw new Error('layout.invalid');if(row.slots.length===(size==='full'?1:2))return;if(size==='mini')row.slots=[block,null];else{const other=row.slots.find(b=>b&&b!==block);row.slots=[block];if(other)layout.rows.splice(layout.rows.indexOf(row)+1,0,{id:crypto.randomUUID(),slots:[other,null]});}}
export function replace(layout:Layout,block:Block,next:Block){if(layout.rows.some(r=>r.slots.includes(next)))throw new Error('layout.duplicate');const row=layout.rows.find(r=>r.slots.includes(block));if(!row)throw new Error('layout.invalid');row.slots[row.slots.indexOf(block)]=next;}

/** Mirrors PanelLayout.insert: rotate within a mini run; displace to a vacancy across full rows. */
export function insert(layout:Layout,block:Block,destination:InsertionTarget,size?:'full'|'mini',miniSlot?:number,generatedRowIDs:string[]=[]){
 if(size!==undefined||miniSlot!==undefined){
  if(miniSlot!==undefined&&![0,1].includes(miniSlot))throw new Error('layout.invalid');
  const next=structuredClone(layout);if(size)resize(next,block,size);insert(next,block,destination);
  if(!('slot'in destination)&&miniSlot!==undefined){const row=next.rows.find(r=>r.slots.length===2&&r.slots.filter(Boolean).length===1&&r.slots.includes(block));if(row)row.slots=miniSlot===0?[block,null]:[null,block];}
  const existing=new Set(layout.rows.map(r=>r.id));let generated=0;for(const row of next.rows)if(!existing.has(row.id)&&generated<generatedRowIDs.length)row.id=generatedRowIDs[generated++];
  validate(next);layout.rows=next.rows;return;
 }
 const source=layout.rows.findIndex(r=>r.slots.includes(block));if(source<0)throw new Error('layout.invalid');
 const sourceSlot=layout.rows[source].slots.indexOf(block),next=structuredClone(layout);
 if('before'in destination||!('slot'in destination)){
  if(destination.before===layout.rows[source].id)return;
  if(destination.before&&!layout.rows.some(r=>r.id===destination.before))throw new Error('layout.invalid');
  const item=layout.rows[source].slots.length===1?structuredClone(layout.rows[source]):{id:crypto.randomUUID(),slots:[block,null]};
  remove(next,block);const index=destination.before?next.rows.findIndex(r=>r.id===destination.before):next.rows.length;next.rows.splice(index,0,item);
 }else{
  const target=layout.rows.findIndex(r=>r.id===destination.row),slot=destination.slot;
  if(target<0||layout.rows[source].slots.length!==2||layout.rows[target].slots.length!==2||![0,1].includes(slot))throw new Error('layout.invalid');
  if(source===target&&sourceSlot===slot)return;
  if(layout.rows[target].slots[slot]===null){next.rows[source].slots[sourceSlot]=null;next.rows[target].slots[slot]=block;}
  else{
   let start=target,end=target;while(start>0&&layout.rows[start-1].slots.length===2)start--;while(end+1<layout.rows.length&&layout.rows[end+1].slots.length===2)end++;
   if(source>=start&&source<=end){const slots=layout.rows.slice(start,end+1).flatMap(r=>r.slots);slots.splice((source-start)*2+sourceSlot,1);slots.splice((target-start)*2+slot,0,block);for(let index=start;index<=end;index++)next.rows[index].slots=slots.slice((index-start)*2,(index-start)*2+2);}
   else{next.rows[source].slots[sourceSlot]=null;let carry:Block|null=block;for(let index=target;index<=end&&carry!==null;index++)for(let half=index===target?slot:0;half<2&&carry!==null;half++){const displaced=next.rows[index].slots[half];next.rows[index].slots[half]=carry;carry=displaced;}if(carry!==null)next.rows.splice(end+1,0,{id:crypto.randomUUID(),slots:[carry,null]});}
  }
  next.rows=next.rows.filter(r=>r.slots.some(Boolean));
 }
 validate(next);layout.rows=next.rows;
}
