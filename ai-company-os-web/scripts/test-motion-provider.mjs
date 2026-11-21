import assert from 'node:assert/strict';
import {motionRequest,motionResult,generateMotion} from './motion-provider.mjs';
assert.throws(()=>motionRequest(''));
assert.equal(motionRequest('Adult character raises a hand').data[7],5);
assert.equal(motionResult('event: heartbeat\ndata: null\n\n'),null);
assert.throws(()=>motionResult('event: error\ndata: null\n\n'));
const event=url=>'event: complete\ndata: '+JSON.stringify([{video:{url}},42])+'\n\n';
assert.throws(()=>motionResult(event('https://evil.example/video.mp4')));
const output=motionResult(event('https://lightricks-ltx-video-distilled.hf.space/gradio_api/file=/tmp/gradio/test/output.mp4'));
assert.equal(output.motion_review,'required');assert.equal(output.ceo_acceptance,false);
let calls=0;
const result=await generateMotion('Adult character raises a hand',async()=>{calls++;if(calls===1)return Response.json({event_id:'a'.repeat(32)});throw Error('timeout');});
assert.equal(calls,2);assert.equal(result.event_id,'a'.repeat(32));assert.equal(result.state,'unverified');
console.log('PASS: bounded request, output host, failure, review gate and recovery ID without resubmission');
let persisted=false;
await generateMotion('Synthetic adult moves',async(url,options)=>{
 if(options.method==='POST')return Response.json({event_id:'b'.repeat(32)});
 assert.equal(persisted,true);return new Response('event: heartbeat\ndata: null\n\n');
},async()=>{persisted=true;});
let recoveryCalls=0;
await generateMotion('Synthetic adult moves',async(url,options)=>{
 recoveryCalls++;assert.notEqual(options.method,'POST');assert.ok(url.endsWith('c'.repeat(32)));return new Response('event: heartbeat\ndata: null\n\n');
},async()=>{throw Error('Recovery must not create another job');},'c'.repeat(32));
assert.equal(recoveryCalls,1);
console.log('PASS: persist before polling and resume without a second generation');

