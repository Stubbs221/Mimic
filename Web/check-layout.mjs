// Created by Василий Маслов on 06.10.2026.
import assert from 'node:assert/strict';
import {build} from 'esbuild';
async function compiled(path){const result=await build({entryPoints:[new URL(path,import.meta.url).pathname],bundle:true,write:false,format:'esm',platform:'node'});return import('data:text/javascript;base64,'+Buffer.from(result.outputFiles[0].text).toString('base64'));}
const {standard,change,insert,validate}=await compiled('./layout.ts');
const {HoldGesture,scrollSpeed,DragResize,resizeZone}=await compiled('./drag-gesture.ts');
const row=slots=>({id:crypto.randomUUID(),slots});
let rows=[row(['utils','builds']),row(['ci','simulators']),row([null,'format'])],layout={version:1,revision:0,rows};
let next=change(layout,l=>insert(l,'utils',{row:rows[1].id,slot:1}));
assert.deepEqual(next.rows.map(r=>r.slots),[['builds','ci'],['simulators','utils'],[null,'format']]);
next=change(next,l=>insert(l,'utils',{row:rows[0].id,slot:0}));assert.deepEqual(next.rows,rows);
next=change(next,l=>insert(l,'builds',{row:rows[2].id,slot:0}));assert.deepEqual(next.rows.map(r=>r.slots),[['utils',null],['ci','simulators'],['builds','format']]);
rows=[row(['utils','format']),row(['bootstrap']),row(['ci','builds']),row(['simulators',null]),row(['beta'])];layout={version:1,revision:0,rows};
next=change(layout,l=>insert(l,'utils',{row:rows[2].id,slot:0}));assert.deepEqual(next.rows.map(r=>r.slots),[[null,'format'],['bootstrap'],['utils','ci'],['builds','simulators'],['beta']]);
layout={version:1,revision:0,rows:[...rows.slice(0,3),rows[4]]};next=change(layout,l=>insert(l,'utils',{row:rows[2].id,slot:1}));assert.deepEqual(next.rows.map(r=>r.slots),[[null,'format'],['bootstrap'],['ci','utils'],['builds',null],['beta']]);
const before=structuredClone(layout);assert.throws(()=>insert(layout,'bootstrap',{row:rows[2].id,slot:0}));assert.deepEqual(layout,before);
const original=standard(),blocks=original.rows.flatMap(r=>r.slots).filter(Boolean);
for(const block of blocks)for(const target of [{},...original.rows.flatMap(r=>[{before:r.id},...(r.slots.length===2&&original.rows.find(r=>r.slots.includes(block)).slots.length===2?[{row:r.id,slot:0},{row:r.id,slot:1}]:[])])]){
 const value=change(original,l=>insert(l,block,target));validate(value);assert.deepEqual(value.rows.flatMap(r=>r.slots).filter(Boolean).sort(),[...blocks].sort());for(const kind of blocks)assert.equal(value.rows.find(r=>r.slots.includes(kind)).slots.length,original.rows.find(r=>r.slots.includes(kind)).slots.length);
}
let gesture=new HoldGesture();gesture.press(0,0,1000);assert(!gesture.activate(1349));assert(gesture.activate(1350));assert(!gesture.activate(1400));assert.deepEqual(gesture.release(),{drop:true,click:false});
gesture.press(0,0,0);gesture.move(12,0);assert.equal(gesture.phase,'waiting');gesture.move(12.1,0);assert(!gesture.activate(1000));assert.deepEqual(gesture.release(),{drop:false,click:false});
gesture.press(0,0,0,false);assert.equal(gesture.phase,'idle');gesture.press(0,0,0);assert(gesture.release().click);
assert.equal(scrollSpeed(24,600),-200);assert.equal(scrollSpeed(576,600),200);assert.equal(scrollSpeed(300,600),0);assert.equal(scrollSpeed(650,600),400);
console.log('PASS: insertion parity scenarios, sizes/identities/no loss, atomic rejection, hold threshold/click suppression, bounded scrolling');

// Size changes remain atomic and use the same session IDs on repeated previews.
const origin=standard(),ids=[crypto.randomUUID(),crypto.randomUUID(),crypto.randomUUID()];
next=change(origin,l=>insert(l,'bootstrap',{before:origin.rows[1].id},'mini',1,ids));assert.deepEqual(next.rows[0].slots,[null,'bootstrap']);
const enlarged=change(origin,l=>insert(l,'builds',{before:origin.rows[1].id},'full',undefined,ids));assert.deepEqual(enlarged.rows[1].slots,['builds']);assert.deepEqual(enlarged.rows[2].slots,['utils',null]);
assert.deepEqual(enlarged,change(origin,l=>insert(l,'builds',{before:origin.rows[1].id},'full',undefined,ids)));
next=change(origin,l=>insert(l,'bootstrap',{row:origin.rows[1].id,slot:1},'mini',undefined,ids));assert.equal(next.rows[1].slots[1],'bootstrap');assert.deepEqual(next.rows.flatMap(r=>r.slots).filter(Boolean).sort(),origin.rows.flatMap(r=>r.slots).filter(Boolean).sort());
const rejected=structuredClone(origin);assert.throws(()=>insert(rejected,'bootstrap',{row:origin.rows[1].id,slot:0},'full'));assert.deepEqual(rejected,origin);
let size=new DragResize('mini',{x:0,y:0});
assert(!size.update('center',{x:0,y:0},0));assert.equal(size.pending,'center');
assert(!size.update('center',{x:30,y:40},499));assert(size.progress>.99);
assert(size.update('center',{x:30,y:40},500));assert.equal(size.size,'full');
assert(!size.update('right',{x:0,y:0},1000));assert(!size.update('right',{x:50.1,y:0},1490));assert.equal(size.progress,0);
assert(!size.update('right',{x:50.1,y:0},1989));assert(size.update('right',{x:50.1,y:0},1990));
size=new DragResize('full',{x:0,y:0});assert(!size.update('left',{x:0,y:0},0));assert(!size.update('right',{x:0,y:0},400));assert(!size.update(null,{x:0,y:0},800));assert.equal(size.pending,null);
assert(!size.update('right',{x:0,y:0},1000));assert(!size.update('right',{x:0,y:0},1499));assert(size.update('right',{x:0,y:0},1500));
size=new DragResize('mini',{x:0,y:0});for(let tick=0;tick<10;tick++)assert(!size.update('center',{x:tick*30,y:0},tick*200));assert.equal(size.size,'mini');
assert.equal(resizeZone(30,100),'left');assert.equal(resizeZone(70,100),'right');assert.equal(resizeZone(30.1,100),'center');assert.equal(resizeZone(-1,100),null);
console.log('PASS: atomic resize/side insertion, 500ms dwell without movement, 50pt radius/reset, zone exit, continuous motion, 30/40/30 zones');
