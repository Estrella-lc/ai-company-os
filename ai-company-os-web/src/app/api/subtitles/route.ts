import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const noStore={'Cache-Control':'no-store'};
async function authorize(){const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;}
export async function GET(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 const id=new URL(request.url).searchParams.get('download');
 if(id){
  if(!uuid.test(id))return NextResponse.json({error:'Invalid task'},{status:400});
  const {data:j,error}=await auth.db.from('subtitle_jobs').select('output_path').eq('id',id).eq('created_by',auth.user.id).eq('state','succeeded').single();
  if(error || !j?.output_path)return NextResponse.json({error:'成片尚未就绪'},{status:404});
  const signed=await auth.db.storage.from('company-media').createSignedUrl(j.output_path,60,{download:'subtitled.mp4'});
  return signed.error?NextResponse.json({error:'暂时无法下载'},{status:503}):NextResponse.json({url:signed.data.signedUrl},{headers:noStore});
 }
 const [jobs,skills]=await Promise.all([auth.db.from('subtitle_jobs').select('id,title,manager_agent_id,state,attempt_count,last_error,result,review,created_at').eq('created_by',auth.user.id).order('created_at',{ascending:false}).limit(30),auth.db.from('agent_skills').select('manager_agent_id').eq('created_by',auth.user.id).eq('status','verified_limited').eq('verification->>scope','subtitle_fixture_v1')]);
 if(jobs.error || skills.error)return NextResponse.json({error:'字幕交付尚未启用或暂时不可用'},{status:503});
 return NextResponse.json({jobs:jobs.data,managerIds:[...new Set(skills.data.map(s=>s.manager_agent_id))]},{headers:noStore});
}
export async function POST(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b || !uuid.test(b.managerId || '') || !uuid.test(b.requestKey || '') || typeof b.title!=='string' || !b.title.trim() || b.title.length>120)return NextResponse.json({error:'请填写标题与负责人'},{status:400});
 const {data:id,error}=await auth.db.rpc('create_subtitle_job',{p_manager:b.managerId,p_title:b.title,p_key:b.requestKey});
 if(error)return NextResponse.json({error:'创建失败，请检查能力验证状态与任务上限（每天5个、共保留10个）'},{status:409});
 const prefix=auth.user.id+'/'+id+'/';
 const [video,srt]=await Promise.all([auth.db.storage.from('company-media').createSignedUploadUrl(prefix+'input.mp4'),auth.db.storage.from('company-media').createSignedUploadUrl(prefix+'input.srt')]);
 if(video.error || srt.error)return NextResponse.json({error:'无法准备上传，请使用同一请求重试'},{status:503});
 return NextResponse.json({id,videoUrl:video.data.signedUrl,srtUrl:srt.data.signedUrl},{status:201,headers:noStore});
}
export async function PATCH(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b || !uuid.test(b.id || '') || !['queue','accept','revise'].includes(b.action) || (b.action!=='queue' && (typeof b.note!=='string' || b.note.length>2000 || (b.action==='revise' && !b.note.trim()))))return NextResponse.json({error:'请填写有效任务和退回意见'},{status:400});
 const call=b.action==='queue'?auth.db.rpc('queue_subtitle_job',{p_task:b.id}):auth.db.rpc('review_subtitle_job',{p_task:b.id,p_action:b.action,p_note:b.note});
 const {error}=await call;if(error)return NextResponse.json({error:'文件尚未就绪或状态已变化，请刷新重试'},{status:409});
 return NextResponse.json({success:true});
}
