import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {isUuid} from '@/lib/projects';
export async function POST(request:Request){
 const db=await createClient();const {data:{user}}=await db.auth.getUser();
 if(!user)return NextResponse.json({error:'请先登录CEO账户'},{status:401});
 const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});if(!ceo)return NextResponse.json({error:'Unauthorized'},{status:403});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b||!isUuid(b.orderId)||!isUuid(b.jobId))return NextResponse.json({error:'无效任务版本'},{status:400});
 const {data:id,error}=await db.rpc('request_text_quality',{p_order:b.orderId,p_job:b.jobId});
 return error?NextResponse.json({error:'请刷新并确认当前成果已生成。每个交付版本只创建一次质检。'},{status:409}):NextResponse.json({id},{status:201});
}
