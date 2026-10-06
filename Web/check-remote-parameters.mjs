// Created by Василий Маслов on 06.10.2026.
import assert from 'node:assert/strict';
import {build} from 'esbuild';
const compiled=await build({entryPoints:['remote-parameters.ts'],bundle:true,write:false,format:'esm',platform:'node'});
const {applyRemoteDefaults}=await import('data:text/javascript;base64,'+Buffer.from(compiled.outputFiles[0].text).toString('base64'));
const parameters=[{id:'branch',kind:'branch'},{id:'TEST_PLAN',kind:'choice'},{id:'FAST',kind:'boolean'},{id:'TEXT',kind:'text'}];
const values={branch:'feature/vmaslov/APP-00001-demo-flow-v2x',TEST_PLAN:'FUNCTIONAL',FAST:'false',TEXT:'edited'};
const fields={BRANCH:{defaultValue:'develop',choices:[]},TEST_PLAN:{defaultValue:'SMOKE',choices:['SMOKE','FUNCTIONAL']},FAST:{defaultValue:'true',choices:[]},TEXT:{defaultValue:'default',choices:[]}};
assert.deepEqual(applyRemoteDefaults(parameters,values,fields),[]);
assert.deepEqual(values,{branch:'feature/vmaslov/APP-00001-demo-flow-v2x',TEST_PLAN:'FUNCTIONAL',FAST:'false',TEXT:'edited'});
fields.branch={defaultValue:'develop',choices:[]};
fields.TEST_PLAN.choices=['SMOKE'];
assert.deepEqual(applyRemoteDefaults(parameters,values,fields),['TEST_PLAN']);
assert.equal(values.branch,'feature/vmaslov/APP-00001-demo-flow-v2x');
assert.equal(values.TEST_PLAN,'SMOKE');
assert(!('BRANCH' in values));
console.log('PASS: Jenkins wire fields excluded; branch and editable values preserved; stale choices replaced.');
