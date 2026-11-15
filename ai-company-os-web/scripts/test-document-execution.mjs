import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {runDocumentJob} from './document-runner.mjs';
const origin='https://mcwkkmkgfienxrmfyvfl.supabase.co',original=globalThis.fetch;
const evidence=join(process.env.RUNNER_TEMP||tmpdir(),'ai-company-skill-evidence','documents');
try{
 for(const [profile,input] of [['pdf_extract_v1',await readFile(join(evidence,'synthetic-input.pdf'))],['docx_extract_v1',await readFile(join(evidence,'synthetic-input.docx'))],['docx_create_v1',Buffer.from('公司业务复测\n成熟开源工具实际生成DOCX')]]){
  let uploaded,callback;
  globalThis.fetch=async(url,options)=>{if(String(url)===origin+'/input')return new Response(input);assert.equal(String(url),origin+'/output');assert.equal(options.method,'PUT');uploaded=Buffer.from(options.body);return new Response('{}');};
  await runDocumentJob({id:'synthetic',lease_token:'synthetic-token',profile,inputUrl:origin+'/input',uploadUrl:origin+'/output'},async body=>{callback=body;return {success:true};});
  assert.equal(callback.action,'document_complete');assert.equal(callback.report.scope,profile);assert.equal(callback.report.output_sha256,createHash('sha256').update(uploaded).digest('hex'));assert.ok(!('preview' in callback.report));
  if(profile==='docx_create_v1')assert.equal(uploaded.subarray(0,2).toString(),'PK');
  if(profile==='pdf_extract_v1')assert.match(uploaded.toString(),/PDF fixture 2026/);
  if(profile==='docx_extract_v1')assert.match(uploaded.toString(),/公司测试/);
 }
 let failed=false,uploaded=false;
 globalThis.fetch=async(url,options)=>{if(options?.method==='PUT')uploaded=true;return new Response('corrupt PDF');};
 await assert.rejects(()=>runDocumentJob({id:'synthetic-failure',lease_token:'token',profile:'pdf_extract_v1',inputUrl:origin+'/input',uploadUrl:origin+'/output'},async body=>{failed=body.action==='document_fail';return {success:true};}));
 assert.equal(failed,true);assert.equal(uploaded,false);
 console.log('PASS: real PDF/DOCX extraction, real DOCX generation, upload hashes, redacted callbacks and corrupt-input failure');
}finally{globalThis.fetch=original;}
