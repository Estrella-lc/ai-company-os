import {createHash} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,readFile,chmod,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const exec=promisify(execFile),MAX_INPUT=2*1024*1024,MAX_OUTPUT=20*1024*1024;
export function checkedFilmUrl(value,upload=false){
 const url=new URL(value),bucket=upload?'company-films':'company-creative';
 const prefix='/storage/v1/object/'+(upload?'upload/sign/':'sign/')+bucket+'/';
 if(url.protocol!=='https:' || url.hostname!=='mcwkkmkgfienxrmfyvfl.supabase.co' || url.port || url.username || url.password || !url.pathname.startsWith(prefix) || !url.searchParams.get('token'))throw new Error('Invalid film grant');
 return url.href;
}
export function verifyFilmBytes(bytes,expected,limit=MAX_INPUT){
 if(!Buffer.isBuffer(bytes) || !bytes.length || bytes.length>limit || !/^[a-f0-9]{64}$/.test(expected || '') || createHash('sha256').update(bytes).digest('hex')!==expected)throw new Error('Film asset integrity failed');
 return bytes;
}
async function download(asset){
 const r=await fetch(checkedFilmUrl(asset.url),{redirect:'error',signal:AbortSignal.timeout(45000)});
 if(!r.ok || !r.body || Number(r.headers.get('content-length'))>MAX_INPUT)throw new Error('Film input unavailable');
 const chunks=[];let size=0;
 for await(const chunk of r.body){size+=chunk.length;if(size>MAX_INPUT)throw new Error('Film input too large');chunks.push(chunk);}
 return verifyFilmBytes(Buffer.concat(chunks),asset.sha256);
}
// Called only after the server has bound grants to an active workload lease.
// This module is deliberately not dispatched until that server contract exists.
export async function runFilmJob(job,api){
 const work=await mkdtemp(join(tmpdir(),'company-film-'));
 try{
  const grant=await api({action:'film_grants',taskId:job.id,leaseToken:job.lease_token});
  if(!grant.plan || typeof grant.script!=='string' || !grant.script.trim())throw new Error('Missing film specification');
  const upload=checkedFilmUrl(grant.uploadUrl,true);
  const input=join(work,'input'),out=join(work,'out');await mkdir(input);await mkdir(out);await chmod(out,0o777);
  await writeFile(join(input,'character.png'),await download(grant.character));
  await writeFile(join(input,'voice.wav'),await download(grant.voice));
  await writeFile(join(input,'voice.txt'),grant.script);
  await writeFile(join(input,'plan.json'),JSON.stringify(grant.plan));
  await exec('docker',['build','-t','ai-company-film:local','sandbox/film'],{timeout:180000,maxBuffer:1024*1024});
  await exec('docker',['run','--rm','--network','none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=128','--memory=1g','--cpus=2','--user','65534:65534','--tmpfs','/tmp:rw,noexec,nosuid,size=128m','--volume',resolve('sandbox/film')+':/adapter:ro','--volume',input+':/input:ro','--volume',out+':/out:rw','ai-company-film:local'],{timeout:190000,maxBuffer:1024*1024});
  const report=JSON.parse(await readFile(join(out,'verification.json'),'utf8'));
  const output=verifyFilmBytes(await readFile(join(out,'sample.mp4')),report.sha256,MAX_OUTPUT);
  if(report.technical_passed!==true || report.bytes!==output.length || report.scope!=='still_image_edit_v1' || report.ceo_acceptance!==false || report.independent_film_review!=='required')throw new Error('Invalid film technical report');
  const response=await fetch(upload,{method:'PUT',headers:{'Content-Type':'video/mp4','x-upsert':'false'},body:output,redirect:'error',signal:AbortSignal.timeout(60000)});
  if(!response.ok)throw new Error('Film upload failed');
  const result=await api({action:'film_complete',taskId:job.id,leaseToken:job.lease_token,report});
  if(!result.success)throw new Error('Film completion rejected');
 }catch{
  try{await api({action:'film_fail',taskId:job.id,leaseToken:job.lease_token});}catch{}
  throw new Error('Private film execution failed; signed grants and media are not logged');
 }finally{await rm(work,{recursive:true,force:true});}
}
