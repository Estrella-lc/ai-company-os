import {mkdtemp,readFile,writeFile,mkdir,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash,randomUUID} from 'node:crypto';
import {discoverSkills} from './skill-discovery.mjs';
const exec=promisify(execFile),adapter=resolve('sandbox/creative');
export async function creativeDiscovery(fetcher=fetch){
 const catalog=await discoverSkills({query:'image speech generation agent skills',capability:'creative'},fetcher);
 const trace=catalog.trace,candidates=[],alternatives=[];
 for(const query of ['CPU text to image openvino','Chinese offline text to speech onnx']){
  try{const r=await fetcher('https://api.github.com/search/repositories?q='+encodeURIComponent(query+' archived:false')+'&sort=stars&per_page=3',{headers:{'User-Agent':'AI-Company-OS-Capability-Employee'},redirect:'error',signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('search_'+r.status);const data=await r.json();
   for(const item of data.items||[])if(!item.private&&!item.archived)alternatives.push({repository:item.full_name,stars:item.stargazers_count,license:item.license?.spdx_id||'unknown',selected:false,reason:'发现的成熟技术候选；未适配当前固定CPU执行接口，未运行或登记为已验证能力'});
   trace.push({action:'mature_technology_search',query,repositories:(data.items||[]).map(x=>x.full_name)});
  }catch{trace.push({action:'mature_technology_search',query,status:'unavailable_using_supported_upstream_catalog'});}
 }
 for(const [repository,profile] of [['openvinotoolkit/openvino.genai','character_reference_cpu_v1'],['k2-fsa/sherpa-onnx','mandarin_tts_cpu_v1']]){
  const get=async path=>{const r=await fetcher('https://api.github.com/repos/'+repository+path,{headers:{'User-Agent':'AI-Company-OS-Capability-Employee'},redirect:'error',signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('upstream_metadata_'+r.status);return r.json();};
  const repo=await get(''),commit=await get('/commits/'+encodeURIComponent(repo.default_branch));
  if(repo.private||repo.archived||!['Apache-2.0','MIT'].includes(repo.license?.spdx_id)||!/^[a-f0-9]{40}$/.test(commit.sha))throw Error('upstream_source_unverified');
  candidates.push({repository,commit_sha:commit.sha,license:repo.license.spdx_id,profile,stars:repo.stargazers_count,selected:true,reason:'成熟CPU推理接口与现有免费托管环境匹配；模型数据仍需下载、校验和真实生成验证'});
  trace.push({action:'mature_upstream_inspected',repository,profile,commit_sha:commit.sha});
 }
 return {alternatives,catalog_candidates:catalog.candidates.map(c=>({repository:c.repository,commit_sha:c.commit_sha,skill_path:c.skill_path,rejected:c.rejected})),candidates,trace};
}
export function creativeFailureCode(e){
 const value=String(e?.stderr||'')+' '+String(e?.message||'');
 return /budget_exhausted/.test(value)?'budget_exhausted':e?.killed||e?.code==='ETIMEDOUT'?'phase_timeout':e?.code===137?'runtime_memory_limit':/PermissionError|permission denied/i.test(value)?'filesystem_permission':/429|Too Many Requests/i.test(value)?'source_rate_limit':/403|Forbidden/i.test(value)?'source_access_denied':/ReadTimeout|ConnectionError|download|timed out/i.test(value)?'source_network':/voice_quality|image_quality|output_size/i.test(value)?'technical_quality':/reuse_.*version_changed/.test(value)?'reuse_version_changed':'runtime_or_callback_failed';
}
async function generate(spec,reuse,phase=()=>{},deadline=Date.now()+430000){
 const timeout=maximum=>Math.max(1000,Math.min(maximum,deadline-Date.now()-30000));
 const work=await mkdtemp(join(tmpdir(),'company-creative-')),models=resolve(process.env.RUNNER_TEMP||tmpdir(),'company-creative-model-cache'),out=join(work,'out');
 await chmod(work,0o755);await mkdir(models,{recursive:true});await mkdir(out,{recursive:true});await chmod(out,0o777);
 await writeFile(join(work,'request.json'),JSON.stringify(spec),{mode:0o444});
 if(reuse)await writeFile(join(work,'reuse.json'),JSON.stringify(reuse),{mode:0o444});
 phase('build');await exec('docker',['build','-t','company-creative:local',adapter],{timeout:timeout(170000),maxBuffer:1024*1024});
 // Preparation sees public model hosts, but receives no identity, provider or database secrets.
 phase('prepare');await exec('docker',['run','--rm','--user',process.getuid()+':'+process.getgid(),'--env','HF_HOME=/tmp/hf','--cap-drop=ALL','--security-opt=no-new-privileges','--memory=3g','--cpus=2','--volume',adapter+':/adapter:ro','--volume',models+':/models:rw','--volume',work+':/request:ro','company-creative:local','prepare','/models',...(reuse?['/request/reuse.json']:[])],{timeout:timeout(240000),maxBuffer:1024*1024});
 if(deadline-Date.now()<90000)throw Error('budget_exhausted');
 phase('generate');const container='company-creative-'+randomUUID();
 try{await exec('docker',['run','--name',container,'--network=none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=128','--memory=6g','--memory-swap=6g','--cpus=2','--user=65534:65534','--tmpfs','/tmp:rw,noexec,nosuid,size=256m','--volume',adapter+':/adapter:ro','--volume',models+':/models:ro','--volume',work+':/request:ro','--volume',out+':/out:rw','company-creative:local','generate','/models','/request/request.json','/out'],{timeout:timeout(350000),maxBuffer:1024*1024});}
 catch(e){const steps=String(e?.stdout||'').match(/CREATIVE_ENGINE (image_load|image_generate|voice_load|voice_generate)/g);if(steps)console.log(steps.join('\n'));const state=await exec('docker',['inspect','--format','{{json .State}}',container],{timeout:5000,maxBuffer:4096}).then(r=>JSON.parse(r.stdout)).catch(()=>null);console.log('CREATIVE_RUNTIME',JSON.stringify({exit_code:Number.isInteger(e?.code)?e.code:null,oom_killed:state?.OOMKilled===true}));throw e;}
 finally{await exec('docker',['rm','-f',container],{timeout:5000,maxBuffer:2048}).catch(()=>{});}
 const verification=JSON.parse(await readFile(join(out,'verification.json'),'utf8')),manifest=JSON.parse(await readFile(join(models,'manifest.json'),'utf8'));
 if(!verification.passed||!Object.values(verification.isolation).every(Boolean))throw Error('creative_adapter_unverified');
 return {out,verification,manifest};
}
export const creativeFixture={image_prompt_en:'Single fictional adult male office worker, age 28, short neat black hair, navy blue blazer and cream shirt, calm confident expression, clean detailed anime character concept art, one person, head to knees, neutral pale background, crisp cel shaded illustration, no writing, no logo, no watermark',voice_text:'这份方案不是临时赶出来的，每一个数字，我都核对过。',seed:42};
export async function runCreativeFixture(destination){
 let stage='search';const phase=s=>{stage=s;console.log('CREATIVE_PHASE',s);};
 let discovery,result;try{discovery=await creativeDiscovery();result=await generate(creativeFixture,null,phase);}catch(e){throw Error('creative_fixture_'+stage+'_'+creativeFailureCode(e));}await mkdir(destination,{recursive:true});
 // Only this explicitly synthetic fixture is retained in CI evidence. Real jobs never copy assets here.
 for(const name of ['character.png','voice.wav','verification.json'])await writeFile(join(destination,name),await readFile(join(result.out,name)));
 await writeFile(join(destination,'research.json'),JSON.stringify({discovery,manifest:result.manifest},null,2));
 console.log(JSON.stringify({fixture:'creative_cpu_samples',verification:result.verification}));
}
export async function runCreative(job,api){
 let stage='search';const phase=s=>{stage=s;console.log('CREATIVE_PHASE',s);};const deadline=Date.now()+430000;
 try{
  const discovery=job.input.reuse_manifest?{reused:true,trace:[{action:'reuse_company_verified_capability'}],candidates:[]}:await creativeDiscovery();
  const result=await generate(job.input.spec,job.input.reuse_manifest,phase,deadline);phase('upload');const grants=await api({action:'creative_uploads',taskId:job.id,leaseToken:job.lease_token});
  for(const [name,key] of [['character.png','image'],['voice.wav','voice']]){
   const bytes=await readFile(join(result.out,name));if(createHash('sha256').update(bytes).digest('hex')!==result.verification.files[name].sha256)throw Error('local_asset_hash');
   const r=await fetch(grants[key],{method:'PUT',headers:{'Content-Type':key==='image'?'image/png':'audio/wav'},body:bytes,redirect:'error',signal:AbortSignal.timeout(30000)});if(!r.ok)throw Error('private_upload_failed');
  }
  phase('finish');const response=await api({action:'creative_finish',taskId:job.id,leaseToken:job.lease_token,report:{verification:result.verification,manifest:result.manifest,discovery,adapter_commit:process.env.GITHUB_SHA}},45000);
  if(!response.success)throw Error('creative_lease_rejected');
  console.log(JSON.stringify({taskId:job.id,status:'generated_pending_independent_review'}));
 }catch(e){const code=creativeFailureCode(e);console.log('CREATIVE_FAILED',JSON.stringify({stage,code}));await api({action:'creative_fail',taskId:job.id,leaseToken:job.lease_token,report:{summary:'公开技术搜索、模型数据准备、隔离推理或私有回存未通过；能力未登记为可用。',stage,code}}).catch(()=>{});throw Error('Creative capability validation failed safely');}
}
