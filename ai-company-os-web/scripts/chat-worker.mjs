import { createClient } from '@supabase/supabase-js';
import { GoogleGenAI } from '@google/genai';
const required=['NEXT_PUBLIC_SUPABASE_URL','SUPABASE_SECRET_KEY','GEMINI_API_KEY'];
for(const name of required) if(!process.env[name])throw new Error(name+' missing');
const db=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL,process.env.SUPABASE_SECRET_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const ai=new GoogleGenAI({apiKey:process.env.GEMINI_API_KEY});
let stopping=false;
process.on('SIGTERM',()=>{stopping=true});process.on('SIGINT',()=>{stopping=true});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function rpc(name,args={}){const {data,error}=await db.rpc(name,args);if(error)throw Object.assign(new Error(error.message),{code:error.code});return data}
async function rows(table,columns,filters){let q=db.from(table).select(columns);for(const [k,v]of Object.entries(filters))q=q.eq(k,v);const {data,error}=await q;if(error)throw error;return data}
function transient(e){return /timeout|timed out|deadline|503|502|500|504|429|high demand|overload/i.test(e.message??'')||/timeout/i.test(e.name??'')}
async function execute(job){
 const usage=[]; let lost=false; let heartbeatBusy=false;
 const heartbeat=setInterval(async()=>{if(heartbeatBusy)return;heartbeatBusy=true;try{if(!await rpc('heartbeat_chat_reply',{p_task:job.id,p_token:job.lease_token}))lost=true}catch{lost=true}finally{heartbeatBusy=false}},20000);
 try{
  const [agent]=await rows('agents','id,code,title,is_active,system_prompt',{id:job.assigned_agent_id});
  const [conversation]=await rows('conversations','id,created_by,agent_id',{id:job.conversation_id});
  const [request]=await rows('messages','id,conversation_id,sender_type,content,created_at',{id:job.request_message_id});
  if(!agent?.is_active||conversation?.created_by!==job.created_by||conversation.agent_id!==agent.id||request?.conversation_id!==conversation.id||request.sender_type!=='user')throw new Error('INVALID_TASK_BINDING');
  const {data:history,error}=await db.from('messages').select('id,sender_type,content,created_at').eq('conversation_id',conversation.id).lte('created_at',request.created_at).order('created_at',{ascending:false}).order('id',{ascending:false}).limit(20);if(error)throw error;
  const transcript=history.filter(m=>m.id!==request.id).reverse().map(m=>(m.sender_type==='user'?'CEO':agent.code)+': '+m.content).join('\n')+'\nCEO: '+request.content;
  const models=[...new Set([process.env.GEMINI_MODEL||'gemini-3.8-flash',process.env.GEMINI_FALLBACK_MODEL||'gemini-3.5-flash-lite'])];
  let answer;
  for(let index=0;index<models.length;index++){
   if(lost)throw new Error('LEASE_LOST');const model=models[index];const start=Date.now();
   try{
    const result=await ai.interactions.create({model,input:transcript,system_instruction:'You are '+agent.code+' ('+agent.title+') of AI Company OS. Answer the CEO in Chinese within your role. You have no tools or repository access; never claim actions were executed.\n'+(agent.system_prompt||''),generation_config:{thinking_level:'low',max_output_tokens:2400}},{timeout_ms:index===0&&models.length>1?15000:30000,maxRetries:0});
    usage.push({model,status:result.status,duration_ms:Date.now()-start,input_tokens:result.usage?.total_input_tokens??null,output_tokens:result.usage?.total_output_tokens??null,request_id:result.id});
    if(result.status!=='completed'||!result.output_text?.trim())throw new Error('EMPTY_RESPONSE');answer=result.output_text.trim();break;
   }catch(e){if(!usage.some(u=>u.model===model))usage.push({model,status:'failed',duration_ms:Date.now()-start,input_tokens:null,output_tokens:null});if(index===models.length-1||!transient(e))throw e;console.info('MODEL_FALLBACK',{task:job.id,model})}
  }
  if(lost)throw new Error('LEASE_LOST');
  const mid=await rpc('complete_chat_reply',{p_task:job.id,p_token:job.lease_token,p_content:answer,p_usage:usage});console.info('TASK_SUCCEEDED',{task:job.id,message:mid});
 }catch(e){
  const code=e.message==='INVALID_TASK_BINDING'?'invalid_binding':e.message==='LEASE_LOST'?'lease_lost':transient(e)?'provider_unavailable':'execution_failed';
  if(!lost)try{await rpc('fail_chat_reply',{p_task:job.id,p_token:job.lease_token,p_code:code,p_retry:transient(e),p_usage:usage})}catch{console.error('FAIL_STATE_WRITE',{task:job.id})}
  console.warn('TASK_ATTEMPT_FAILED',{task:job.id,code});
 }finally{clearInterval(heartbeat)}
}
console.info('WORKER_STARTED',{concurrency:1});
while(!stopping){try{await rpc('reap_expired_chat_replies');const jobs=await rpc('claim_chat_reply');if(jobs?.length)await execute(jobs[0]);else await sleep(1500)}catch(e){console.error('WORKER_POLL_FAILED',{code:e.code??'unknown'});await sleep(5000)}}
console.info('WORKER_STOPPED');
