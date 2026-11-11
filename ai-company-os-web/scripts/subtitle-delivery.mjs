import {mkdtemp,mkdir,writeFile,readFile,chmod,rm,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const exec=promisify(execFile),MAX=20*1024*1024;
export function checkedMediaUrl(value,upload=false){
 const url=new URL(value);
 const prefix=upload?'/storage/v1/object/upload/sign/company-media/':'/storage/v1/object/sign/company-media/';
 if(url.protocol!=='https:' || url.hostname!=='mcwkkmkgfienxrmfyvfl.supabase.co' || url.port || url.username || url.password || !url.pathname.startsWith(prefix) || !url.searchParams.get('token'))throw new Error('Invalid media URL');
 return url.href;
}
async function download(value,path,limit){
 const r=await fetch(checkedMediaUrl(value),{redirect:'error',signal:AbortSignal.timeout(45000)});
 if(!r.ok || !r.body || Number(r.headers.get('content-length'))>limit)throw new Error('Input download failed');
 const chunks=[];let size=0;
 for await(const chunk of r.body){size+=chunk.length;if(size>limit)throw new Error('Input size limit');chunks.push(chunk);}
 if(!size)throw new Error('Empty input');await writeFile(path,Buffer.concat(chunks));
}
export async function runSubtitleContainer(input,out){
 await mkdir(out,{recursive:true});await chmod(out,0o777);await chmod(input,0o755);
 await exec('docker',['build','-f','sandbox/subtitle/media.Dockerfile','-t','ai-company-media:local','sandbox/subtitle'],{timeout:240000,maxBuffer:1024*1024});
 await exec('docker',['run','--rm','--network','none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=64','--memory=512m','--cpus=1','--tmpfs','/tmp:rw,noexec,nosuid,size=128m','--user','65534:65534','--volume',resolve('sandbox/subtitle')+':/adapter:ro','--volume',resolve(input)+':/input:ro','--volume',resolve(out)+':/out:rw','ai-company-media:local'],{timeout:155000,maxBuffer:1024*1024});
 return JSON.parse(await readFile(join(out,'verification.json'),'utf8'));
}
export async function runSubtitleDelivery(job,api){
 const work=await mkdtemp(join(tmpdir(),'company-media-'));
 try{
  const input=join(work,'input'),out=join(work,'out');await mkdir(input);
  await download(job.media.videoUrl,join(input,'input.mp4'),MAX);
  await download(job.media.subtitleUrl,join(input,'input.srt'),65536);
  const report=await runSubtitleContainer(input,out),output=join(out,'subtitled.mp4');
  if((await stat(output)).size>=MAX)throw new Error('Output size limit');
  const r=await fetch(checkedMediaUrl(job.media.uploadUrl,true),{method:'PUT',headers:{'Content-Type':'video/mp4','x-upsert':'false'},body:await readFile(output),redirect:'error',signal:AbortSignal.timeout(60000)});
  if(!r.ok)throw new Error('Private output upload failed');
  const result=await api({action:'media_complete',taskId:job.id,leaseToken:job.lease_token,report});
  if(!result.success)throw new Error('Output lease rejected');
  console.log('SUBTITLE_PRIVATE_DELIVERY_SAVED');
 }catch{
  try{await api({action:'media_fail',taskId:job.id,leaseToken:job.lease_token,report:{summary:'字幕执行失败，将在现有限额内重试。'}});}catch{console.error('MEDIA_FAIL_CALLBACK_UNAVAILABLE');}
  throw new Error('Private subtitle delivery failed; no user media was retained as a workflow artifact');
 }finally{await rm(work,{recursive:true,force:true});}
}
