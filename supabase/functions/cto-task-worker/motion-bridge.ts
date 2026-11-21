export async function motionBridge(db:any,rpc:any,body:any,identity:{runner:string;runUrl:string}){
 if(!['motion_context','motion_submitted','motion_pending','motion_upload','motion_complete'].includes(body.action)||!/^[a-f0-9-]{36}$/i.test(body.taskId||'')||!/^[a-f0-9-]{36}$/i.test(body.leaseToken||''))return Response.json({error:'Invalid motion callback'},{status:400});
 const binding={p_task:body.taskId,p_token:body.leaseToken,p_runner:identity.runner};
 const m=(await rpc('motion_task_context',binding))?.[0];if(!m)return Response.json({error:'Motion lease denied'},{status:403});
 if(body.action==='motion_context')return Response.json({profile:'text_to_video_5s',allow_external_generation:true,prompt:m.prompt,provider_event_id:m.provider_event_id});
 const path=m.created_by+'/'+body.taskId+'/'+body.leaseToken+'/motion.mp4';
 if(body.action==='motion_upload'){
  if(!m.provider_event_id)return Response.json({error:'Missing provider binding'},{status:409});
  const r=await db.storage.from('company-films').createSignedUploadUrl(path);if(r.error)throw Error('MOTION_UPLOAD');return Response.json({uploadUrl:r.data.signedUrl});
 }
 let payload:any={};
 if(body.action==='motion_submitted'){
  if(body.provider?.provider!=='Lightricks/ltx-video-distilled'||!/^[a-f0-9]{32}$/.test(body.provider?.event_id||''))return Response.json({error:'Invalid provider job'},{status:400});payload={event_id:body.provider.event_id};
 }else if(body.action==='motion_complete'){
  const r=body.report;
  if(r?.provider_event_id!==m.provider_event_id||r?.scope!=='text_to_video_5s'||r?.motion_review!=='required'||r?.ceo_acceptance!==false)return Response.json({error:'Invalid motion report'},{status:400});
  const file=await db.storage.from('company-films').download(path);if(file.error||file.data.size>20971520||file.data.size<12)throw Error('MOTION_FILE');
  const bytes=new Uint8Array(await file.data.arrayBuffer());
  const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
  if(hash!==r.sha256||bytes.length!==r.bytes||String.fromCharCode(...bytes.slice(4,8))!=='ftyp')throw Error('MOTION_INTEGRITY');
  payload={provider:'Lightricks/ltx-video-distilled',provider_event_id:m.provider_event_id,output_path:path,sha256:hash,bytes:bytes.length,scope:'text_to_video_5s',motion_review:'required',ceo_acceptance:false,run_url:identity.runUrl};
 }
 const success=await rpc('update_motion_task',{...binding,p_action:body.action.replace('motion_',''),p_payload:payload});return Response.json({success},{status:success?200:409});
}

