// Shared contract for COS plans. Plans grant no executable permissions.
export type BusinessStep={id:string;manager_code:string;assignment:string;depends_on:string[];capabilities:string[];acceptance:string[]};
export type BusinessPlan={summary:string;steps:BusinessStep[]};
const bounded=(v:unknown,n:number):v is string=>typeof v==='string'&&v.trim().length>0&&v.length<=n;
export function validateBusinessPlan(value:unknown,managers:string[]):BusinessPlan{
 if(!value||typeof value!=='object')throw new Error('INVALID_BUSINESS_PLAN');
 const p=value as BusinessPlan;
 if(!bounded(p.summary,1000)||!Array.isArray(p.steps)||p.steps.length<1||p.steps.length>8)throw new Error('INVALID_BUSINESS_PLAN');
 const ids=new Set<string>();
 for(const s of p.steps){
  if(!s||!bounded(s.id,32)||!/^[a-z][a-z0-9_]*$/.test(s.id)||ids.has(s.id)||s.manager_code==='COS'||!managers.includes(s.manager_code)||!bounded(s.assignment,2000)||!Array.isArray(s.depends_on)||new Set(s.depends_on).size!==s.depends_on.length||!Array.isArray(s.capabilities)||s.capabilities.length>4||s.capabilities.some(c=>!bounded(c,80)||!/^[a-z][a-z0-9_]*$/.test(c))||!Array.isArray(s.acceptance)||s.acceptance.length<1||s.acceptance.length>8||s.acceptance.some(c=>!bounded(c,500)))throw new Error('INVALID_BUSINESS_STEP');
  ids.add(s.id);
 }
 const visiting=new Set<string>(),done=new Set<string>();
 const visit=(id:string)=>{if(done.has(id))return;if(visiting.has(id))throw new Error('CYCLIC_BUSINESS_PLAN');visiting.add(id);const s=p.steps.find(s=>s.id===id);if(!s)throw new Error('UNKNOWN_DEPENDENCY');for(const dep of s.depends_on)visit(dep);visiting.delete(id);done.add(id);};
 for(const id of ids)visit(id);
 return {summary:p.summary,steps:p.steps.map(s=>({id:s.id,manager_code:s.manager_code,assignment:s.assignment,depends_on:[...s.depends_on],capabilities:[...new Set(s.capabilities)],acceptance:[...s.acceptance]}))};
}
export type SkillEvidence={capability:string;status:string;adapter:string|null;profiles:string[]};
export function routeCapability(capability:string,profile:string,skills:SkillEvidence[],allowedAdapters:string[]){
 const reusable=skills.find(s=>s.capability===capability&&s.status==='verified_limited'&&s.adapter!==null&&allowedAdapters.includes(s.adapter)&&s.profiles.includes(profile));
 return reusable?{action:'reuse' as const,adapter:reusable.adapter,profile}:{action:'research' as const,capability,profile};
}
export type StepEvidence={id:string;state:string;source_job_id:string;quality_source_job_id:string|null;quality_verdict:string|null;producer_id:string;inspector_id:string|null};
export function readyBusinessSteps(plan:BusinessPlan,evidence:StepEvidence[]){
 const byId=new Map(evidence.map(e=>[e.id,e]));
 const passed=(id:string)=>{const e=byId.get(id);return !!e&&e.state==='succeeded'&&e.quality_verdict==='pass'&&e.quality_source_job_id===e.source_job_id&&!!e.inspector_id&&e.inspector_id!==e.producer_id;};
 return plan.steps.filter(s=>!byId.has(s.id)&&s.depends_on.every(passed)).map(s=>s.id);
}
export function businessReadyForCeo(plan:BusinessPlan,evidence:StepEvidence[],integration:{verdict:string;versions:Record<string,string>}|null){
 if(!integration||integration.verdict!=='pass')return false;
 return plan.steps.every(s=>{const e=evidence.find(e=>e.id===s.id);return !!e&&e.state==='succeeded'&&e.quality_verdict==='pass'&&e.source_job_id===e.quality_source_job_id&&integration.versions[s.id]===e.source_job_id&&!!e.inspector_id&&e.inspector_id!==e.producer_id;});
}
