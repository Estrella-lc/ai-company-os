import {inspectComfyWorkflow} from './comfy-workflow-policy.mjs';
export async function researchComfyWorkflows(fetcher=fetch){
 const repository='Comfy-Org/workflow_templates',trace=[],workflows=[];
 async function get(path,raw=false){
  const url=raw?'https://raw.githubusercontent.com/'+path:'https://api.github.com/'+path;
  const r=await fetcher(url,{redirect:'error',signal:AbortSignal.timeout(15000),headers:{'User-Agent':'AI-Company-OS-Workflow-Research'}});
  if(!r.ok)throw Error('Workflow source HTTP '+r.status);const text=await r.text();if(text.length>5000000)throw Error('Workflow source too large');return JSON.parse(text);
 }
 try{
  const repo=await get('repos/'+repository),commit=await get('repos/'+repository+'/commits/'+encodeURIComponent(repo.default_branch));
  if(!/^[a-f0-9]{40}$/.test(commit.sha||''))throw Error('Unpinned workflow source');
  const tree=await get('repos/'+repository+'/git/trees/'+commit.sha+'?recursive=1');
  const files=(tree.tree||[]).filter(f=>f.type==='blob'&&f.size<=250000&&/\.json$/.test(f.path)&&/wan|ltx/i.test(f.path)&&/image|i2v/i.test(f.path)).slice(0,3);
  for(const f of files){
   try{const graph=await get(repository+'/'+commit.sha+'/'+f.path,true);
    let inspection;try{inspection=inspectComfyWorkflow(graph,[]);}catch{inspection={static_passed:false,runtime_verified:false,reason:'API export or installed-node verification required'};}
    workflows.push({repository,commit_sha:commit.sha,path:f.path,blob_sha:f.sha,license:repo.license?.spdx_id||'UNKNOWN',inspection});
   }catch(e){trace.push({path:f.path,error:String(e.message).slice(0,120)});}
  }
  trace.push({action:'official_workflow_search',repository,commit_sha:commit.sha,count:workflows.length,tree_truncated:!!tree.truncated});
 }catch(e){trace.push({action:'official_workflow_search',error:String(e.message).slice(0,120)});}
 return {workflows,trace,runtime_verified:false,execution_gap:'No verified ComfyUI GPU endpoint; do not mark skill executable',third_party_scripts_executed:false};
}

