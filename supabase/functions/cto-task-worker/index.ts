import { technologyBridge } from './technology-bridge.ts';
import { textExecutionContext, employeeDelivery } from './text-execution.ts';
import {qualityContext,parseQualityReport,uncertainQuality} from './text-quality.ts';
import {projectDialogueContext,validateDialogueAnswer,discussionReferences} from './project-dialogue.ts';
import { knowledgeContext } from './knowledge-context.ts';
import { mediaBridge } from './media-bridge.ts';
import { createGithubVerifier } from './github-identity.ts';
const verifySkillIdentity=createGithubVerifier();
// One durable task per invocation; RPC lease expiry recovers interrupted work.
import { createClient } from "npm:@supabase/supabase-js@2.110.0";
import { GoogleGenAI } from "npm:@google/genai@2.32.0";
const env=(name:string)=>Deno.env.get(name);
const transient=(e:unknown)=>/timeout|timed out|deadline|503|502|500|504|429|high demand|overload/i.test(String((e as Error)?.message??e));
export async function handle(req:Request):Promise<Response>{
 const token=env('CTO_WORKER_TOKEN');
 let skillIdentity:{runner:string;runUrl:string}|null=null;
 if(req.headers.get('authorization')){
  try{skillIdentity=await verifySkillIdentity(req.headers.get('authorization')!.replace(/^Bearer /,''));}
  catch{return Response.json({error:'Unauthorized workload identity'},{status:401});}
 }else if(!token || req.headers.get('x-worker-token')!==token)return Response.json({error:'Unauthorized'},{status:401});
 if(req.method!=='POST')return new Response(null,{status:405});
 const url=env('SUPABASE_URL'), key=env('SUPABASE_SERVICE_ROLE_KEY'), gemini=env('GEMINI_API_KEY');
 if(!url||!key||!gemini)return Response.json({error:'Worker configuration missing'},{status:503});
 const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:(input,init)=>fetch(input,{...init,signal:AbortSignal.timeout(8000)})}});
 const rpc=async(name:string,args:Record<string,unknown>={})=>{const {data,error}=await db.rpc(name,args);if(error)throw new Error(error.message);return data};
 if(skillIdentity){
  try{
   const raw=await req.text();if(raw.length>200000)return Response.json({error:'Report too large'},{status:413});
   const body=JSON.parse(raw);
   if(typeof body.action==='string' && body.action.startsWith('technology_'))return await technologyBridge(db,rpc,body,skillIdentity,{key:gemini,models:[...new Set([env('GEMINI_MODEL')||'gemini-3.8-flash',env('GEMINI_FALLBACK_MODEL')||'gemini-3.5-flash-lite'])]});
   if(typeof body.action==='string' && body.action.startsWith('media_'))return await mediaBridge(db,rpc,body,skillIdentity);
   if(body.action==='claim'){
    const rows=await rpc('claim_skill_research',{p_runner:skillIdentity.runner}),job=rows?.[0];
    let integration=null;if(job?.input?.mode==='technology_execute'){const r=await db.from('company_integrations').select('package,manifest').eq('id',job.input.integration_id).eq('created_by',job.created_by).eq('status','available').single();if(r.error)return Response.json({error:'Shared connection unavailable'},{status:409});integration=r.data;}
    return Response.json({job:job?{id:job.id,lease_token:job.lease_token,input:{need:job.description,query:job.input.query,capability:job.input.capability,mode:job.input.mode,profile:job.input.profile,srt:job.input.mode==='technology_execute'?job.input.srt:undefined},integration}:null});
   }
   if(!['complete','fail'].includes(body.action) || !/^[0-9a-f-]{36}$/i.test(body.taskId || '') || !/^[0-9a-f-]{36}$/i.test(body.leaseToken || '') || !body.report || typeof body.report!=='object')return Response.json({error:'Invalid skill callback'},{status:400});
   const report={...body.report,run_url:skillIdentity.runUrl};
   if(Array.isArray(report.candidates))report.candidates=report.candidates.map((c:any)=>({...c,verification:{...c.verification,run_url:skillIdentity!.runUrl}}));
   const success=await rpc('finish_skill_research',{p_task:body.taskId,p_token:body.leaseToken,p_runner:skillIdentity.runner,p_report:report,p_failed:body.action==='fail'});
   return Response.json({success},{status:success?200:409});
  }catch{return Response.json({error:'Skill callback failed'},{status:503});}
 }
 let job:any;const usage:any[]=[];let lost=false;let timer:ReturnType<typeof setInterval>|undefined;let heartbeatBusy=false;
 try{
  await rpc('reap_expired_chat_replies');
  const jobs=await rpc('claim_chat_reply');job=jobs?.[0];if(!job)return Response.json({status:'idle'});
  timer=setInterval(async()=>{if(heartbeatBusy)return;heartbeatBusy=true;try{if(!await rpc('heartbeat_chat_reply',{p_task:job.id,p_token:job.lease_token}))lost=true}catch{lost=true}finally{heartbeatBusy=false}},20000);
  const {data:agent,error:ae}=await db.from('agents').select('id,code,title,is_active,system_prompt').eq('id',job.assigned_agent_id).single();
  const {data:c,error:ce}=await db.from('conversations').select('id,created_by,agent_id').eq('id',job.conversation_id).single();
  const {data:m,error:me}=await db.from('messages').select('id,conversation_id,sender_type,content,created_at').eq('id',job.request_message_id).single();
  if(ae||ce||me||!agent?.is_active||c?.created_by!==job.created_by||c.agent_id!==agent.id||m?.conversation_id!==c.id||m.sender_type!=='user')throw new Error('INVALID_TASK_BINDING');
  let employeeContext:ReturnType<typeof textExecutionContext>|null=null;
  let inspection:ReturnType<typeof qualityContext>|null=null;
  let dialogue:ReturnType<typeof projectDialogueContext>|null=null;
  if(job.input?.discussion_turn_id){
   const {data:t,error:te}=await db.from('discussion_turns').select('id,created_by,discussion_id,round_number,phase,agent_id,job_id,content').eq('id',job.input.discussion_turn_id).eq('created_by',job.created_by).single();
   if(te||!t)throw new Error('INVALID_TASK_BINDING');
   const [d,h]=await Promise.all([db.from('project_discussions').select('id,created_by,project_id,sender_agent_id,recipient_agent_id,topic,max_rounds,state,snapshot').eq('id',t.discussion_id).eq('created_by',job.created_by).single(),db.from('discussion_turns').select('id,created_by,discussion_id,round_number,phase,agent_id,job_id,content').eq('discussion_id',t.discussion_id).eq('created_by',job.created_by).order('round_number').order('phase')]);
   if(d.error||h.error)throw new Error('INVALID_TASK_BINDING');
   dialogue=projectDialogueContext(job,t,d.data,h.data||[],agent);
  }
  if(job.input?.quality_review_id){
   const {data:q,error:qe}=await db.from('quality_reviews').select('id,created_by,job_id,work_order_id,source_job_id,employee_id,manager_agent_id,snapshot').eq('id',job.input.quality_review_id).eq('created_by',job.created_by).single();
   if(qe||!q)throw new Error('INVALID_TASK_BINDING');
   const [employee,order]=await Promise.all([db.from('ai_employees').select('id,created_by,manager_agent_id,role').eq('id',q.employee_id).eq('created_by',job.created_by).single(),db.from('tasks').select('id,created_by,input').eq('id',q.work_order_id).eq('created_by',job.created_by).eq('task_kind','work_order').single()]);
   if(employee.error||order.error)throw new Error('INVALID_TASK_BINDING');
   inspection=qualityContext(job,q,employee.data,order.data);
   inspection.system+=' 项目协作参考附注也不计入正文；讨论答复本身不构成外部运行或实际执行证据。';
  }
  if(job.input?.employee_id){
   const [employee,order]=await Promise.all([
    db.from('ai_employees').select('id,created_by,manager_agent_id,name,role').eq('id',job.input.employee_id).eq('created_by',job.created_by).single(),
    db.from('tasks').select('id,created_by,assigned_agent_id,conversation_id,input,result').eq('id',job.input.work_order_id).eq('created_by',job.created_by).eq('task_kind','work_order').single(),
   ]);
   if(employee.error || order.error)throw new Error('INVALID_TASK_BINDING');
   employeeContext=textExecutionContext(job,employee.data,order.data,agent);
  }
  const {data:h,error:he}=await db.from('messages').select('id,sender_type,content,created_at').eq('conversation_id',c.id).lte('created_at',m.created_at).order('created_at',{ascending:false}).order('id',{ascending:false}).limit(20);if(he)throw he;
  const knowledge=knowledgeContext(employeeContext?await rpc('knowledge_for_employee_task',{p_task:job.id,p_token:job.lease_token}):[]);
  let discussionData:Parameters<typeof discussionReferences>[0]=[];
  if(!inspection&&!dialogue){const {data,error}=await db.rpc('discussion_context_for_task',{p_task:job.id,p_token:job.lease_token});if(error&&!['PGRST202','42883'].includes(error.code))throw new Error(error.message);discussionData=data||[];}
  const discussion=discussionReferences(discussionData);
  const input=dialogue?dialogue.input:inspection?inspection.input:employeeContext?m.content+knowledge.input+discussion.input:h.filter(x=>x.id!==m.id).reverse().map(x=>(x.sender_type==='user'?'CEO':agent.code)+': '+x.content).join('\n')+'\nCEO: '+m.content+discussion.input;
  const ai=new GoogleGenAI({apiKey:gemini});
  const models=[...new Set([env('GEMINI_MODEL')||'gemini-3.8-flash',env('GEMINI_FALLBACK_MODEL')||'gemini-3.5-flash-lite'])];let answer='';
  for(let i=0;i<models.length;i++){
   if(lost)throw new Error('LEASE_LOST');const model=models[i],start=Date.now();
   try{
    const out=await ai.interactions.create({model,input,system_instruction:dialogue?.system || inspection?.system || employeeContext?.system || 'You are '+agent.code+' ('+agent.title+') of AI Company OS. Answer the CEO in Chinese within your role. You have no tools or repository access; never claim actions were executed.\n'+(agent.system_prompt||''),generation_config:{thinking_level:'low',max_output_tokens:dialogue?(dialogue.limit===1400?800:1600):2400}},{timeout_ms:i===0&&models.length>1?15000:30000,maxRetries:0});
    usage.push({model,status:out.status,duration_ms:Date.now()-start,input_tokens:out.usage?.total_input_tokens??null,output_tokens:out.usage?.total_output_tokens??null,request_id:out.id});
    if(out.status!=='completed'||!out.output_text?.trim())throw new Error('EMPTY_RESPONSE');answer=out.output_text.trim();break;
   }catch(e){if(!usage.some(x=>x.model===model))usage.push({model,status:'failed',duration_ms:Date.now()-start,input_tokens:null,output_tokens:null});if(i===models.length-1||!transient(e))throw e;}
  }
  if(lost)throw new Error('LEASE_LOST');
  let content=employeeDelivery(answer,employeeContext?.prefix || '')+knowledge.provenance+discussion.footer;
  if(dialogue)content=validateDialogueAnswer(answer,dialogue.limit);
  if(inspection){try{content=JSON.stringify(parseQualityReport(answer,inspection.body));}catch{content=JSON.stringify(uncertainQuality('质检输出格式或原文证据未通过验证，需要人工复核；系统没有将其标为通过。'));}}
  await rpc('complete_chat_reply',{p_task:job.id,p_token:job.lease_token,p_content:content,p_usage:usage});
  console.info('EDGE_TASK_SUCCEEDED',{task:job.id});return Response.json({status:'succeeded',taskId:job.id});
 }catch(e){
  const code=(e as Error)?.message==='INVALID_TASK_BINDING'?'invalid_binding':lost?'lease_lost':transient(e)?'provider_unavailable':'execution_failed';
  if(job&&!lost)try{await rpc('fail_chat_reply',{p_task:job.id,p_token:job.lease_token,p_code:code,p_retry:transient(e),p_usage:usage})}catch{console.warn('EDGE_FAIL_WRITE',{task:job.id})}
  console.warn('EDGE_TASK_FAILED',{task:job?.id,code});return Response.json({status:'failed',code},{status:503});
 }finally{if(timer!==undefined)clearInterval(timer)}
}
Deno.serve(handle);
