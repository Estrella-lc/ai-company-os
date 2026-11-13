import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {isUuid} from '@/lib/projects';
async function authorize(){const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;}
export async function GET(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'请先登录CEO账户'},{status:401});
 const project=new URL(request.url).searchParams.get('project');if(!isUuid(project))return NextResponse.json({error:'无效项目'},{status:400});
 const {data:p,error:pe}=await auth.db.from('company_projects').select('id,plan_id').eq('id',project).eq('created_by',auth.user.id).single();if(pe||!p)return NextResponse.json({error:'项目不可访问'},{status:404});
 const [a,s,d]=await Promise.all([auth.db.from('agents').select('id,code,title,is_active').eq('is_active',true).order('code'),p.plan_id?auth.db.from('tasks').select('assigned_agent_id').eq('created_by',auth.user.id).eq('task_kind','plan_assignment').eq('input->>plan_id',p.plan_id):Promise.resolve({data:[],error:null}),auth.db.from('project_discussions').select('id,project_id,topic,max_rounds,state,created_at,completed_at,project_revision:snapshot->project_revision,sender:agents!project_discussions_sender_agent_id_fkey(code),recipient:agents!project_discussions_recipient_agent_id_fkey(code)').eq('created_by',auth.user.id).eq('project_id',p.id).order('created_at',{ascending:false}).limit(50)]);
 if(a.error||s.error||d.error)return NextResponse.json({error:'协作室暂时不可用'},{status:503});
 const ids=(d.data||[]).map(t=>t.id);
 const {data:turns,error:te}=ids.length?await auth.db.from('discussion_turns').select('id,discussion_id,round_number,phase,content,created_at,completed_at,job_id,agent:agents(code),job:tasks!discussion_turns_job_id_fkey(execution_state,attempt_count,last_error_code)').eq('created_by',auth.user.id).in('discussion_id',ids).order('round_number').order('phase').limit(200):{data:[],error:null};
 if(te)return NextResponse.json({error:'无法读取对话记录'},{status:503});
 return NextResponse.json({participants:(a.data||[]).filter(agent=>agent.code==='COS'||(s.data||[]).some(t=>t.assigned_agent_id===agent.id)),discussions:d.data,turns},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'请先登录CEO账户'},{status:401});let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b||!isUuid(b.projectId)||!isUuid(b.senderId)||!isUuid(b.recipientId)||b.senderId===b.recipientId||!isUuid(b.requestKey)||!Number.isInteger(b.revision)||b.revision<0||![1,2].includes(b.rounds)||typeof b.topic!=='string'||!b.topic.trim()||b.topic.length>2000)return NextResponse.json({error:'请选择两位不同的项目高管并填写议题'},{status:400});
 const {data:id,error}=await auth.db.rpc('start_project_discussion',{p_project:b.projectId,p_revision:b.revision,p_sender:b.senderId,p_recipient:b.recipientId,p_topic:b.topic,p_rounds:b.rounds,p_key:b.requestKey});
 return error?NextResponse.json({error:'请刷新项目版本，确认参与者属于本项目，且没有仍在进行的讨论。'},{status:409}):NextResponse.json({id},{status:201});
}
export async function PATCH(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'请先登录CEO账户'},{status:401});let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b||!isUuid(b.id)||!['retry','close'].includes(b.action))return NextResponse.json({error:'无效讨论'},{status:400});
 const {data:id,error}=await auth.db.rpc(b.action==='retry'?'retry_project_discussion':'close_failed_project_discussion',{p_discussion:b.id});
 return error?NextResponse.json({error:'操作未完成：只能结束已失败的讨论；重试最多允许10次执行尝试。'},{status:409}):NextResponse.json({id});
}
