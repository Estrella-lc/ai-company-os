import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function authorize(){const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;}
export async function GET(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});const {db,user}=auth;
 const document=new URL(request.url).searchParams.get('document');
 if(document){
  if(!uuid.test(document))return NextResponse.json({error:'Invalid skill'},{status:400});
  const {data,error}=await db.from('agent_skills').select('name,document').eq('id',document).eq('created_by',user.id).single();
  return error?NextResponse.json({error:'Not found'},{status:404}):NextResponse.json(data,{headers:{'Cache-Control':'no-store'}});
 }
 const [jobs,skills,employees]=await Promise.all([
  db.from('tasks').select('id,title,description,assigned_agent_id,execution_state,input,attempt_count,last_error_code,created_at,started_at,summary:result->>summary,run_url:result->>run_url,reused:result->reused').eq('created_by',user.id).eq('task_kind','skill_research').order('created_at',{ascending:false}).limit(50),
  db.from('agent_skills').select('id,manager_agent_id,employee_id,request_task_id,repository,commit_sha,skill_path,name,description,capability,status,verification,created_at,license:metadata->>license,flags:metadata->flags,dependencies:metadata->dependencies').eq('created_by',user.id).order('created_at',{ascending:false}).limit(100),
  db.from('ai_employees').select('id,name,manager_agent_id,role,created_at').eq('created_by',user.id),
 ]);
 if(jobs.error || skills.error || employees.error)return NextResponse.json({error:'无法读取技能研究记录'},{status:503});
 return NextResponse.json({jobs:jobs.data,skills:skills.data,employees:employees.data,lastRunnerSeen:jobs.data?.map(j=>j.started_at).filter(Boolean).sort().at(-1) || null},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b || !uuid.test(b.managerId || '') || !uuid.test(b.requestKey || '') || typeof b.need!=='string' || !b.need.trim() || b.need.length>4000 || typeof b.query!=='string' || (b.query && !/^[A-Za-z0-9 _-]{2,64}$/.test(b.query)) || (b.planId && !uuid.test(b.planId)))return NextResponse.json({error:'请填写能力需求，搜索词仅用通用英文关键词'},{status:400});
 const {data:id,error}=await auth.db.rpc('request_skill_research',{p_manager:b.managerId,p_need:b.need,p_query:b.query,p_key:b.requestKey,p_plan:b.planId || null});
 if(error)return NextResponse.json({error:'研究请求未创建，请检查负责人、关联计划或当日请求上限'},{status:409});
 return NextResponse.json({id},{status:201});
}

