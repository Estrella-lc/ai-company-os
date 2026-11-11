import {createHash,randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,chmod,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {discoverTechnologies,validateManifest} from './technology-discovery.mjs';
const exec=promisify(execFile);
export const timelineCases=()=>[
 {text:'',events:[]},
 {text:'1\n00:00:00,000 --> 00:00:01,000\nHello\n',events:[{text:'Hello',start:0,end:1}]},
 {text:'1\n00:00:00,000 --> 00:00:01,000\n你好\n',events:[{text:'你好',start:0,end:1}]},
 {text:'1\n00:00:00,000 --> 00:00:01,000\nA\n\n2\n00:00:01,000 --> 00:00:02,000\nB\n',events:[{text:'A',start:0,end:1},{text:'B',start:1,end:2}]},
 {text:'1\n00:00:00,000 --> 00:00:01,000\nFirst\nSecond\n',events:[{text:'First\nSecond',start:0,end:1}]},
 {text:'\ufeff1\r\n00:00:00,000 --> 00:00:01,000\r\n中文\r\n',events:[{text:'中文',start:0,end:1}]},
 {text:'8\n00:00:00,000 --> 00:00:01,000\nIndex\n',events:[{text:'Index',start:0,end:1}]},
 {text:'1\n00:00:01,125 --> 00:00:02,875\nPrecision\n',events:[{text:'Precision',start:1.125,end:2.875}]},
];
export async function wheelBytes(pkg,fetcher=fetch){const u=new URL(pkg.url);if(u.protocol!=='https:' || u.hostname!=='files.pythonhosted.org' || !/^[A-Za-z0-9_.+\-]+\.whl$/.test(pkg.filename) || !/^[a-f0-9]{64}$/.test(pkg.sha256))throw new Error('wheel_source');const r=await fetcher(u,{redirect:'error',signal:AbortSignal.timeout(30000)});if(!r.ok || !r.body)throw new Error('wheel_download');const chunks=[];let n=0;for await(const c of r.body){n+=c.length;if(n>10000000)throw new Error('wheel_size');chunks.push(c);}const bytes=Buffer.concat(chunks);if(createHash('sha256').update(bytes).digest('hex')!==pkg.sha256)throw new Error('wheel_hash');return bytes;}
export async function prepareConnector(){await exec('docker',['build','-t','company-package-connector:local','sandbox/integration'],{timeout:180000,maxBuffer:1024*1024});}
export async function invokePackage(pkg,manifest,input,bytes){
 validateManifest(manifest);const container='company-connection-'+randomUUID(),work=await mkdtemp(join(tmpdir(),'company-connection-'));await chmod(work,0o755);
 try{await writeFile(join(work,pkg.filename),bytes,{mode:0o444});await writeFile(join(work,'config.json'),JSON.stringify({filename:pkg.filename,sha256:pkg.sha256,manifest,input}),{mode:0o444});
 const {stdout}=await exec('docker',['run','--name',container,'--rm','--network','none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=48','--memory=256m','--cpus=1','--user','65534:65534','--tmpfs','/tmp:rw,noexec,nosuid,size=128m','--volume',resolve('sandbox/integration')+':/connector:ro','--volume',work+':/request:ro','company-package-connector:local'],{timeout:35000,maxBuffer:1024*1024});return JSON.parse(stdout);
 }finally{await exec('docker',['rm','-f',container],{timeout:5000,maxBuffer:2048}).catch(()=>{});if(!work.startsWith(join(tmpdir(),'company-connection-')))throw new Error('cleanup_path');await rm(work,{recursive:true,force:true});}
}
export async function verifyPackage(pkg,manifest,bytes){const cases=timelineCases(),failures=[];let passed=0,isolation=true;for(let i=0;i<cases.length;i++){try{const result=await invokePackage(pkg,manifest,{srt:cases[i].text},bytes);isolation &&=Object.keys(result.isolation || {}).length===4 && Object.values(result.isolation).every(v=>v===true);if(JSON.stringify(result.events)===JSON.stringify(cases[i].events))passed++;else failures.push({case:i,error:'timeline_output_mismatch'});}catch{failures.push({case:i,error:'package_invocation_failed'});}if(failures.length>=2)break;}return {profile:'subtitle_timeline_v1',passed:passed===cases.length && isolation,case_count:cases.length,passed_count:passed,isolation_passed:isolation,failures};}
export async function runTechnology(job,api){
 await prepareConnector();let report;
 try{
 if(job.input.mode==='technology_execute'){
  const saved=job.integration,bytes=await wheelBytes(saved.package),result=await invokePackage(saved.package,saved.manifest,{srt:job.input.srt},bytes);
  if(!Array.isArray(result.events) || result.events.length>200 || result.events.some(e=>typeof e.text!=='string' || !Number.isFinite(e.start) || !Number.isFinite(e.end) || e.start<0 || e.end<e.start))throw new Error('invalid_timeline');
  report={connection_status:'executed',summary:'员工复用了公司已有成熟技术连接，完成字幕时间轴解析；未重新搜索、生成代码或调用规划模型。',events:result.events};
 }else{
  const discovery=await discoverTechnologies(job.input.query);report={connection_status:'blocked',summary:'当前未找到通过本连接器实际验收的方案，未登记可调用能力。需要根据阻塞记录补充依赖、运行环境或其他平台接口。',trace:discovery.trace};
  for(const candidate of discovery.candidates){try{const plan=await api({action:'technology_plan',taskId:job.id,leaseToken:job.lease_token,candidate},65000),manifest=validateManifest(plan.manifest),bytes=await wheelBytes(candidate.package),verification=await verifyPackage(candidate.package,manifest,bytes);if(verification.passed){report={connection_status:'connected',summary:'平台员工搜索并选择成熟开源包，锁定版本、自动安装并通过字幕时间轴业务验收，已登记为公司共享连接。',repository:candidate.repository,commit_sha:candidate.commit_sha,license:candidate.license,package:candidate.package,manifest,verification,planning_model:plan.model,trace:discovery.trace};break;}report.trace.push({repository:candidate.repository,blocked:'business_acceptance_failed',verification});}catch{report.trace.push({repository:candidate.repository,blocked:'planning_or_invocation_failed'});}}
 }
 const saved=await api({action:'technology_finish',taskId:job.id,leaseToken:job.lease_token,report});if(!saved.success)throw new Error('lease_rejected');console.log(JSON.stringify({taskId:job.id,status:report.connection_status}));
 }catch{await api({action:'technology_fail',taskId:job.id,leaseToken:job.lease_token,report:{summary:'成熟技术搜索或调用失败，没有新增已接入能力。'}}).catch(()=>{});throw new Error('Technology job failed safely');}
}
