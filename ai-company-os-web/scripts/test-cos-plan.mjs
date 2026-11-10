import assert from 'node:assert/strict';
import { parseCosPlan } from '../src/lib/cos-plan.ts';
const plan={mode:'direct',reason:'Simple summary',missing_information:[],tasks:[{title:'Summarize',agent_code:'COS',instruction:'Summarize the supplied text',acceptance:'One sentence',after:[]}]};
assert.deepEqual(parseCosPlan(JSON.stringify(plan)),plan);
assert.deepEqual(parseCosPlan('```json\n'+JSON.stringify(plan)+'\n```'),plan);
assert.equal(parseCosPlan('I have already dispatched the task'),null);
assert.equal(parseCosPlan('{broken JSON'),null);
assert.equal(parseCosPlan(JSON.stringify({...plan,mode:'execute_everything'})),null);
assert.equal(parseCosPlan(JSON.stringify({...plan,missing_information:'unknown'})),null);
assert.equal(parseCosPlan(JSON.stringify({...plan,tasks:[{...plan.tasks[0],after:[0]}]})),null);
assert.equal(parseCosPlan(JSON.stringify({...plan,tasks:[{...plan.tasks[0],after:[-1]}]})),null);
assert.equal(parseCosPlan(JSON.stringify({...plan,tasks:[{...plan.tasks[0],instruction:undefined}]})),null);
console.log('PASS: fenced plans, malformed responses and invalid dependency rejection');

