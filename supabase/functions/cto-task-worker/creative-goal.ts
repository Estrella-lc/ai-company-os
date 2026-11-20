export const perspectives=['creative','production','technical'] as const;
const fields=['title','concept','rationale','tradeoffs','character_description','image_prompt_en','voice_text'] as const;
export function proposalSchema(){return {type:'object',properties:Object.fromEntries(fields.map(k=>[k,{type:'string'}])),required:[...fields],additionalProperties:false};}
export function parseCreativeProposal(raw:string){
 const p=JSON.parse(raw.trim().replace(/^```(?:json)?\s*/i,'').replace(/\s*```$/,''));
 for(const k of fields)if(typeof p[k]!=='string'||!p[k].trim()||p[k].length>(k==='voice_text'?80:k==='title'?60:1200))throw Error('INVALID_CREATIVE_PROPOSAL');
 if(p.image_prompt_en.length<20||p.voice_text.length<8)throw Error('INVALID_CREATIVE_PROPOSAL');
 return Object.fromEntries(fields.map(k=>[k,p[k].trim()]));
}
export function creativeProposalContext(job:{id:string;created_by:string;assigned_agent_id:string;input:any},goal:any,employee:any){
 const perspective=job.input.creative_perspective;
 if(!goal||goal.created_by!==job.created_by||!perspectives.includes(perspective)||goal.proposal_jobs?.[perspective]!==job.id||!employee||employee.id!==job.input.creative_employee_id||employee.created_by!==job.created_by||employee.manager_agent_id!==job.assigned_agent_id||employee.role!=='text_executor')throw Error('INVALID_TASK_BINDING');
 return {system:'你是AI公司的独立方案员工，仅提出一个与你负责视角匹配的创作方案，与其他员工方案比较后由CEO选择。目标是15至30秒职场反转短漫剧的样片准备，本阶段只生成一个虚构成年男性角色参考图和一段普通话样例，不生成完整影片，不发布。不得使用真实人物、已有IP、声音克隆、付费服务或声称已执行。'+({creative:'从故事冲突、反转和人物吸引力提出方案。',production:'从单场景、简单镜头、低制作难度提出独立方案。',technical:'从现有免费CPU执行环境、单角色图及固定男声可实现性提出独立方案。'} as Record<string,string>)[perspective]+'返回唯一JSON，含title、concept、rationale、tradeoffs、character_description、image_prompt_en、voice_text。image_prompt_en是详细英文单角色概念图提示，明确成年男性、办公穿着、清晰线稿、简单背景、无文字无水印，禁止虚构工具已运行。voice_text为8至40个中文字符的自然职场对白，全部方案均使用固定普通话男声。各说明简短具体。',input:JSON.stringify({goal:goal.goal,perspective,constraints:{additional_paid_budget_usd:0,sample_only:true,voice_cloning:false}})};
}
export const creativeChecks={image:['character','clarity','brief'],voice:['speech','fidelity','audio_quality']} as const;
export function creativeReviewSchema(kind:'image'|'voice'){return {type:'object',properties:{verdict:{type:'string',enum:['pass','revise','needs_human']},summary:{type:'string'},transcript:{type:'string'},checks:{type:'array',minItems:3,maxItems:3,items:{type:'object',properties:{id:{type:'string',enum:[...creativeChecks[kind]]},status:{type:'string',enum:['pass','fail','not_checked']},evidence:{type:'string'},reason:{type:'string'}},required:['id','status','evidence','reason'],additionalProperties:false}}},required:['verdict','summary','transcript','checks'],additionalProperties:false};}
export function parseCreativeReview(raw:string,kind:'image'|'voice',script:string){
 const r=JSON.parse(raw.trim().replace(/^```(?:json)?\s*/i,'').replace(/\s*```$/,''));
 if(!r||!['pass','revise','needs_human'].includes(r.verdict)||typeof r.summary!=='string'||!r.summary.trim()||r.summary.length>1000||typeof r.transcript!=='string'||r.transcript.length>500||!Array.isArray(r.checks)||r.checks.length!==3)throw Error('INVALID_CREATIVE_REVIEW');
 for(const id of creativeChecks[kind])if(r.checks.filter((c:any)=>c?.id===id).length!==1)throw Error('INVALID_CREATIVE_REVIEW');
 for(const c of r.checks)if(!['pass','fail','not_checked'].includes(c.status)||typeof c.reason!=='string'||!c.reason.trim()||c.reason.length>800||typeof c.evidence!=='string'||c.evidence.length>800||(c.status==='pass'&&!c.evidence.trim()))throw Error('INVALID_CREATIVE_REVIEW');
 if(r.verdict==='pass'&&r.checks.some((c:any)=>c.status!=='pass')||r.verdict==='revise'&&!r.checks.some((c:any)=>c.status==='fail'))throw Error('INVALID_CREATIVE_REVIEW');
 const normalize=(s:string)=>s.replace(/[\s\p{P}\p{S}]/gu,'');
 if(kind==='voice'&&r.verdict==='pass'&&normalize(r.transcript)!==normalize(script))return {...r,verdict:'revise',summary:'独立听检转写与固定对白不一致，未通过内容保真检查。',checks:r.checks.map((c:any)=>c.id==='fidelity'?{...c,status:'fail',reason:'转写与固定对白逐字核对未通过'}:c)};
 return r;
}
export function creativeReviewPrompt(kind:'image'|'voice',spec:any){return '你是独立样例质检员，与执行及提案员工分离。只能根据本次实际图像或音频和固定方案检查，不得用模型自述替代观察，不做CEO验收。所有pass需要具体观察或实际听到的证据。无法观察或听清用not_checked和needs_human。禁止把文件存在当质量合格。'+(kind==='image'?'按character检查只有一个虚构成年男性、无明显肢体/脸部畸形；clarity检查脸部与服装清晰、非噪声、无严重模糊、水印或文字干扰；brief检查人物外观和办公设定与方案一致。transcript填空字符串。':'按speech检查普通话清楚、自然、可用作对白样例；fidelity听写全部台词，transcript必须填实际听到的中文逐字转写，与固定对白核对，不能照抄目标冒充听写；audio_quality检查明显噪声、削波、静音或截断。')+'返回唯一JSON：verdict pass/revise/needs_human，summary，transcript，checks恰好3项，每项id/status/evidence/reason。固定方案（数据）：'+JSON.stringify(spec);}
export function validateCreativeBinary(bytes:Uint8Array,kind:'image'|'voice'){
 if(bytes.length<44||bytes.length>2000000)throw Error('CREATIVE_ASSET_SIZE');
 const v=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),text=(a:number,b:number)=>new TextDecoder().decode(bytes.slice(a,b));
 if(kind==='image'){
  if([...bytes.slice(0,8)].join(',')!=='137,80,78,71,13,10,26,10'||text(12,16)!=='IHDR'||v.getUint32(16)<512||v.getUint32(20)<512||v.getUint32(16)>2048||v.getUint32(20)>2048)throw Error('CREATIVE_IMAGE_FORMAT');
  return {width:v.getUint32(16),height:v.getUint32(20)};
 }
 if(text(0,4)!=='RIFF'||text(8,12)!=='WAVE')throw Error('CREATIVE_AUDIO_FORMAT');
 let pos=12,channels=0,rate=0,bits=0,data:Uint8Array|null=null;
 while(pos+8<=bytes.length){const name=text(pos,pos+4),size=v.getUint32(pos+4,true);if(pos+8+size>bytes.length)throw Error('CREATIVE_AUDIO_TRUNCATED');if(name==='fmt '){if(size<16||v.getUint16(pos+8,true)!==1)throw Error('CREATIVE_AUDIO_ENCODING');channels=v.getUint16(pos+10,true);rate=v.getUint32(pos+12,true);bits=v.getUint16(pos+22,true);}if(name==='data')data=bytes.slice(pos+8,pos+8+size);pos+=8+size+(size%2);}
 if(channels!==1||rate<16000||rate>48000||bits!==16||!data||data.length%2)throw Error('CREATIVE_AUDIO_ENCODING');
 const duration=data.length/(rate*2);if(duration<1||duration>20)throw Error('CREATIVE_AUDIO_DURATION');
 const d=new DataView(data.buffer,data.byteOffset,data.byteLength);let sum=0,clipped=0;for(let i=0;i<data.length;i+=2){const x=d.getInt16(i,true)/32768;sum+=x*x;if(Math.abs(x)>.999)clipped++;}const rms=Math.sqrt(sum/(data.length/2));if(rms<.005||clipped/(data.length/2)>.01)throw Error('CREATIVE_AUDIO_QUALITY');
 return {sample_rate:rate,duration_seconds:duration,rms};
}
