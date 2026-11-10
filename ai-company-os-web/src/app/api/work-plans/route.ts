import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { parseCosPlan } from '@/lib/cos-plan';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function authorize(){
 const db=await createClient();const {data:{user}}=await db.auth.getUser();
 if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;
}
export async function GET(){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 const {db,user}=auth;
 const {data:plans,error}=await db.from('tasks').select('id,title,description,input,result,created_at').eq('created_by',user.id).eq('task_kind','work_plan').order('created_at',{ascending:false}).limit(50);
 if(error)return NextResponse.json({error:'无法读取规划'},{status:503});
 const jobs=(plans || []).map(p=>p.result?.current_job_id).filter(Boolean);
 const {data:assignments,error:ae}=await db.from('tasks').select('id,title,description,assigned_agent_id,input,result').eq('created_by',user.id).eq('task_kind','plan_assignment').in('input->>plan_id',(plans || []).map(p=>p.id));
 if(ae)return NextResponse.json({error:'无法读取分工'},{status:503});
 const workIds=(assignments || []).map(a=>a.result?.work_order_id).filter(Boolean);
 const [j,m,w]=await Promise.all([
  jobs.length?db.from('tasks').select('id,execution_state,last_error_code').eq('created_by',user.id).eq('task_kind','chat_reply').in('id',jobs):Promise.resolve({data:[],error:null}),
  jobs.length?db.from('messages').select('reply_task_id,content').in('reply_task_id',jobs):Promise.resolve({data:[],error:null}),
  workIds.length?db.from('tasks').select('id,result,title').eq('created_by',user.id).eq('task_kind','work_order').in('id',workIds):Promise.resolve({data:[],error:null}),
 ]);
 if(j.error || m.error || w.error)return NextResponse.json({error:'无法读取规划进度'},{status:503});
 return NextResponse.json({plans:(plans || []).map(p=>{const reply=m.data?.find(r=>r.reply_task_id===p.result?.current_job_id);return {...p,draft:p.result?.plan || parseCosPlan(reply?.content || ''),raw:reply?.content || '',job:j.data?.find(x=>x.id===p.result?.current_job_id)};}),assignments,workOrders:w.data},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b || typeof b.goal!=='string' || !b.goal.trim() || b.goal.length>4000 || typeof b.acceptance!=='string' || !b.acceptance.trim() || b.acceptance.length>2000 || !uuid.test(b.requestKey || ''))return NextResponse.json({error:'请填写目标和验收标准'},{status:400});
 const {data:id,error}=await auth.db.rpc('create_work_plan',{p_goal:b.goal,p_acceptance:b.acceptance,p_key:b.requestKey});
 if(error)return NextResponse.json({error:'规划创建失败，请检查COS是否启用后重试'},{status:409});
 return NextResponse.json({id},{status:201});
}
export async function PATCH(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b || !uuid.test(b.id || ''))return NextResponse.json({error:'无效规划'},{status:400});
 let result;
 if(b.action==='start')result=await auth.db.rpc('start_plan_assignment',{p_task:b.id});
 else if(['save','approve'].includes(b.action) && Number.isInteger(b.revision) && b.revision>=0 && JSON.stringify(b.plan || {}).length<=40000 && parseCosPlan(JSON.stringify(b.plan))) result=await auth.db.rpc('review_work_plan',{p_task:b.id,p_revision:b.revision,p_plan:b.plan,p_approve:b.action==='approve'});
 else return NextResponse.json({error:'计划格式无效，请检查负责人和依赖关系'},{status:400});
 if(result.error)return NextResponse.json({error:'操作未完成：请刷新确认版本、补齐资料，并确保前置成果已经验收。'},{status:409});
 return NextResponse.json({id:result.data});
}

