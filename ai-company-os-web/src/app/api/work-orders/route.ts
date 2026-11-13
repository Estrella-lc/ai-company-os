import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function authorize() {
 const db = await createClient();
 const {data:{user}} = await db.auth.getUser();
 if (!user) return null;
 const {data:ceo} = await db.rpc('is_company_ceo',{p_user:user.id});
 return ceo ? {db,user} : null;
}
export async function GET() {
 const auth = await authorize();
 if (!auth) return NextResponse.json({error:'Unauthorized'},{status:401});
 const {db,user} = auth;
 const {data:orders,error} = await db.from('tasks').select('id,title,description,assigned_agent_id,conversation_id,input,result,created_at,updated_at').eq('created_by',user.id).eq('task_kind','work_order').order('created_at',{ascending:false}).limit(100);
 if (error) return NextResponse.json({error:'无法读取任务'},{status:503});
 const ids = [...new Set((orders || []).flatMap(w => (w.input?.runs || []).map((r:{job_id:string})=>r.job_id)))];
 let jobs: unknown[] = [], replies: unknown[] = [];
 if (ids.length) {
  const [j,m] = await Promise.all([
   db.from('tasks').select('id,execution_state,attempt_count,last_error_code,input').eq('created_by',user.id).eq('task_kind','chat_reply').in('id',ids),
   db.from('messages').select('id,reply_task_id,content,created_at').in('reply_task_id',ids),
  ]);
  if(j.error || m.error) return NextResponse.json({error:'无法读取执行成果'},{status:503});
  jobs=(j.data || []).map(({input,...job})=>({...job,knowledge:Array.isArray(input?.knowledge_context)?input.knowledge_context.map((r:{id:string;title:string;source_task_id:string;source_job_id:string})=>({id:r.id,title:r.title,source_task_id:r.source_task_id,source_job_id:r.source_job_id})):[]})); replies=m.data || [];
 }
 const {data:quality,error:qe}=(orders||[]).length?await db.from('quality_reviews').select('id,work_order_id,source_job_id,report,completed_at,job:tasks!quality_reviews_job_id_fkey(execution_state,last_error_code),employee:ai_employees(name)').eq('created_by',user.id).in('work_order_id',(orders||[]).map(w=>w.id)):{data:[],error:null};
 if(qe)return NextResponse.json({error:'无法读取独立质检状态'},{status:503});
 return NextResponse.json({orders,jobs,replies,quality},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request) {
 const auth = await authorize();
 if (!auth) return NextResponse.json({error:'Unauthorized'},{status:401});
 let b; try { b=await request.json(); } catch { return NextResponse.json({error:'请求格式错误'},{status:400}); }
 if (!b || typeof b.title!=='string' || !b.title.trim() || b.title.length>120 || typeof b.brief!=='string' || !b.brief.trim() || b.brief.length>5000 || typeof b.acceptance!=='string' || !b.acceptance.trim() || b.acceptance.length>2000 || !uuid.test(b.agentId || '') || !uuid.test(b.requestKey || '')) return NextResponse.json({error:'请填写完整任务，目标最多5000字，验收标准最多2000字'},{status:400});
 const {data:id,error}=await auth.db.rpc('create_work_order',{p_title:b.title,p_brief:b.brief,p_acceptance:b.acceptance,p_agent:b.agentId,p_key:b.requestKey});
 if(error) return NextResponse.json({error:'任务创建失败，请检查高管是否启用后重试'},{status:error.code==='22023'?400:409});
 return NextResponse.json({id},{status:201});
}
export async function PATCH(request:Request) {
 const auth = await authorize();
 if (!auth) return NextResponse.json({error:'Unauthorized'},{status:401});
 let b; try { b=await request.json(); } catch { return NextResponse.json({error:'请求格式错误'},{status:400}); }
 if(!b || !uuid.test(b.id || '') || !uuid.test(b.jobId || '') || !['accept','revise'].includes(b.action) || typeof b.note!=='string' || b.note.length>2000 || (b.action==='revise' && !b.note.trim())) return NextResponse.json({error:'退回修改时请填写意见（最多2000字）'},{status:400});
 const {error}=await auth.db.rpc('review_work_order',{p_task:b.id,p_job:b.jobId,p_action:b.action,p_note:b.note});
 if(error) return NextResponse.json({error:'请刷新确认当前版本；新任务须独立质检通过后才能验收，不合格或待人工核实的成果可填写意见退回修改。'},{status:409});
 return NextResponse.json({success:true});
}
