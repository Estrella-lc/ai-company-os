import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
async function authorize(){const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;}
const fail=(error:string,status=409)=>NextResponse.json({error},{status});
export async function GET(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);const url=new URL(request.url),id=url.searchParams.get('id');
 if(!id){const r=await a.db.from('company_goals').select('id,title,state,created_at,last_error').eq('created_by',a.user.id).order('created_at',{ascending:false}).limit(30);return r.error?fail('业务目标暂时无法读取',503):NextResponse.json({goals:r.data},{headers:{'Cache-Control':'no-store'}});}
 if(!uuid.test(id))return fail('无效目标',400);
 const g=await a.db.from('company_goals').select('*').eq('id',id).eq('created_by',a.user.id).single();if(g.error)return fail('目标不存在',404);
 const jobs=[...Object.values(g.data.proposal_jobs||{}),...Object.values(g.data.review_jobs||{}),g.data.research_job].filter((x):x is string=>typeof x==='string'&&uuid.test(x));
 const [tasks,messages,usage]=await Promise.all([a.db.from('tasks').select('id,execution_state,attempt_count,last_error_code,input,result,started_at,finished_at').eq('created_by',a.user.id).in('id',jobs),a.db.from('messages').select('reply_task_id,content').in('reply_task_id',jobs),a.db.from('model_usage').select('task_id,model_name,input_tokens,output_tokens,duration_ms,call_status,error_kind,http_status').in('task_id',jobs)]);
 if(tasks.error||messages.error)return fail('目标执行记录暂时无法读取',503);
 const research=tasks.data.find(t=>t.id===g.data.research_job),asset=url.searchParams.get('asset');
 if(asset){
  if(!['image','voice'].includes(asset)||research?.execution_state!=='succeeded')return fail('文件尚未就绪',404);
  const path=research.result?.assets?.[asset+'_path'];if(typeof path!=='string'||!path.startsWith(a.user.id+'/'+research.id+'/'))return fail('文件无效',404);
  const file=await a.db.storage.from('company-creative').download(path);if(file.error)return fail('文件读取失败',503);
  return new NextResponse(await file.data.arrayBuffer(),{headers:{'Content-Type':asset==='image'?'image/png':'audio/wav','Content-Disposition':(url.searchParams.has('download')?'attachment':'inline')+'; filename="'+(asset==='image'?'character-reference.png':'voice-sample.wav')+'"','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'}});
 }
 const safeTasks=tasks.data.map(t=>({id:t.id,state:t.execution_state,attempts:t.attempt_count,error:t.last_error_code,result:t.id===g.data.research_job?t.result:null}));
 return NextResponse.json({goal:g.data,tasks:safeTasks,reports:messages.data.filter(m=>Object.values(g.data.review_jobs||{}).includes(m.reply_task_id)).map(m=>{let report;try{report=JSON.parse(m.content);}catch{report=null;}return {job_id:m.reply_task_id,report};}),usage:usage.data||[],usageUnavailable:!!usage.error},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);let b;try{b=await request.json();}catch{return fail('请求格式错误',400);}
 if(!b||typeof b.title!=='string'||!b.title.trim()||b.title.length>120||typeof b.goal!=='string'||!b.goal.trim()||b.goal.length>3000||!uuid.test(b.requestKey||'')||b.consent!==true)return fail('请填写目标并确认本次处理',400);
 const r=await a.db.rpc('create_company_goal',{p_title:b.title,p_goal:b.goal,p_key:b.requestKey,p_consent:true});return r.error?fail('创建失败，请检查每日3项目标上限或连接状态'):NextResponse.json({id:r.data},{status:201});
}
export async function PATCH(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);let b;try{b=await request.json();}catch{return fail('请求格式错误',400);}
 if(!b||!uuid.test(b.id||''))return fail('无效目标',400);
 let r;
 if(b.action==='select'&&uuid.test(b.proposalJob||''))r=await a.db.rpc('select_company_goal_proposal',{p_goal:b.id,p_job:b.proposalJob});
 else if(b.action==='retry')r=await a.db.rpc('retry_company_goal',{p_goal:b.id});
 else if(b.action==='accept'&&uuid.test(b.researchJob||''))r=await a.db.rpc('accept_company_goal',{p_goal:b.id,p_research:b.researchJob});
 else return fail('无效操作',400);
 return r.error||r.data!==true?fail('状态已变化或未满足验证条件，请刷新核对'):NextResponse.json({success:true});
}
