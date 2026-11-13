import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {validProjectInput,validStageInput,isUuid} from '@/lib/projects';
async function authorize(){
 const db=await createClient();const {data:{user}}=await db.auth.getUser();
 if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;
}
export async function GET(){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'请先登录CEO账户'},{status:401});
 const {data:projects,error}=await auth.db.from('company_projects').select('id,title,goal,acceptance,integration_acceptance,stages,plan_id,revision,state,integration_state,created_at,updated_at').eq('created_by',auth.user.id).order('created_at',{ascending:false}).limit(100);
 if(error)return NextResponse.json({error:'项目中心暂时不可用，请稍后刷新'},{status:503});
 const ids=projects.map(p=>p.id);
 const {data:checks,error:ce}=ids.length?await auth.db.from('project_checks').select('id,project_id,project_revision,level,stage_index,outcome,evidence,actor_kind,snapshot,created_at').eq('created_by',auth.user.id).in('project_id',ids).order('created_at',{ascending:false}).limit(500):{data:[],error:null};
 if(ce)return NextResponse.json({error:'无法读取验收记录'},{status:503});
 const planIds=projects.map(p=>p.plan_id).filter(Boolean);
 const {data:assignments,error:ae}=planIds.length?await auth.db.from('tasks').select('id,title,assigned_agent_id,input,result').eq('created_by',auth.user.id).eq('task_kind','plan_assignment').in('input->>plan_id',planIds):{data:[],error:null};
 if(ae)return NextResponse.json({error:'无法读取项目分工'},{status:503});
 const orderIds=(assignments||[]).map(a=>a.result?.work_order_id).filter(Boolean);
 const {data:workOrders,error:we}=orderIds.length?await auth.db.from('tasks').select('id,result').eq('created_by',auth.user.id).eq('task_kind','work_order').in('id',orderIds):{data:[],error:null};
 if(we)return NextResponse.json({error:'无法读取项目交付状态'},{status:503});
 return NextResponse.json({projects,checks,assignments,workOrders},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'请先登录CEO账户'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!validProjectInput(b))return NextResponse.json({error:'请填写项目目标、业务成功条件、全流程验证条件和1至8个阶段'},{status:400});
 const {data:id,error}=await auth.db.rpc('create_company_project',{p_title:b.title,p_goal:b.goal,p_acceptance:b.acceptance,p_integration:b.integration,p_stages:b.stages,p_key:b.requestKey});
 return error?NextResponse.json({error:'项目未创建，请检查填写内容后重试'},{status:409}):NextResponse.json({id},{status:201});
}
export async function PATCH(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'请先登录CEO账户'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b || !isUuid(b.id) || !Number.isInteger(b.revision) || b.revision<0)return NextResponse.json({error:'项目或版本无效'},{status:400});
 let result;
 if(b.action==='plan')result=await auth.db.rpc('plan_company_project',{p_project:b.id,p_revision:b.revision});
 else if(b.action==='configure' && isUuid(b.planId) && validStageInput(b.stages,true))result=await auth.db.rpc('configure_company_project',{p_project:b.id,p_revision:b.revision,p_plan:b.planId,p_stages:b.stages});
 else if(b.action==='check' && ['stage','integration','final'].includes(b.level) && ['passed','failed'].includes(b.outcome) && typeof b.evidence==='string' && b.evidence.trim() && b.evidence.length<=4000 && (b.level==='stage'?Number.isInteger(b.stage)&&b.stage>=0&&b.stage<8:b.stage===null))result=await auth.db.rpc('record_project_check',{p_project:b.id,p_revision:b.revision,p_level:b.level,p_stage:b.stage,p_outcome:b.outcome,p_evidence:b.evidence});
 else return NextResponse.json({error:'操作参数无效'},{status:400});
 if(result.error)return NextResponse.json({error:'操作未完成：请刷新版本，确认计划已批准、所有任务已分配阶段、前置阶段及任务已验收。'},{status:409});
 return NextResponse.json({id:result.data});
}
