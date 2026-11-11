export type RecordTask = {
  id: string; title: string; assigned_agent_id?: string; manager_agent_id?: string;
  execution_state?: string; state?: string; mode?: string;
  input?: {dependencies?: string[]; plan_id?: string};
  result?: {review_state?: string; current_job_id?: string; work_order_id?: string; connection_status?: string; stage?: string};
  review?: {state?: string}; job?: {execution_state?: string};
};
export type Agent = {id:string;code:string;title:string;is_active:boolean};
export type Employee = {id:string;name:string;manager_agent_id:string;role:string};
export type OverviewInput = {
  work?: {orders?:RecordTask[];jobs?:RecordTask[]};
  planning?: {plans?:RecordTask[];assignments?:RecordTask[];workOrders?:RecordTask[]};
  research?: {jobs?:RecordTask[];employees?:Employee[]};
  media?: {jobs?:RecordTask[]}; integrations?: {jobs?:RecordTask[];connections?:{id:string;name:string;status:string}[]};
  agents?: {agents?:Agent[]};
};
export type OverviewRow = {key:string;title:string;manager:string;kind:string;state:string;phase:number;label:string;href:string;dependencies:{id:string;title:string;accepted:boolean}[]};
function status(execution?:string,review?:string) {
  if(review==='accepted')return {state:'accepted',phase:4,label:'已验收'};
  if(execution==='succeeded')return {state:'review',phase:3,label:'待验收'};
  if(execution==='running')return {state:'running',phase:2,label:'执行中'};
  if(execution==='queued')return {state:'queued',phase:1,label:'排队中'};
  if(execution==='failed')return {state:'failed',phase:2,label:'执行失败'};
  return {state:'unknown',phase:0,label:'状态待确认'};
}
export function overviewRows(data:OverviewInput):OverviewRow[] {
  const assignments=data.planning?.assignments || [], orders=data.work?.orders || [];
  const allOrders=[...orders,...(data.planning?.workOrders || [])];
  function dependencies(a?:RecordTask) {
    return (a?.input?.dependencies || []).map(id=>{
      const step=assignments.find(x=>x.id===id),work=allOrders.find(x=>x.id===step?.result?.work_order_id);
      return {id,title:step?.title || '前置任务（未在当前列表中）',accepted:work?.result?.review_state==='accepted'};
    });
  }
  const rows:OverviewRow[]=orders.map(o=>{
    const assignment=assignments.find(a=>a.result?.work_order_id===o.id);
    const job=data.work?.jobs?.find(j=>j.id===o.result?.current_job_id);
    return {key:'work:'+o.id,title:o.title,manager:o.assigned_agent_id || '',kind:'文本交付',...status(job?.execution_state,o.result?.review_state),href:'/tasks',dependencies:dependencies(assignment)};
  });
  for(const a of assignments) {
    if(orders.some(o=>o.id===a.result?.work_order_id))continue;
    const deps=dependencies(a),started=Boolean(a.result?.work_order_id);
    rows.push({key:'assignment:'+a.id,title:a.title,manager:a.assigned_agent_id || '',kind:'规划分工',state:started?'unknown':deps.every(d=>d.accepted)?'ready':'blocked',phase:0,label:started?'执行记录未在当前列表中':deps.every(d=>d.accepted)?'前置已就绪，待启动':'等待前置验收',href:'/plans',dependencies:deps});
  }
  for(const p of data.planning?.plans || []) {
    if(p.result?.stage==='approved')continue;
    const s=status(p.job?.execution_state);
    rows.push({key:'plan:'+p.id,title:p.title,manager:data.agents?.agents?.find(a=>a.code==='COS')?.id || '',kind:'COS 规划',...s,label:s.state==='review'?'待确认规划':s.label,href:'/plans',dependencies:[]});
  }
  for(const m of data.media?.jobs || [])rows.push({key:'media:'+m.id,title:m.title,manager:m.manager_agent_id || '',kind:'字幕交付',...status(m.state,m.review?.state),...(m.state==='uploading'?{state:'uploading',phase:0,label:'等待素材'}:{}),href:'/subtitles',dependencies:[]});
  for(const [kind,jobs] of [['技能研究',data.research?.jobs || []],['技术接入',data.integrations?.jobs || []]] as const) {
    for(const j of jobs) {
      let s=status(j.execution_state);
      if(j.execution_state==='succeeded')s=j.result?.connection_status==='blocked'?{state:'blocked',phase:2,label:'未接入，需补充条件'}:{state:'completed',phase:4,label:kind==='技能研究'?'研究完成（非业务验收）':j.result?.connection_status==='executed'?'调用完成':j.result?.connection_status==='reused'?'已复用连接':'接入验证通过'};
      rows.push({key:kind+':'+j.id,title:j.title,manager:j.assigned_agent_id || '',kind,...s,href:'/skills',dependencies:[]});
    }
  }
  return rows;
}
