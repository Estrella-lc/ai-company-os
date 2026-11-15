import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function authorize(){const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;}
const fail=(message:string,status=409)=>NextResponse.json({error:message},{status});
export async function POST(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);
 let b;try{b=await request.json();}catch{return fail('请求格式错误',400);}
 if(!b||!uuid.test(b.requestKey||'')||typeof b.title!=='string'||!b.title.trim()||b.title.length>120||typeof b.goal!=='string'||!b.goal.trim()||b.goal.length>2000||typeof b.sourceName!=='string'||!b.sourceName.trim()||b.sourceName.length>180||!['pdf_extract_v1','docx_extract_v1'].includes(b.profile)||b.consent!==true)return fail('请填写目标、资料并同意本任务文字处理',400);
 const r=await a.db.rpc('create_brief_workflow',{p_title:b.title,p_goal:b.goal,p_name:b.sourceName,p_profile:b.profile,p_key:b.requestKey,p_consent:b.consent});
 if(r.error)return fail('暂时无法创建，请检查服务状态和文档任务上限');
 const f=await a.db.from('brief_workflows').select('document_job_id').eq('id',r.data).eq('created_by',a.user.id).single();
 if(f.error)return fail('任务已创建，请刷新查看');
 return NextResponse.json({id:r.data,documentId:f.data.document_job_id},{status:201});
}
export async function GET(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);
 const url=new URL(request.url),id=url.searchParams.get('id');
 if(!id){const r=await a.db.from('brief_workflows').select('id,title,state,last_error,created_at,work_order_id').eq('created_by',a.user.id).order('created_at',{ascending:false}).limit(30);return r.error?fail('业务任务暂未启用或连接失败',503):NextResponse.json({flows:r.data},{headers:{'Cache-Control':'no-store'}});}
 if(!uuid.test(id))return fail('Invalid workflow',400);
 const r=await a.db.from('brief_workflows').select('id,title,goal,source_name,state,plan,plan_job_id,document_job_id,work_order_id,source_sha256,last_error,model_consent_at,created_at').eq('id',id).eq('created_by',a.user.id).single();
 if(r.error||!r.data)return fail('任务不存在',404);const f=r.data;
 const [doc,order,planning]=await Promise.all([
  a.db.from('document_jobs').select('state,last_error,result,skill_id').eq('id',f.document_job_id).eq('created_by',a.user.id).single(),
  f.work_order_id?a.db.from('tasks').select('id,input,result,assigned_agent_id').eq('id',f.work_order_id).eq('created_by',a.user.id).single():Promise.resolve({data:null,error:null}),
  f.plan_job_id?a.db.from('tasks').select('execution_state,last_error_code').eq('id',f.plan_job_id).eq('created_by',a.user.id).single():Promise.resolve({data:null,error:null}),
 ]);
 if(doc.error||order.error||planning.error)return fail('读取任务进度失败',503);
 const jobId=order.data?.result?.current_job_id;
 const [job,message,quality]=jobId?await Promise.all([
  a.db.from('tasks').select('id,execution_state,last_error_code').eq('id',jobId).eq('created_by',a.user.id).single(),
  a.db.from('messages').select('content').eq('reply_task_id',jobId).maybeSingle(),
  a.db.from('quality_reviews').select('id,employee_id,source_job_id,report,completed_at').eq('source_job_id',jobId).eq('created_by',a.user.id).maybeSingle(),
 ]):[{data:null,error:null},{data:null,error:null},{data:null,error:null}];
 if(job.error||message.error||quality.error)return fail('读取成果失败',503);
 const downloadable=job.data?.execution_state==='succeeded'&&quality.data?.report?.verdict==='pass';
 if(url.searchParams.get('download')==='1'){
  if(!downloadable||!message.data?.content)return fail('当前版本尚未通过独立质检');
  return new NextResponse(message.data.content,{headers:{'Cache-Control':'no-store','Content-Type':'text/plain; charset=utf-8','Content-Disposition':'attachment; filename="project-brief.txt"','X-Content-Type-Options':'nosniff'}});
 }
 return NextResponse.json({flow:f,document:doc.data,planning:planning.data,order:order.data,job:job.data,body:message.data?.content||'',quality:quality.data,downloadable},{headers:{'Cache-Control':'no-store'}});
}
export async function PATCH(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);
 let b;try{b=await request.json();}catch{return fail('请求格式错误',400);}
 if(!b||!uuid.test(b.id||'')||!['submit','accept','revise'].includes(b.action))return fail('任务或操作无效',400);
 const f=await a.db.from('brief_workflows').select('work_order_id').eq('id',b.id).eq('created_by',a.user.id).single();
 if(f.error)return fail('任务不存在',404);
 if(b.action!=='submit'&&(!uuid.test(b.jobId||'')||typeof b.note!=='string'||b.note.length>2000||(b.action==='revise'&&!b.note.trim())))return fail('请提供当前版本和修改意见',400);
 const r=b.action==='submit'?await a.db.rpc('submit_brief_workflow',{p_flow:b.id}):await a.db.rpc('review_work_order',{p_task:f.data.work_order_id,p_job:b.jobId,p_action:b.action,p_note:b.note});
 return r.error?fail('操作未完成：请检查上传、当前版本和独立质检状态'):NextResponse.json({success:true});
}
