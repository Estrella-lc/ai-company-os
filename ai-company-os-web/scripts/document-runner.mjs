import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,writeFile,readFile,chmod,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
const exec=promisify(execFile),limit=2*1024*1024;
export const profiles=['pdf_extract_v1','docx_extract_v1','docx_create_v1'];
export async function prepareDocuments(){await exec('docker',['build','-t','company-documents:local','sandbox/documents'],{timeout:240000,maxBuffer:1024*1024});}
export async function documentContainer(profile,data,out,fixture=false){
 if(!fixture && (!profiles.includes(profile)||!Buffer.isBuffer(data)||!data.length||data.length>limit))throw new Error('document_input_limit');
 const work=await mkdtemp(join(tmpdir(),'company-documents-')),name='company-documents-'+randomUUID();
 await chmod(work,0o755);await import('node:fs/promises').then(fs=>fs.mkdir(out,{recursive:true}));await chmod(out,0o777);
 try{
  if(!fixture){await writeFile(join(work,'input'),data,{mode:0o444});await writeFile(join(work,'config.json'),JSON.stringify({profile}),{mode:0o444});}
  await exec('docker',['run','--name',name,'--rm','--network','none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=48','--memory=384m','--cpus=1','--user','65534:65534','--tmpfs','/tmp:rw,noexec,nosuid,size=64m','--volume',resolve('sandbox/documents')+':/adapter:ro','--volume',work+':/request:ro','--volume',out+':/out:rw','company-documents:local',...(fixture?['--fixture']:[])],{timeout:60000,maxBuffer:65536});
  return JSON.parse(await readFile(join(out,fixture?'verification.json':'report.json'),'utf8'));
 }finally{await exec('docker',['rm','-f',name],{timeout:5000,maxBuffer:2048}).catch(()=>{});await rm(work,{recursive:true,force:true});}
}
export async function documentResearch(report,evidence){
 await prepareDocuments();
 const verification=await documentContainer(null,null,join(evidence,'documents'),true);
 const repository='Estrella-lc/ai-company-os',commit=process.env.GITHUB_SHA;
 if(!/^[a-f0-9]{40}$/.test(commit||''))throw new Error('untrusted_adapter_commit');
 const document=await readFile('skills/document-processing/SKILL.md','utf8');
 const candidate={repository,commit_sha:commit,skill_path:'skills/document-processing/SKILL.md',name:'company-document-processing',description:'pypdf PDF提取、python-docx DOCX提取与生成；只覆盖记录的测试范围。',document,rejected:false,metadata:{adapter:'company_documents_v1',license:'Company adapter; dependency licenses recorded',engine_licenses:{pypdf:'BSD-3-Clause','python-docx':'MIT'},source_url:'https://github.com/'+repository+'/blob/'+commit+'/skills/document-processing/SKILL.md',requirements_sha256:createHash('sha256').update(await readFile('sandbox/documents/requirements.lock')).digest('hex')},verification};
 report.candidates=[...report.candidates.slice(0,2),candidate];
 report.trace.push({action:'isolated_document_fixture',passed:verification.passed,profiles:verification.profiles,case_count:verification.case_count});
 return report;
}
export async function runDocumentJob(job,api){
 const out=await mkdtemp(join(tmpdir(),'company-document-output-'));
 try{
  const url=new URL(job.inputUrl);if(url.protocol!=='https:'||url.hostname!=='mcwkkmkgfienxrmfyvfl.supabase.co')throw new Error('document_source');
  const r=await fetch(url,{signal:AbortSignal.timeout(20000),redirect:'error'});if(!r.ok||!r.body)throw new Error('document_download');
  const chunks=[];let size=0;for await(const chunk of r.body){size+=chunk.length;if(size>limit)throw new Error('document_input_limit');chunks.push(chunk);}
  await prepareDocuments();const report=await documentContainer(job.profile,Buffer.concat(chunks),out);
  const bytes=await readFile(join(out,'result'));if(bytes.length>limit||createHash('sha256').update(bytes).digest('hex')!==report.output_sha256)throw new Error('document_output_integrity');
  const upload=new URL(job.uploadUrl);if(upload.protocol!=='https:'||upload.hostname!==url.hostname)throw new Error('document_destination');
  const uploaded=await fetch(upload,{method:'PUT',headers:{'Content-Type':job.profile==='docx_create_v1'?'application/vnd.openxmlformats-officedocument.wordprocessingml.document':'text/plain','x-upsert':'false'},body:bytes,signal:AbortSignal.timeout(20000),redirect:'error'});if(!uploaded.ok)throw new Error('document_upload');
  // File contents and previews stay in private storage, not callback logs or Actions artifacts.
  delete report.preview;
  const saved=await api({action:'document_complete',taskId:job.id,leaseToken:job.lease_token,report});if(!saved.success)throw new Error('document_lease_lost');
  console.log(JSON.stringify({document_job:job.id,scope:report.scope,passed:true}));
 }catch{await api({action:'document_fail',taskId:job.id,leaseToken:job.lease_token,report:{error:'document_processing_failed_or_unsupported'}}).catch(()=>{});throw new Error('Document processing failed safely');}
 finally{await rm(out,{recursive:true,force:true});}
}
