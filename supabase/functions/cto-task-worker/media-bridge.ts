// Called only after the existing main-branch GitHub OIDC verifier succeeds.
export async function mediaBridge(db:any,rpc:(name:string,args:Record<string,unknown>)=>Promise<any>,body:any,identity:{runner:string;runUrl:string}){
 if(body.action==='media_claim'){
  const jobs=await rpc('claim_subtitle_job',{p_runner:identity.runner}),j=jobs?.[0];
  if(!j)return Response.json({job:null});
  const prefix=j.created_by+'/'+j.id+'/';
  const storage=db.storage.from('company-media');
  const [video,subtitle,upload]=await Promise.all([storage.createSignedUrl(prefix+'input.mp4',600),storage.createSignedUrl(prefix+'input.srt',600),storage.createSignedUploadUrl(j.output_path)]);
  if(video.error || subtitle.error || upload.error)return Response.json({error:'Media grants unavailable'},{status:503});
  return Response.json({job:{id:j.id,lease_token:j.lease_token,media:{videoUrl:video.data.signedUrl,subtitleUrl:subtitle.data.signedUrl,uploadUrl:upload.data.signedUrl}}});
 }
 if(!['media_complete','media_fail'].includes(body.action) || !/^[0-9a-f-]{36}$/i.test(body.taskId || '') || !/^[0-9a-f-]{36}$/i.test(body.leaseToken || '') || !body.report || typeof body.report!=='object')return Response.json({error:'Invalid media callback'},{status:400});
 // Only a bounded allowlist of measurements is persisted. Never accept a path or URL from a runner.
 const r=body.report,report={passed:r.passed===true,scope:r.scope,duration:r.duration,subtitle_cues:r.subtitle_cues,output_bytes:r.output_bytes,input_sha256:r.input_sha256,srt_sha256:r.srt_sha256,output_sha256:r.output_sha256,third_party_scripts_executed:false,run_url:identity.runUrl};
 const success=await rpc('finish_subtitle_job',{p_task:body.taskId,p_token:body.leaseToken,p_runner:identity.runner,p_report:report,p_failed:body.action==='media_fail'});
 return Response.json({success},{status:success?200:409});
}
