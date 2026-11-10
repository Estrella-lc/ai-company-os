export type PlanStep={title:string;agent_code:string;instruction:string;acceptance:string;after:number[]};
export type CosPlan={mode:'direct'|'single'|'team';reason:string;missing_information:string[];tasks:PlanStep[]};
export function parseCosPlan(text:string):CosPlan|null {
 try {
  const trimmed=text.trim();
  const raw=trimmed.startsWith('```')?trimmed.replace(/^```(?:json)?\s*/i,'').replace(/\s*```$/,''):trimmed;
  const p=JSON.parse(raw);
  if(!p || !['direct','single','team'].includes(p.mode) || typeof p.reason!=='string' || !Array.isArray(p.missing_information) || !p.missing_information.every((x:unknown)=>typeof x==='string') || !Array.isArray(p.tasks) || p.tasks.length<1 || p.tasks.length>6) return null;
  if(!p.tasks.every((s:PlanStep,i:number)=>s && ['title','agent_code','instruction','acceptance'].every(k=>typeof s[k as keyof PlanStep]==='string') && Array.isArray(s.after) && s.after.every(n=>Number.isInteger(n) && n>=0 && n<i))) return null;
  return p;
 } catch { return null; }
}

