import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
export async function PATCH(request:Request){
 const db=await createClient(),{data:{user}}=await db.auth.getUser();
 if(!user)return NextResponse.json({error:'Unauthorized'},{status:401});
 const {data:ceo}=await db.rpc('is_company_ceo',{p_user:user.id});
 if(!ceo)return NextResponse.json({error:'Unauthorized'},{status:403});
 let b;try{b=await request.json();}catch{return NextResponse.json({error:'请求格式错误'},{status:400});}
 if(!b||typeof b.id!=='string'||!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(b.id)||!['retry','close'].includes(b.action))return NextResponse.json({error:'咨询操作无效'},{status:400});
 const {error}=await db.rpc(b.action==='retry'?'retry_employee_consultation':'close_employee_consultation',{p_id:b.id});
 if(error)return NextResponse.json({error:'请刷新确认咨询仍处于失败状态，且未超过重试上限。'},{status:409});
 return NextResponse.json({success:true});
}
