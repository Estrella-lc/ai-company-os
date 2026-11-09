import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Context={params:Promise<{id:string}>};
export async function POST(request:Request, context:Context){
 const s=await createClient(); const {data:{user},error}=await s.auth.getUser();
 if(error||!user)return NextResponse.json({error:"Unauthorized"},{status:401});
 const {data:ceo}=await s.rpc("is_company_ceo",{p_user:user.id});
 if(!ceo)return NextResponse.json({error:"Forbidden"},{status:403});
 const {id}=await context.params; let body;
 try{body=await request.json()}catch{return NextResponse.json({error:"Invalid JSON"},{status:400})}
 if(!uuid.test(body.messageId??"")||!uuid.test(body.requestKey??""))return NextResponse.json({error:"Invalid request"},{status:400});
 const {data:c}=await s.from("conversations").select("id").eq("id",id).eq("created_by",user.id).single();
 const {data:m}=await s.from("messages").select("id").eq("id",body.messageId).eq("conversation_id",id).eq("sender_type","user").single();
 if(!c||!m)return NextResponse.json({error:"Not found"},{status:404});
 const {data:taskId,error:enqueueError}=await s.rpc("enqueue_chat_reply",{p_message:body.messageId,p_request_key:body.requestKey});
 if(enqueueError)return NextResponse.json({error:"Unable to queue reply"},{status:enqueueError.code==="42501"?403:409});
 return NextResponse.json({success:true,taskId},{status:202});
}
export async function GET(_request:Request,context:Context){
 const s=await createClient(); const {data:{user},error}=await s.auth.getUser();
 if(error||!user)return NextResponse.json({error:"Unauthorized"},{status:401});
 const {data:ceo}=await s.rpc("is_company_ceo",{p_user:user.id});
 if(!ceo)return NextResponse.json({error:"Forbidden"},{status:403});
 const {id}=await context.params;
 const {data:c}=await s.from("conversations").select("id").eq("id",id).eq("created_by",user.id).single();
 if(!c)return NextResponse.json({error:"Not found"},{status:404});
 const {data,error:queryError}=await s.from("tasks").select("id,request_message_id,execution_state,result,last_error_code,created_at").eq("conversation_id",id).eq("created_by",user.id).eq("task_kind","chat_reply").order("created_at",{ascending:false}).limit(20);
 if(queryError)return NextResponse.json({error:"Unable to load tasks"},{status:503});
 return NextResponse.json({tasks:data},{headers:{"Cache-Control":"no-store"}});
}
