// Only reachable after the existing trusted-main GitHub OIDC verification.
export async function filmBridge(db:any,rpc:any,body:any,identity:{runner:string;runUrl:string}){
 if(!['film_grants','film_complete','film_fail'].includes(body.action)||!/^[a-f0-9-]{36}$/i.test(body.taskId||'')||!/^[a-f0-9-]{36}$/i.test(body.leaseToken||''))return Response.json({error:'Invalid film lease'},{status:400});
 const binding={p_task:body.taskId,p_token:body.leaseToken,p_runner:identity.runner};
 const f=(await rpc('film_task_context',binding))?.[0];
 if(!f)return Response.json({error:'Film lease denied'},{status:403});
 const path=f.created_by+'/'+body.taskId+'/'+body.leaseToken+'/sample.mp4';
 if(body.action==='film_fail')return Response.json({success:await rpc('finish_film_render',{...binding,p_report:{},p_failed:true})});
 if(body.action==='film_grants'){
  const assets=f.source_snapshot?.assets,spec=f.source_snapshot?.spec;
  if(!assets||!spec?.voice_text||!f.storyboard?.shots)throw Error('FILM_SOURCE_MISSING');
  const grants:any={};
  for(const [kind,key] of [['character','image'],['voice','voice']]){
   const source=assets[key+'_path'];
   if(typeof source!=='string'||!source.startsWith(f.created_by+'/'+f.source_job+'/')||!/^[a-f0-9]{64}$/.test(assets[key]?.sha256||''))throw Error('FILM_SOURCE_BINDING');
   const signed=await db.storage.from('company-creative').createSignedUrl(source,600);
   if(signed.error)throw Error('FILM_INPUT_GRANT');
   grants[kind]={url:signed.data.signedUrl,sha256:assets[key].sha256};
  }
  const upload=await db.storage.from('company-films').createSignedUploadUrl(path);
  if(upload.error)throw Error('FILM_OUTPUT_GRANT');
  return Response.json({...grants,plan:f.storyboard,script:spec.voice_text,uploadUrl:upload.data.signedUrl});
 }
 const r=body.report;
 if(!r||r.technical_passed!==true||r.scope!=='still_image_edit_v1'||r.width!==512||r.height!==768||!Number.isFinite(r.duration)||r.duration<15||r.duration>30||r.independent_film_review!=='required'||r.ceo_acceptance!==false)return Response.json({error:'Film measurements invalid'},{status:400});
 const file=await db.storage.from('company-films').download(path);
 if(file.error||!file.data.size||file.data.size>20971520)throw Error('FILM_OUTPUT_MISSING');
 const bytes=new Uint8Array(await file.data.arrayBuffer());
 const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
 if(hash!==r.sha256||bytes.length!==r.bytes||String.fromCharCode(...bytes.slice(4,8))!=='ftyp')throw Error('FILM_OUTPUT_INTEGRITY');
 const report={technical_passed:true,scope:r.scope,width:r.width,height:r.height,duration:r.duration,bytes:bytes.length,sha256:hash,output_path:path,run_url:identity.runUrl,independent_film_review:'required',ceo_acceptance:false};
 const success=await rpc('finish_film_render',{...binding,p_report:report,p_failed:false});
 return Response.json({success},{status:success?200:409});
}

