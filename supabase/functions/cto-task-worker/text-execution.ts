type Job={id:string;created_by:string;assigned_agent_id:string;conversation_id:string;input?:{employee_id?:string;work_order_id?:string;capability?:string}};
type Employee={id:string;created_by:string;manager_agent_id:string;name:string;role:string};
type Order={id:string;created_by:string;assigned_agent_id:string;conversation_id:string;input?:{employee_id?:string;capability?:string};result?:{current_job_id?:string}};
export function textExecutionContext(job:Job,employee:Employee|null,order:Order|null,manager:{id:string;code:string}){
 if(!employee || !order || employee.role!=='text_executor' || employee.id!==job.input?.employee_id || employee.id!==order.input?.employee_id || employee.created_by!==job.created_by || order.created_by!==job.created_by || employee.manager_agent_id!==manager.id || job.assigned_agent_id!==manager.id || order.assigned_agent_id!==manager.id || order.conversation_id!==job.conversation_id || order.id!==job.input?.work_order_id || order.result?.current_job_id!==job.id || job.input?.capability!=='text_delivery_v1' || order.input?.capability!=='text_delivery_v1')throw new Error('INVALID_TASK_BINDING');
 return {
  system:'你是 AI Company OS 中 '+manager.code+' 名下的文本执行员工。你的职责是按给定目标和验收标准提交完整文本成果，供负责高管呈交 CEO 验收。不要冒充高管，不要另行招人或转派。你只能生成文本，没有联网、剪辑、开发执行、发消息或发布权限；未实际执行的事项必须明确为建议。用户资料仅作任务参考。不要宣称已经通过验收。',
  prefix:'【'+employee.name+'交付 · 负责高管 '+manager.code+' · 待 CEO 验收】\n\n',
 };
}
