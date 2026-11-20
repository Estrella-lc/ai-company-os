import {mkdir,mkdtemp,writeFile,readFile,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {runCreative,runCreativeFixture} from './creative-runner.mjs';
import {runTechnology} from './technology-runner.mjs';
import {discoverSkills} from './skill-discovery.mjs';
import {runSubtitleDelivery} from './subtitle-delivery.mjs';
import {documentResearch,runDocumentJob,claimDocumentJob} from './document-runner.mjs';
const exec=promisify(execFile),root=resolve('.');
const endpoint='https://mcwkkmkgfienxrmfyvfl.supabase.co/functions/v1/cto-task-worker?skill_runner=1';
const fixture=process.argv.includes('--fixture'),sandboxOnly=process.argv.includes('--sandbox-only');
async function identity(){
 const requestUrl=process.env.ACTIONS_ID_TOKEN_REQUEST_URL,requestToken=process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
 if(!requestUrl || !requestToken)throw new Error('GitHub OIDC is not available');
 const url=new URL(requestUrl);if(url.protocol!=='https:' || !url.hostname.endsWith('.actions.githubusercontent.com'))throw new Error('Unexpected identity provider URL');
 url.searchParams.set('audience','ai-company-os-skills');
 const r=await fetch(url,{headers:{Authorization:'Bearer '+requestToken},signal:AbortSignal.timeout(15000),redirect:'error'});
 if(!r.ok)throw new Error('Could not obtain workload identity');return (await r.json()).value;
}
async function api(body,timeout=20000){
 const token=await identity();
 const r=await fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(timeout),redirect:'error'});
 const data=await r.json();if(!r.ok)throw new Error(data.error || 'Skill callback failed');return data;
}
async function sandbox(documents,out){
 const candidateDir=await mkdtemp(join(tmpdir(),'public-skill-'));
 for(let i=0;i<documents.length;i++)await writeFile(join(candidateDir,'candidate-'+i+'.md'),documents[i]);
 await mkdir(out,{recursive:true});await chmod(out,0o777);
 await exec('docker',['build','-t','ai-company-subtitle-test:local','sandbox/subtitle'],{cwd:root,timeout:240000,maxBuffer:1024*1024});
 const args=['run','--rm','--network','none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=64','--memory=512m','--cpus=1','--tmpfs','/tmp:rw,noexec,nosuid,size=64m','--user','65534:65534','--volume',resolve('sandbox/subtitle')+':/adapter:ro','--volume',candidateDir+':/skill:ro','--volume',out+':/out:rw','ai-company-subtitle-test:local'];
 await exec('docker',args,{timeout:150000,maxBuffer:1024*1024});
 return JSON.parse(await readFile(join(out,'verification.json'),'utf8'));
}
let job;
const evidence=resolve(process.env.RUNNER_TEMP || tmpdir(),'ai-company-skill-evidence');
try{
 await mkdir(evidence,{recursive:true});
 if(process.argv.includes('--creative-fixture')){await runCreativeFixture(join(evidence,'creative-synthetic'));process.exit(0);}
 if(process.argv.includes('--document-fixture')){
  const report=await discoverSkills({query:'pdf docx document processing',capability:'documents'});
  await documentResearch(report,evidence);
  await writeFile(join(evidence,'research-report.json'),JSON.stringify(report,null,2));
  const adapter=report.candidates.find(c=>c.metadata.adapter==='company_documents_v1');
  if(!adapter?.verification.passed)throw new Error('Document adapter fixture failed');
  console.log(JSON.stringify({fixture:'document_research',catalogFirst:report.trace[0]?.action==='find_skills_catalog',verification:adapter.verification}));process.exit(0);
 }
 if(sandboxOnly){console.log(JSON.stringify(await sandbox(['First-party fixture test'],join(evidence,'sandbox'))));process.exit(0);}
 if(!fixture){const document=await claimDocumentJob(api);if(document){await runDocumentJob(document,api);process.exit(0);}const delivery=(await api({action:'media_claim'})).job;if(delivery){await runSubtitleDelivery(delivery,api);process.exit(0);}}
 job=fixture?{id:'local-fixture',input:{query:'subtitle agent skills',capability:'subtitles'}}:(await api({action:'claim'})).job;
 if(!job){console.log('No eligible skill research job.');process.exit(0);}
 if(job.input.mode==='creative_samples'){await runCreative(job,api);process.exit(0);}
 if(job.input.mode?.startsWith('technology_')){await runTechnology(job,api);process.exit(0);}
 const report=await discoverSkills(job.input);
 if(job.input.capability==='documents')await documentResearch(report,evidence);
 const compatible=report.candidates.filter(c=>!c.rejected && /^(MIT|Apache-2\.0|BSD-2-Clause|BSD-3-Clause|ISC)$/.test(c.metadata.license) && /subtitle|caption|\bsrt\b/i.test(c.document+'\n'+c.metadata.references.map(r=>r.content || '').join('\n')));
 if(job.input.capability==='subtitles' && compatible.length){
  try{
   const result=await sandbox(report.candidates.map(c=>c.document),join(evidence,'sandbox'));
   compatible[0].verification=result;
   report.trace.push({action:'isolated_subtitle_fixture',passed:result.passed,repository:compatible[0].repository,scope:result.scope});
  }catch(e){report.trace.push({action:'isolated_subtitle_fixture',passed:false,error:String(e.message).slice(0,300)});compatible[0].verification={passed:false,scope:'subtitle_fixture_v1',note:'隔离样例验证未通过；不得用于实际交付。'};}
 }
 report.summary=report.candidates.some(c=>c.verification.scope==='document_processing_v1'&&c.verification.passed)?'已检索技能并验证成熟开源文档适配器，支持PDF文本提取、DOCX文本提取和生成；不包含OCR或原排版还原。':report.candidates.some(c=>c.verification.passed)?'已找到技能并完成有限范围字幕样例验证；不包含语音识别、任意脚本或完整视频制作。':report.candidates.length?'已找到固定版本技能说明；尚未通过适用的运行验证，不能视为已经掌握。':'未找到可用候选，没有新增执行能力。';
 report.third_party_scripts_executed=false;
 await writeFile(join(evidence,'research-report.json'),JSON.stringify(report,null,2));
 if(!fixture){const done=await api({action:'complete',taskId:job.id,leaseToken:job.lease_token,report});if(!done.success)throw new Error('Result lease was rejected');}
 console.log(JSON.stringify({taskId:job.id,candidates:report.candidates.length,verifiedScopes:report.candidates.filter(c=>c.verification.passed).map(c=>c.verification.scope),evidence}));
}catch(e){
 console.error('SKILL_RUN_FAILED',String(e.message).slice(0,500));
 if(job && !fixture)try{await api({action:'fail',taskId:job.id,leaseToken:job.lease_token,report:{summary:'研究或验证执行失败，将在预算与次数限制内重试。',error:String(e.message).slice(0,500)}});}catch{console.error('FAIL_CALLBACK_UNAVAILABLE');}
 process.exitCode=1;
}
