import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function GET(request:Request){
 const db=await createClient();const {data:{user}}=await db.auth.getUser();
 if(!user)return NextResponse.json({error:'Unauthorized'},{status:401});
 const {data:ceo,error:authError}=await db.rpc('is_company_ceo',{p_user:user.id});
 if(authError || !ceo)return NextResponse.json({error:'Unauthorized'},{status:403});
 const params=new URL(request.url).searchParams,id=params.get('id'),query=params.get('q');
 if(id && !uuid.test(id) || query!==null && (query.trim().length<2 || query.length>300))return NextResponse.json({error:'无效知识ID或搜索词（2至300字）'},{status:400});
 const headers={'Cache-Control':'private, no-store'};
 if(query && !id){const result=await db.rpc('search_company_knowledge',{p_query:query,p_limit:20});return result.error?NextResponse.json({error:'知识检索暂时不可用'},{status:503}):NextResponse.json({entries:result.data,method:'accepted_keywords_v1'},{headers});}
 let rows=db.from('company_knowledge').select(id?'id,title,body,source_task_id,source_job_id,manager_agent_id,employee_id,created_at':'id,title,source_task_id,source_job_id,manager_agent_id,employee_id,created_at').eq('created_by',user.id);
 if(id)rows=rows.eq('id',id);
 const result=await rows.order('created_at',{ascending:false}).limit(id?1:100);
 return result.error?NextResponse.json({error:'知识库暂时不可用'},{status:503}):NextResponse.json({entries:result.data},{headers});
}
