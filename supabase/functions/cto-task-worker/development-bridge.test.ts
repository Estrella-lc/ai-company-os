import assert from 'node:assert/strict';
import {developmentBridge} from './development-bridge.ts';
const id='11111111-1111-4111-8111-111111111111',token='22222222-2222-4222-8222-222222222222';
const identity={runner:'123/1',runUrl:'https://github.com/Estrella-lc/ai-company-os/actions/runs/123'};
const settings={key:'test-unused',models:['test-unused']};
Deno.test('duplicate generation reservation does not invoke model or read prior source',async()=>{
 const db={from(){throw new Error('Model path must not be reached');}};
 let calls=0;
 const rpc=async()=>{calls++;return [{id,number:1,generation_nonce:'other-reservation',source:null}];};
 const result=await developmentBridge(db,rpc,{action:'dev_generate',taskId:id,leaseToken:token,requestKey:id},identity,settings);
 assert.equal(result.status,409);assert.equal(calls,1);
});
Deno.test('saved candidate replay returns the exact version without a model call',async()=>{
 const rpc=async()=>[{id,number:2,source:'def analyze_srt(text,duration_seconds=None): return {}',source_sha256:'a'.repeat(64)}];
 const result=await developmentBridge({},rpc,{action:'dev_generate',taskId:id,leaseToken:token,requestKey:id},identity,settings);
 const body=await result.json();assert.equal(body.number,2);assert.equal(body.sourceSha256,'a'.repeat(64));
});
Deno.test('test evidence always binds the authoritative workflow URL',async()=>{
 let recorded:any;
 const rpc=async(name:string,args:any)=>{recorded={name,args};return true;};
 const result=await developmentBridge({},rpc,{action:'dev_test',taskId:id,leaseToken:token,attemptId:id,report:{passed:true},runUrl:'https://attacker.invalid'},identity,settings);
 assert.equal(result.status,200);assert.equal(recorded.name,'save_development_test');assert.equal(recorded.args.p_run_url,identity.runUrl);assert.equal(recorded.args.p_runner,identity.runner);
});
Deno.test('invalid workload binding is denied before any RPC',async()=>{
 const result=await developmentBridge({},async()=>{throw new Error('Unexpected call');},{action:'dev_generate',taskId:'invalid'},identity,settings);assert.equal(result.status,400);
});
