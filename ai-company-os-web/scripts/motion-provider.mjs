// Bounded public provider adapter. Not activated in production until lease/storage integration.
const origin='https://lightricks-ltx-video-distilled.hf.space';
export function motionRequest(prompt){
 if(typeof prompt!=='string'||!prompt.trim()||prompt.length>1500)throw Error('Invalid motion prompt');
 return {data:[prompt,'static, camera zoom, blurry, distorted',null,null,512,704,'text-to-video',5,9,42,false,1,false]};
}
export function motionResult(sse){
 for(const block of sse.split(/\r?\n\r?\n/)){
  const event=block.match(/^event: (.+)$/m)?.[1];
  if(event==='error')throw Error('Provider generation failed');
  if(event!=='complete')continue;
  const data=JSON.parse(block.match(/^data: (.+)$/m)?.[1]||'null');
  const value=data?.[0]?.video?.url;const url=new URL(value);
  if(url.origin!==origin||url.username||url.password||!url.pathname.startsWith('/gradio_api/file=/tmp/gradio/')||!url.pathname.endsWith('.mp4')||url.search||url.hash)throw Error('Invalid provider output');
  return {url:url.href,seed:data[1],scope:'text_to_video_5s',motion_review:'required',ceo_acceptance:false};
 }
 return null;
}
export async function generateMotion(prompt,fetcher=fetch,persistJob=async()=>{},resumeId=null){
 let id=resumeId;
 if(id!==null&&!/^[a-f0-9]{32}$/.test(id))throw Error('Invalid recovery job');
 if(!id){
 const submit=await fetcher(origin+'/gradio_api/call/text_to_video',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(motionRequest(prompt)),redirect:'error',signal:AbortSignal.timeout(20000)});
 if(!submit.ok)throw Error('Provider submit unavailable');
 id=(await submit.json()).event_id;if(!/^[a-f0-9]{32}$/.test(id||''))throw Error('Invalid provider job');
 // Persist before waiting: a stopped runner must resume the same provider job.
 await persistJob({provider:'Lightricks/ltx-video-distilled',event_id:id});
 }
 // No blind resubmission after timeout: persist event ID for recovery.
 const result={provider:'Lightricks/ltx-video-distilled',event_id:id,state:'submitted'};
 try{
  const response=await fetcher(origin+'/gradio_api/call/text_to_video/'+id,{redirect:'error',signal:AbortSignal.timeout(180000)});
  if(!response.ok||!response.body)throw Error('Provider status unavailable');
  const reader=response.body.getReader(),decoder=new TextDecoder();let text='';
  try{while(true){const {value,done}=await reader.read();if(done)break;text+=decoder.decode(value,{stream:true});if(text.length>65536)throw Error('Provider response too large');const output=motionResult(text);if(output)return {...result,state:'generated',...output};}}finally{await reader.cancel();}
  return {...result,state:'pending',motion_review:'required'};
 }catch(e){return {...result,state:'unverified',error:e instanceof Error?e.message:'Provider unavailable',motion_review:'required'};}
}

