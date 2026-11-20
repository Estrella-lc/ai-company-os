import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {filmBridge} from '../../supabase/functions/cto-task-worker/film-bridge.ts';
const id='11111111-1111-4111-8111-111111111111',token='22222222-2222-4222-8222-222222222222';
const body={taskId:id,leaseToken:token,action:'film_grants'},identity={runner:'12/1',runUrl:'https://github.com/example/run'};
const flow={created_by:'owner',source_job:'source',storyboard:{shots:[]},source_snapshot:{spec:{voice_text:'对白'},assets:{image_path:'owner/source/image.png',voice_path:'owner/source/voice.wav',image:{sha256:'a'.repeat(64)},voice:{sha256:'b'.repeat(64)}}}};
test('an invalid or expired lease cannot reach storage',async()=>{
 const db={storage:{from(){throw Error('Storage must not be touched');}}};
 assert.equal((await filmBridge(db,async()=>[],body,identity)).status,403);
 assert.equal((await filmBridge(db,async()=>{throw Error('RPC must not run');},{...body,taskId:'bad'},identity)).status,400);
});
test('grants use frozen server source and server output paths',async()=>{
 const seen=[];const db={storage:{from(bucket){return {async createSignedUrl(path){seen.push([bucket,path]);return {data:{signedUrl:'input'}};},async createSignedUploadUrl(path){seen.push([bucket,path]);return {data:{signedUrl:'output'}};}};}}};
 const r=await filmBridge(db,async()=>[flow],{...body,output_path:'attacker',source_path:'attacker'},identity);
 assert.equal(r.status,200);assert.deepEqual(seen,[['company-creative','owner/source/image.png'],['company-creative','owner/source/voice.wav'],['company-films',`owner/${id}/${token}/sample.mp4`]]);
 await assert.rejects(()=>filmBridge(db,async()=>[{...flow,source_job:'foreign'}],body,identity),/BINDING/);
});
test('completion hashes actual private bytes and never trusts a reported output path',async()=>{
 const bytes=Buffer.from([0,0,0,24,102,116,121,112,105,115,111,109]);
 const report={technical_passed:true,scope:'still_image_edit_v1',width:512,height:768,duration:15,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),independent_film_review:'required',ceo_acceptance:false,output_path:'attacker'};
 let saved;const db={storage:{from(){return {async download(){return {data:new Blob([bytes])};}};}}};
 const rpc=async(name,args)=>name==='film_task_context'?[flow]:(saved=args,true);
 assert.equal((await filmBridge(db,rpc,{...body,action:'film_complete',report},identity)).status,200);
 assert.equal(saved.p_report.output_path,`owner/${id}/${token}/sample.mp4`);
 assert.equal(saved.p_report.independent_film_review,'required');
 await assert.rejects(()=>filmBridge(db,rpc,{...body,action:'film_complete',report:{...report,sha256:'a'.repeat(64)}},identity),/INTEGRITY/);
 assert.equal((await filmBridge(db,rpc,{...body,action:'film_complete',report:{...report,ceo_acceptance:true}},identity)).status,400);
});

