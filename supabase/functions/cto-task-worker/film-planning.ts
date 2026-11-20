import {validateShotPlan} from './film-shot-plan.js';

export function filmPlanningContext(job:any,flow:any,employee:any){
 const phase=job.input?.film_phase;
 const roles:any={storyboard:['CMO','text_executor'],capabilities:['CTO','text_executor'],inspection:['COO','quality_inspector']};
 if(!roles[phase]||!flow||flow.created_by!==job.created_by||flow.employee_jobs?.[phase]!==job.id||job.input.film_workflow_id!==flow.id||!employee||employee.id!==job.input.creative_employee_id||employee.created_by!==job.created_by||employee.manager_agent_id!==job.assigned_agent_id||employee.role!==roles[phase][1])throw Error('INVALID_FILM_BINDING');
 const s=flow.source_snapshot;
 if(!s?.assets?.image?.sha256||!s?.assets?.voice?.sha256)throw Error('INVALID_FILM_SOURCE');
 const assets=[{id:'character',kind:'image',verdict:'pass',sha256:s.assets.image.sha256},{id:'dialogue',kind:'voice',verdict:'pass',sha256:s.assets.voice.sha256,duration:s.assets.voice.duration_seconds,transcript:s.spec.voice_text}];
 const instructions:any={storyboard:'提出2至6个连续镜头，共15至30秒。返回JSON {shots:[{id,start,duration,image,motion,voice,dialogue}]}。image只能character，voice只能dialogue或null；对白必须原文；motion只能still/slow_push/slow_pull。无对白镜头dialogue为空字符串。只能规划静态图剪辑，不能声称已制作影片。',capabilities:'检查固定分镜的技能缺口，优先公司已有能力，再提出成熟技术搜索需求。返回JSON {status:"ready"或"gap",summary,missing_skills:字符串数组}。ready只代表规划可行，不能声称FFmpeg已完成生产接入或素材已生成。',inspection:'独立检查分镜与能力评估，返回JSON {verdict:"pass"或"revise",summary,evidence:字符串数组}。这只是方案检查，不能代替实际影片质检或CEO验收。不得放行截断对白、未验证素材或虚构动画能力。'};
 return {system:'你是AI公司的专职员工，仅履行当前职责。'+instructions[phase],input:JSON.stringify({spec:s.spec,assets,storyboard:flow.storyboard,capabilities:flow.capability_review,previous_rejections:(flow.candidate_history||[]).filter((x:any)=>x.phase===phase).slice(-2)}),phase,assets};
}

export function parseFilmPlanning(raw:string,context:ReturnType<typeof filmPlanningContext>){
 const r=JSON.parse(raw.trim().replace(/^```(?:json)?\s*/i,'').replace(/\s*```$/,''));
 if(context.phase==='storyboard'){validateShotPlan(r,context.assets);return r;}
 if(typeof r.summary!=='string'||!r.summary.trim()||r.summary.length>1200)throw Error('INVALID_FILM_REPORT');
 if(context.phase==='capabilities'){
  if(!['ready','gap'].includes(r.status)||!Array.isArray(r.missing_skills)||r.missing_skills.length>12||r.missing_skills.some((x:any)=>typeof x!=='string'||!x.trim()||x.length>200)||((r.status==='ready')!==(r.missing_skills.length===0)))throw Error('INVALID_FILM_CAPABILITIES');
 }else if(!['pass','revise'].includes(r.verdict)||!Array.isArray(r.evidence)||r.evidence.length<1||r.evidence.length>12||r.evidence.some((x:any)=>typeof x!=='string'||!x.trim()||x.length>500))throw Error('INVALID_FILM_INSPECTION');
 return r;
}

export function filmPlanningSchema(phase:string){
 const str={type:'string'};
 if(phase==='storyboard')return {type:'object',properties:{shots:{type:'array',minItems:2,maxItems:6,items:{type:'object',properties:{id:str,start:{type:'number',minimum:0},duration:{type:'number',minimum:1,maximum:12},image:{type:'string',enum:['character']},motion:{type:'string',enum:['still','slow_push','slow_pull']},voice:{type:['string','null'],enum:['dialogue',null]},dialogue:str},required:['id','start','duration','image','motion','voice','dialogue'],additionalProperties:false}}},required:['shots'],additionalProperties:false};
 if(phase==='capabilities')return {type:'object',properties:{status:{type:'string',enum:['ready','gap']},summary:str,missing_skills:{type:'array',items:str}},required:['status','summary','missing_skills'],additionalProperties:false};
 return {type:'object',properties:{verdict:{type:'string',enum:['pass','revise']},summary:str,evidence:{type:'array',minItems:1,items:str}},required:['verdict','summary','evidence'],additionalProperties:false};
}
export function filmCandidateError(e:unknown){const code=(e as Error)?.message;return ['SHOT_COUNT','SHOT_ID','SHOT_TIMELINE','UNSUPPORTED_MOTION','UNAPPROVED_IMAGE','UNAPPROVED_VOICE','VOICE_FIDELITY_OR_TRUNCATION','MISSING_VOICE','FILM_DURATION','INVALID_FILM_REPORT','INVALID_FILM_CAPABILITIES','INVALID_FILM_INSPECTION'].includes(code)?code:'JSON_FORMAT';}
