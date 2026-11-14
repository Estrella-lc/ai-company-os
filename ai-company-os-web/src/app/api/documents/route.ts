import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const profiles=['pdf_extract_v1','docx_extract_v1','docx_create_v1'];
async function authorize(){const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return null;const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});return ceo?{db,user}:null;}
export async function GET(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 const id=new URL(request.url).searchParams.get('download');
 if(id){
  if(!uuid.test(id))return NextResponse.json({error:'Invalid document job'},{status:400});
  const {data:j,error}=await auth.db.from('document_jobs').select('output_path,profile').eq('id',id).eq('created_by',auth.user.id).eq('state','succeeded').single();
  if(error||!j?.output_path)return NextResponse.json({error:'文件尚未完成'},{status:404});
  const signed=await auth.db.storage.from('company-documents').createSignedUrl(j.output_path,60,{download:j.profile==='docx_create_v1'?'result.docx':'result.txt'});
  return signed.error?NextResponse.json({error:'暂时无法下载'},{status:503}):NextResponse.json({url:signed.data.signedUrl},{headers:{'Cache-Control':'no-store'}});
 }
 const {data:jobs,error}=await auth.db.from('document_jobs').select('id,title,manager_agent_id,profile,state,attempt_count,research_job_id,skill_id,last_error,result,review,created_at').eq('created_by',auth.user.id).order('created_at',{ascending:false}).limit(30);
 if(error)return NextResponse.json({error:'文档执行尚未启用或暂时不可用'},{status:503});
 return NextResponse.json({jobs},{headers:{'Cache-Control':'no-store'}});
}
export async function POST(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b||!uuid.test(b.managerId||'')||!uuid.test(b.requestKey||'')||typeof b.title!=='string'||!b.title.trim()||b.title.length>120||!profiles.includes(b.profile))return NextResponse.json({error:'请填写文档任务和负责人'},{status:400});
 const {data:id,error}=await auth.db.rpc('create_document_job',{p_manager:b.managerId,p_title:b.title,p_profile:b.profile,p_key:b.requestKey});
 if(error)return NextResponse.json({error:'无法创建，请检查负责人和任务上限（每天5个、保留10个）'},{status:409});
 const signed=await auth.db.storage.from('company-documents').createSignedUploadUrl(auth.user.id+'/'+id+'/input');
 return signed.error?NextResponse.json({error:'无法准备上传，请用同一任务重试'},{status:503}):NextResponse.json({id,uploadUrl:signed.data.signedUrl},{status:201,headers:{'Cache-Control':'no-store'}});
}
export async function PATCH(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b||!uuid.test(b.id||'')||!['queue','accept','revise'].includes(b.action)||(b.action!=='queue'&&(typeof b.note!=='string'||b.note.length>2000||(b.action==='revise'&&!b.note.trim()))))return NextResponse.json({error:'请填写有效任务和意见'},{status:400});
 const {error}=await (b.action==='queue'?auth.db.rpc('queue_document_job',{p_task:b.id}):auth.db.rpc('review_document_job',{p_task:b.id,p_action:b.action,p_note:b.note}));
 return error?NextResponse.json({error:'文件未就绪或状态已变化，请刷新重试'},{status:409}):NextResponse.json({success:true});
}
