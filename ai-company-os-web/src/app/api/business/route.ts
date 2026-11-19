import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function authorize(){const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;}
const fail=(error:string,status=409)=>NextResponse.json({error},{status});
export async function GET(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);const url=new URL(request.url),id=url.searchParams.get('id');
 if(id){if(!uuid.test(id))return fail('无效任务',400);const r=await a.db.rpc('business_workflow_status',{p_flow:id});if(r.error)return fail('任务暂时不可用',503);
  if(url.searchParams.has('download')){if(!(r.data.ready||r.data.state==='accepted')||!r.data.final_body)return fail('整体质检尚未通过');return new NextResponse(r.data.final_body,{headers:{'Content-Type':'text/plain; charset=utf-8','Content-Disposition':'attachment; filename="business-delivery.txt"','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});}
  return NextResponse.json(r.data,{headers:{'Cache-Control':'no-store'}});
 }
 const [flows,sources]=await Promise.all([a.db.from('business_workflows').select('id,title,state,last_error,created_at').eq('created_by',a.user.id).order('created_at',{ascending:false}).limit(30),a.db.from('brief_workflows').select('id,title,source_name').eq('created_by',a.user.id).not('source_sha256','is',null).order('created_at',{ascending:false}).limit(20)]);
 if(flows.error||sources.error)return fail('通用编排暂未启用或连接失败',503);return NextResponse.json({flows:flows.data,sources:sources.data},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);let b;try{b=await request.json();}catch{return fail('请求格式错误',400);}
 if(!b||typeof b.title!=='string'||!b.title.trim()||b.title.length>120||typeof b.goal!=='string'||!b.goal.trim()||b.goal.length>3000||!uuid.test(b.requestKey||'')||(b.sourceId&&!uuid.test(b.sourceId))||b.consent!==true)return fail('请填写目标并确认本任务文字处理',400);
 const r=await a.db.rpc('create_business_workflow',{p_title:b.title,p_goal:b.goal,p_source:b.sourceId||null,p_key:b.requestKey,p_consent:true});return r.error?fail('创建失败，请检查资料或每天3项业务任务上限'):NextResponse.json({id:r.data},{status:201});
}
export async function PATCH(request:Request){
 const a=await authorize();if(!a)return fail('Unauthorized',401);let b;try{b=await request.json();}catch{return fail('请求格式错误',400);}
 if(!b||!uuid.test(b.id||'')||!uuid.test(b.version||'')||!['accept','revise'].includes(b.action)||typeof b.note!=='string'||b.note.length>2000||(b.action==='revise'&&!b.note.trim()))return fail('请提供有效版本和意见',400);
 const r=await a.db.rpc('review_business_workflow',{p_flow:b.id,p_action:b.action,p_note:b.note,p_version:b.version});return r.error?fail('当前版本或整体质检未满足要求，请刷新核对'):NextResponse.json({success:true});
}
