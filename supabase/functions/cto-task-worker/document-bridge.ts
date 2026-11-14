// Reachable only after the existing main-branch GitHub OIDC verification.
export async function documentBridge(db:any,rpc:(name:string,args:Record<string,unknown>)=>Promise<any>,body:any,identity:{runner:string;runUrl:string}){
 if(body.action==='document_claim'){
  const rows=await rpc('claim_document_job',{p_runner:identity.runner}),j=rows?.[0];if(!j)return Response.json({job:null});
  const storage=db.storage.from('company-documents');
  const [input,output]=await Promise.all([storage.createSignedUrl(j.created_by+'/'+j.id+'/input',600),storage.createSignedUploadUrl(j.output_path)]);
  if(input.error||output.error)return Response.json({error:'Document grants unavailable'},{status:503});
  return Response.json({job:{id:j.id,lease_token:j.lease_token,profile:j.profile,inputUrl:input.data.signedUrl,uploadUrl:output.data.signedUrl}});
 }
 const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
 if(!['document_complete','document_fail'].includes(body.action)||!uuid.test(body.taskId||'')||!uuid.test(body.leaseToken||'')||!body.report||typeof body.report!=='object')return Response.json({error:'Invalid document callback'},{status:400});
 const r=body.report,report={passed:r.passed===true,scope:r.scope,input_sha256:r.input_sha256,output_sha256:r.output_sha256,output_bytes:r.output_bytes,characters:r.characters,engine:r.engine,quality_checks:r.quality_checks,limitations:r.limitations,third_party_scripts_executed:false,run_url:identity.runUrl};
 const success=await rpc('finish_document_job',{p_task:body.taskId,p_token:body.leaseToken,p_runner:identity.runner,p_report:report,p_failed:body.action==='document_fail'});
 return Response.json({success},{status:success?200:409});
}
