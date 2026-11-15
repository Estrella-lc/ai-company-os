import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {readDocumentUpload,documentByteLimit} from '@/lib/document-upload';
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
  const file=await auth.db.storage.from('company-documents').download(j.output_path);
  if(file.error||!file.data||file.data.size>documentByteLimit)return NextResponse.json({error:'暂时无法下载'},{status:503});
  const docx=j.profile==='docx_create_v1';
  return new NextResponse(await file.data.arrayBuffer(),{headers:{'Cache-Control':'no-store','Content-Type':docx?'application/vnd.openxmlformats-officedocument.wordprocessingml.document':'text/plain; charset=utf-8','Content-Disposition':'attachment; filename="'+(docx?'result.docx':'result.txt')+'"','X-Content-Type-Options':'nosniff'}});
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
 return NextResponse.json({id},{status:201,headers:{'Cache-Control':'no-store'}});
}
export async function PUT(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 const id=new URL(request.url).searchParams.get('upload');if(!id||!uuid.test(id))return NextResponse.json({error:'Invalid document job'},{status:400});
 const {data:job,error}=await auth.db.from('document_jobs').select('id,profile,state').eq('id',id).eq('created_by',auth.user.id).single();
 if(error||!job||job.state!=='uploading')return NextResponse.json({error:'上传任务不存在或已提交'},{status:409});
 const claimed=Number(request.headers.get('content-length'));if(claimed>documentByteLimit)return NextResponse.json({error:'文件最多2MB'},{status:413});
 let bytes:Uint8Array;try{bytes=await readDocumentUpload(request.body);}catch{return NextResponse.json({error:'请提供非空且不超过2MB的文件'},{status:413});}
 const contentType=job.profile==='pdf_extract_v1'?'application/pdf':job.profile==='docx_extract_v1'?'application/vnd.openxmlformats-officedocument.wordprocessingml.document':'text/plain';
 const uploaded=await auth.db.storage.from('company-documents').upload(auth.user.id+'/'+job.id+'/input',bytes,{contentType,upsert:false});
 if(uploaded.error){
  if(uploaded.error.message.toLowerCase().includes('already exists')){
   const existing=await auth.db.storage.from('company-documents').download(auth.user.id+'/'+job.id+'/input');
   if(existing.data?.size===bytes.length){const saved=new Uint8Array(await existing.data.arrayBuffer());if(saved.every((value,index)=>value===bytes[index]))return NextResponse.json({id,alreadyUploaded:true});}
   return NextResponse.json({error:'该任务已上传其他内容，请创建新任务；原文件不会被覆盖'},{status:409});
  }
  return NextResponse.json({error:'私有文件上传暂时失败，请保留当前页面重试'},{status:503});
 }
 return NextResponse.json({id},{status:201});
}
export async function PATCH(request:Request){
 const auth=await authorize();if(!auth)return NextResponse.json({error:'Unauthorized'},{status:401});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b||!uuid.test(b.id||'')||!['queue','accept','revise'].includes(b.action)||(b.action!=='queue'&&(typeof b.note!=='string'||b.note.length>2000||(b.action==='revise'&&!b.note.trim()))))return NextResponse.json({error:'请填写有效任务和意见'},{status:400});
 const {error}=await (b.action==='queue'?auth.db.rpc('queue_document_job',{p_task:b.id}):auth.db.rpc('review_document_job',{p_task:b.id,p_action:b.action,p_note:b.note}));
 return error?NextResponse.json({error:'文件未就绪或状态已变化，请刷新重试'},{status:409}):NextResponse.json({success:true});
}

