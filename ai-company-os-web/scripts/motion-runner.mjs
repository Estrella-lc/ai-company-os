import {createHash} from 'node:crypto';
import {generateMotion,motionResult} from './motion-provider.mjs';
import {checkedFilmUrl} from './film-runner.mjs';
// Backend must issue this context only for an active OIDC/owner/task lease.
// Not dispatched until the corresponding database and callback deployment passes tests.
export async function runMotionJob(job,api,fetcher=fetch){
 const binding={taskId:job.id,leaseToken:job.lease_token};
 const context=await api({action:'motion_context',...binding});
 if(context.profile!=='text_to_video_5s'||context.allow_external_generation!==true)throw Error('Motion execution not authorized');
 const result=await generateMotion(context.prompt,fetcher,async provider=>{
  const saved=await api({action:'motion_submitted',...binding,provider});
  if(!saved.success)throw Error('Provider job persistence rejected');
 },context.provider_event_id||null);
 if(result.state!=='generated'){
  await api({action:'motion_pending',...binding,provider_event_id:result.event_id});
  return {state:'pending',provider_event_id:result.event_id};
 }
 // Validate the origin even when a caller replaces the provider implementation.
 motionResult('event: complete\ndata: '+JSON.stringify([{video:{url:result.url}},result.seed])+'\n\n');
 const response=await fetcher(result.url,{redirect:'error',signal:AbortSignal.timeout(45000)});
 if(!response.ok||!response.body)throw Error('Motion output unavailable');
 const chunks=[];let length=0;
 for await(const chunk of response.body){length+=chunk.length;if(length>20*1024*1024)throw Error('Motion output too large');chunks.push(chunk);}
 const bytes=Buffer.concat(chunks);
 if(bytes.length<12||bytes.toString('ascii',4,8)!=='ftyp')throw Error('Motion output is not MP4');
 const grant=await api({action:'motion_upload',...binding});
 const upload=await fetcher(checkedFilmUrl(grant.uploadUrl,true),{method:'PUT',headers:{'Content-Type':'video/mp4','x-upsert':'false'},body:bytes,redirect:'error',signal:AbortSignal.timeout(60000)});
 if(!upload.ok)throw Error('Private motion upload failed');
 const saved=await api({action:'motion_complete',...binding,report:{provider:result.provider,provider_event_id:result.event_id,scope:'text_to_video_5s',bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),motion_review:'required',ceo_acceptance:false}});
 if(!saved.success)throw Error('Motion completion rejected');
 return {state:'saved',motion_review:'required'};
}

