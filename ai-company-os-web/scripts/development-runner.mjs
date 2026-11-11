import {mkdtemp,mkdir,writeFile,chmod,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash,randomUUID} from 'node:crypto';
import {acceptanceCases,checkAnswer} from './development-contract.mjs';
const exec=promisify(execFile);
function run(args,input,timeout=2500){return new Promise((resolve,reject)=>{const child=execFile('docker',args,{timeout,maxBuffer:16384,killSignal:'SIGKILL'},(error,stdout)=>{if(!error)return resolve(stdout);let reason='sandbox_rejected';try{const parsed=JSON.parse(stdout);if(typeof parsed.error==='string' && /^[A-Za-z_]{1,80}$/.test(parsed.error))reason=parsed.error;}catch{}reject(new Error(error.killed?'timeout':reason));});child.stdin.on('error',()=>{});child.stdin.end(input===undefined?'':JSON.stringify(input));});}
export async function evaluateCandidate(source,{timeout=2500}={}){
 const work=await mkdtemp(join(tmpdir(),'company-dev-candidate-'));await chmod(work,0o755);await writeFile(join(work,'skill.py'),source,{mode:0o444});
 const invoke=async(input,probe=false)=>{const name='company-dev-'+randomUUID();try{
  const args=['run','--name',name,'--rm','-i','--network','none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=32','--memory=128m','--cpus=1','--user','65534:65534','--tmpfs','/tmp:rw,noexec,nosuid,size=8m','--volume',resolve('sandbox/development')+':/harness:ro','--volume',work+':/candidate:ro','ai-company-development:local'];if(probe)args.push('--probe');
  return JSON.parse(await run(args,input,probe?5000:timeout));
 }finally{await exec('docker',['rm','-f',name],{timeout:5000,maxBuffer:2048}).catch(()=>{});}};
 const isolation=await invoke(undefined,true),isolationPassed=Object.values(isolation).length===4 && Object.values(isolation).every(v=>v===true),cases=acceptanceCases(),failures=[];let passed=0,tested=0;
 if(isolationPassed)for(const item of cases){tested++;try{const answer=await invoke(item.input),error=checkAnswer(answer,item.expected);if(error)failures.push({case:item.name,error});else passed++;}catch(e){failures.push({case:item.name,error:e.message});}if(failures.length>=6)break;}
 return {harness_version:'srt_quality_v1',source_sha256:createHash('sha256').update(source).digest('hex'),case_count:cases.length,tested_count:tested,passed_count:passed,passed:isolationPassed && passed===cases.length,isolation_passed:isolationPassed,isolation,failures};
}
export async function prepareDevelopmentImage(){await exec('docker',['build','-t','ai-company-development:local','sandbox/development'],{timeout:180000,maxBuffer:1024*1024});}
export async function runDevelopment(job,api){
 await prepareDevelopmentImage();let feedback={};const evidence=resolve(process.env.RUNNER_TEMP || tmpdir(),'ai-company-skill-evidence','development');await mkdir(evidence,{recursive:true});
 try{for(let n=0;n<3;n++){
  const generated=n===0 && job.candidate?job.candidate:await api({action:'dev_generate',taskId:job.id,leaseToken:job.lease_token,requestKey:randomUUID(),feedback},65000);
  if(!generated.source){feedback={error:'Generation failed; return complete valid JSON containing source.'};continue;}
  const source=generated.source;if(typeof source!=='string' || source.length>24000 || createHash('sha256').update(source).digest('hex')!==generated.sourceSha256)throw new Error('Source integrity mismatch');
  const report=await evaluateCandidate(source);
  await writeFile(join(evidence,'candidate-'+generated.number+'.py'),source);await writeFile(join(evidence,'tests-'+generated.number+'.json'),JSON.stringify(report,null,2));
  const saved=await api({action:'dev_test',taskId:job.id,leaseToken:job.lease_token,attemptId:generated.attemptId,report});if(!saved.success)throw new Error('Test result lease rejected');
  console.log(JSON.stringify({developmentTask:job.id,iteration:generated.number,passed:report.passed,passedCases:report.passed_count,totalCases:report.case_count}));
  if(report.passed)return;
  if(generated.number>=3)return;
  feedback={failures:report.failures,passed_count:report.passed_count,case_count:report.case_count};
 }
 await api({action:'dev_fail',taskId:job.id,leaseToken:job.lease_token,terminal:true});
 }catch{await api({action:'dev_fail',taskId:job.id,leaseToken:job.lease_token,terminal:false}).catch(()=>{});throw new Error('Development stopped safely; inspect persisted attempts and evidence');}
}
if(process.argv.includes('--evaluate-file')){const path=process.argv[process.argv.indexOf('--evaluate-file')+1];await prepareDevelopmentImage();console.log(JSON.stringify(await evaluateCandidate(await readFile(path,'utf8'))));}
