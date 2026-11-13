export type ProjectStage={title:string;acceptance:string;task_ids:string[];state:'pending'|'passed'|'failed'};
export type Project={id:string;title:string;goal:string;acceptance:string;integration_acceptance:string;stages:ProjectStage[];plan_id:string|null;revision:number;state:'draft'|'active'|'accepted';integration_state:'pending'|'passed'|'failed'};
export type ProjectCheck={id:string;project_id:string;project_revision:number;level:'stage'|'integration'|'final';stage_index:number|null;outcome:'passed'|'failed';evidence:string;actor_kind:'ceo_manual';snapshot:{task_versions:{assignment_id:string;work_order_id:string|null;job_id:string|null}[]};created_at:string};
export type ProjectAssignment={id:string;title:string;assigned_agent_id:string;input:{plan_id:string;step_index:number;dependencies:string[]};result:{work_order_id?:string}};
export type ProjectWork={id:string;result:{review_state?:string}};
export const isUuid=(v:unknown):v is string=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
function text(v:unknown,max:number){return typeof v==='string'&&v.trim().length>0&&v.length<=max;}
export function validStageInput(v:unknown,bindings=false):v is ProjectStage[]{return Array.isArray(v)&&v.length>=1&&v.length<=8&&v.every(s=>s&&text(s.title,120)&&text(s.acceptance,2000)&&(!bindings||Array.isArray(s.task_ids)&&s.task_ids.length<=6&&s.task_ids.every(isUuid)));}
export function validProjectInput(v:unknown):v is {title:string;goal:string;acceptance:string;integration:string;stages:ProjectStage[];requestKey:string}{
 if(!v||typeof v!=='object')return false;const b=v as Record<string,unknown>;
 return text(b.title,120)&&text(b.goal,4000)&&text(b.acceptance,2000)&&text(b.integration,2000)&&validStageInput(b.stages)&&isUuid(b.requestKey);
}
export function stageDeliveryStatus(stage:ProjectStage,assignments:ProjectAssignment[],work:ProjectWork[]){
 const rows=stage.task_ids.map(id=>{const a=assignments.find(a=>a.id===id);return {id,title:a?.title||'任务记录不可用',orderId:a?.result.work_order_id,accepted:!!a&&work.some(w=>w.id===a.result.work_order_id&&w.result.review_state==='accepted')};});
 return {rows,ready:rows.every(r=>r.accepted),accepted:rows.filter(r=>r.accepted).length};
}
export function projectGate(p:Project,level:'stage'|'integration'|'final',stage:number|null,assignments:ProjectAssignment[],work:ProjectWork[]){
 if(p.state!=='active'||!p.plan_id)return '请先关联已批准的COS计划，并保存阶段分工。';
 if(level==='stage'){
  if(stage===null||!p.stages[stage])return '请选择有效阶段。';
  if(p.stages.slice(0,stage).some(s=>s.state!=='passed'))return '前置阶段尚未通过。';
  if(!stageDeliveryStatus(p.stages[stage],assignments,work).ready)return '本阶段仍有未验收的任务。';
 }else{
  if(p.stages.some(s=>s.state!=='passed'))return '所有阶段通过后才能验证全流程。';
  if(p.stages.some(s=>!stageDeliveryStatus(s,assignments,work).ready))return '仍有未验收的任务。';
  if(level==='final'&&p.integration_state!=='passed')return '全流程验证尚未通过。';
 }
 return '';
}
