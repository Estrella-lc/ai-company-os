import {validateCreativeBinary,creativeReviewPrompt,creativeReviewSchema} from './creative-goal.ts';
export async function creativeBridge(db:any,rpc:any,body:any,identity:{runner:string;runUrl:string}){
 if(!/^[a-f0-9-]{36}$/i.test(body.taskId||'')||!/^[a-f0-9-]{36}$/i.test(body.leaseToken||''))return Response.json({error:'Invalid creative lease'},{status:400});
 const binding={p_task:body.taskId,p_token:body.leaseToken,p_runner:identity.runner};
 const j=(await rpc('creative_task_context',binding))?.[0];if(!j)return Response.json({error:'Creative lease denied'},{status:403});
 const prefix=j.created_by+'/'+j.id+'/'+body.leaseToken+'/',storage=db.storage.from('company-creative');
 if(body.action==='creative_uploads'){
  if(j.input.revision_kind==='voice_only'){
   const parent=await db.from('tasks').select('created_by,execution_state,result').eq('id',j.input.revision_parent).eq('created_by',j.created_by).single();
   const old=parent.data?.result?.assets;
   if(parent.error||parent.data.execution_state!=='succeeded'||old?.image?.sha256!==j.input.spec?.preserved_image?.sha256||!old?.image_path?.startsWith(j.created_by+'/'+j.input.revision_parent+'/'))throw Error('CREATIVE_REVISION_BINDING');
   const copied=await storage.copy(old.image_path,prefix+'character.png');if(copied.error)throw Error('CREATIVE_IMAGE_COPY');
   const voice=await storage.createSignedUploadUrl(prefix+'voice.wav');if(voice.error)throw Error('CREATIVE_VOICE_UPLOAD');
   return Response.json({voice:voice.data.signedUrl});
  }
  const [image,voice]=await Promise.all(['character.png','voice.wav'].map(n=>storage.createSignedUploadUrl(prefix+n)));
  if(image.error||voice.error)return Response.json({error:'Private upload unavailable'},{status:503});
  return Response.json({image:image.data.signedUrl,voice:voice.data.signedUrl});
 }
 if(body.action==='creative_fail'){const success=await rpc('finish_creative_samples',{...binding,p_report:{summary:'成熟技术搜索、隔离生成或回存未通过；未登记可用技能。',stage:['search','build','prepare','generate','upload','finish'].includes(body.report?.stage)?body.report.stage:'unknown',error_code:['budget_exhausted','runtime_memory_limit','phase_timeout','filesystem_permission','source_rate_limit','source_access_denied','source_network','technical_quality','reuse_version_changed','runtime_or_callback_failed'].includes(body.report?.code)?body.report.code:'unknown',run_url:identity.runUrl},p_failed:true});return Response.json({success});}
 if(body.action!=='creative_finish')return Response.json({error:'Unknown creative action'},{status:400});
 const r=body.report,m=r?.manifest;
 if(!r||!/^[a-f0-9]{40}$/.test(r.adapter_commit||'')||m?.image?.repository!=='OpenVINO/LCM_Dreamshaper_v7-int8-ov'||!/^[a-f0-9]{40}$/.test(m.image.revision||'')||m.voice?.repository!=='k2-fsa/sherpa-onnx'||!/^[a-f0-9]{64}$/.test(m.voice.sha256||'')||m.data_only!==true||r.verification?.passed!==true||r.verification?.api_cost_usd!==0)return Response.json({error:'Creative provenance rejected'},{status:400});
 const assets:any={image_path:prefix+'character.png',voice_path:prefix+'voice.wav'};
 for(const [kind,name] of [['image','character.png'],['voice','voice.wav']] as const){
  const file=await storage.download(prefix+name);if(file.error||file.data.size>2000000)throw Error('CREATIVE_ASSET_MISSING');
  const bytes=new Uint8Array(await file.data.arrayBuffer()),technical=validateCreativeBinary(bytes,kind);
  const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
  if(hash!==r.verification.files?.[name]?.sha256||bytes.length!==r.verification.files?.[name]?.bytes)throw Error('CREATIVE_ASSET_HASH');
  if(kind==='image'&&j.input.revision_kind==='voice_only'&&hash!==j.input.spec?.preserved_image?.sha256)throw Error('CREATIVE_PRESERVED_IMAGE_HASH');
  assets[kind]={sha256:hash,bytes:bytes.length,...technical};
 }
 const success=await rpc('finish_creative_samples',{...binding,p_report:{verification:r.verification,manifest:m,discovery:r.discovery,adapter_commit:r.adapter_commit,assets,run_url:identity.runUrl},p_failed:false});
 return Response.json({success},{status:success?200:409});
}
export async function creativeReviewContext(db:any,job:any){
 const kind=job.input.creative_review_kind;if(!['image','voice'].includes(kind))throw Error('INVALID_TASK_BINDING');
 const [goal,employee,source]=await Promise.all([
  db.from('company_goals').select('*').eq('id',job.input.creative_goal_id).eq('created_by',job.created_by).single(),
  db.from('ai_employees').select('id,created_by,manager_agent_id,role').eq('id',job.input.creative_employee_id).eq('created_by',job.created_by).single(),
  db.from('tasks').select('id,created_by,execution_state,input,result').eq('id',job.input.creative_source_job).eq('created_by',job.created_by).single()]);
 const g=goal.data,e=employee.data,s=source.data;
 if(goal.error||employee.error||source.error||g.review_jobs?.[kind]!==job.id||g.research_job!==s.id||s.execution_state!=='succeeded'||e.manager_agent_id!==job.assigned_agent_id||e.role!=='quality_inspector'||e.id===s.input.employee_id||g.proposals.some((p:any)=>p.employee_id===e.id))throw Error('INVALID_TASK_BINDING');
 const path=s.result.assets?.[kind+'_path'];if(typeof path!=='string'||!path.startsWith(job.created_by+'/'+s.id+'/'))throw Error('INVALID_TASK_BINDING');
 const f=await db.storage.from('company-creative').download(path);if(f.error||f.data.size>2000000)throw Error('CREATIVE_ASSET_MISSING');const bytes=new Uint8Array(await f.data.arrayBuffer());validateCreativeBinary(bytes,kind);
 const parts:string[]=[];for(let i=0;i<bytes.length;i+=32768)parts.push(String.fromCharCode(...bytes.slice(i,i+32768)));
 return {system:'Independent asset quality inspector. Inspect the actual attached asset; no CEO acceptance or fictional execution claims.',input:creativeReviewPrompt(kind,g.selected_spec),kind:kind as 'image'|'voice',script:g.selected_spec.voice_text,asset:{mimeType:kind==='image'?'image/png':'audio/wav',data:btoa(parts.join(''))}};
}
export async function generateCreativeReview(client:any,p:{model:string;input:string;system:string;kind:'image'|'voice';asset:{mimeType:string;data:string}}){
 const r=await client.models.generateContent({model:p.model,contents:[{role:'user',parts:[{text:p.input},{inlineData:p.asset}]}],config:{systemInstruction:p.system,responseMimeType:'application/json',responseJsonSchema:creativeReviewSchema(p.kind),maxOutputTokens:1800,thinkingConfig:{thinkingLevel:'LOW'},abortSignal:AbortSignal.timeout(45000),httpOptions:{timeout:45000,retryOptions:{attempts:1}}}});
 if(r.candidates?.[0]?.finishReason!=='STOP'||!r.text?.trim())throw Error('MODEL_OUTPUT_INCOMPLETE');
 return {status:'completed',output_text:r.text,id:r.responseId,usage:{total_input_tokens:r.usageMetadata?.promptTokenCount,total_output_tokens:r.usageMetadata?.candidatesTokenCount}};
}
