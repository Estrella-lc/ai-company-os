"use client";
import Link from 'next/link';
import SkillGapNotice from '@/components/skill-gap-notice';
import DocumentTasks from '@/components/document-tasks';
import BriefTasks from '@/components/brief-tasks';
import { Suspense, useCallback, useEffect, useRef, useState } from 'react';
import {useRouter,useSearchParams} from 'next/navigation';
import KnowledgeReferences,{type KnowledgeReference} from '@/components/knowledge-references';
import EmployeeConsultationPanel,{consultationStatus,type EmployeeConsultation} from '@/components/employee-consultation';
import QualityReport,{type QualityReview} from '@/components/quality-report';
type Agent={id:string;code:string;title:string;is_active:boolean};
type Run={job_id:string;feedback:string|null};
type Order={id:string;title:string;description:string;assigned_agent_id:string;conversation_id:string;input:{acceptance:string;runs:Run[];employee_id?:string;employee_name?:string;quality_required?:boolean};result:{review_state:string;current_job_id:string;review_note?:string};created_at:string};
type Job={id:string;execution_state:string;attempt_count:number;last_error_code:string|null;knowledge?:KnowledgeReference[]};
type Reply={id:string;reply_task_id:string;content:string;created_at:string};
const field='w-full rounded-lg border border-slate-700 bg-[#0b1020] p-3 text-sm';
function status(order:Order,jobs:Job[],quality:QualityReview[],consultations:EmployeeConsultation[]) {
 if(order.result.review_state==='accepted') return '已完成';
 const skill=(order.result as Order['result']&{skill_search?:{state:string}}).skill_search;
 if(skill?.state==='waiting')return '技能检索与验证中';
 if(skill?.state==='failed')return '技能研究失败';
 const blocking=consultationStatus(consultations.find(c=>c.work_order_id===order.id),order.result.current_job_id);if(blocking)return blocking;
 const j=jobs.find(x=>x.id===order.result.current_job_id);
 if(j?.execution_state==='succeeded' && order.input.quality_required){const q=quality.find(q=>q.source_job_id===order.result.current_job_id);return q?.report?.verdict==='pass'?'待CEO验收':q?.report?.verdict==='revise'?'质检需返工':q?.report?.verdict==='needs_human'?'待人工核实':q?.job?.execution_state==='failed'?'质检失败':'独立质检中';}
 return ({queued:'排队中',running:'执行中',succeeded:'待验收',failed:'执行失败',cancelled:'已取消'} as Record<string,string>)[j?.execution_state || ''] || '读取中';
}
function TasksContent(){
 const params=useSearchParams(),router=useRouter();
 const requestedTask=params.get('task') || '',creating=params.get('new')==='1';
 const [query,setQuery]=useState(''),[filter,setFilter]=useState('all'),[page,setPage]=useState(1),[tab,setTab]=useState('delivery');
 function navigate(id=''){setSelected(id);setNote('');setError('');setTab('delivery');router.push(id?'/tasks?view=text&task='+id:'/tasks?view=text',{scroll:false});}
 const [agents,setAgents]=useState<Agent[]>([]),[orders,setOrders]=useState<Order[]>([]),[jobs,setJobs]=useState<Job[]>([]),[replies,setReplies]=useState<Reply[]>([]);
 const [selected,setSelected]=useState(''),[title,setTitle]=useState(''),[brief,setBrief]=useState(''),[acceptance,setAcceptance]=useState(''),[agentId,setAgentId]=useState(''),[note,setNote]=useState('');
 const [error,setError]=useState(''),[loading,setLoading]=useState(true),[busy,setBusy]=useState(false);
 const [quality,setQuality]=useState<QualityReview[]>([]);
 const [consultations,setConsultations]=useState<EmployeeConsultation[]>([]);
 const requestKey=useRef(''),sequence=useRef(0);
 useEffect(()=>{const timer=setTimeout(()=>{setSelected(requestedTask);setNote('');setTab('delivery');},0);return()=>clearTimeout(timer);},[requestedTask]);

 const load=useCallback(async()=>{
  const seq=++sequence.current;
  try{
   const response=await fetch('/api/work-orders',{cache:'no-store'}),data=await response.json();
   if(!response.ok) throw new Error(data.error || '无法读取任务');
   if(seq!==sequence.current)return;
   setOrders(data.orders);setJobs(data.jobs);setReplies(data.replies);setQuality(data.quality);setConsultations(data.consultations||[]);

  } catch(e){if(seq===sequence.current)setError(e instanceof Error?e.message:'加载失败');}
  finally{if(seq===sequence.current)setLoading(false);}
 },[]);
 useEffect(()=>{
  let active=true;
  void fetch('/api/agents',{cache:'no-store'}).then(async r=>{const d=await r.json();if(!r.ok)throw new Error('无法读取高管');if(active){setAgents(d.agents.filter((a:Agent)=>a.is_active));setAgentId(d.agents.find((a:Agent)=>a.code==='COS' && a.is_active)?.id || d.agents.find((a:Agent)=>a.is_active)?.id || '');}}).catch(()=>{if(active)setError('无法读取高管，请刷新页面');});
  const initial=setTimeout(()=>void load(),0);const timer=setInterval(()=>void load(),5000);
  return()=>{active=false;clearTimeout(initial);clearInterval(timer);};
 },[load]);
 const order=orders.find(w=>w.id===selected);
 const current=jobs.find(j=>j.id===order?.result.current_job_id);
 const consultation=consultations.find(c=>c.work_order_id===order?.id);
 const inspection=quality.find(q=>q.source_job_id===order?.result.current_job_id);
 const manualAllowed=inspection?.report?.verdict==='needs_human'&&!inspection.report.checks.some(c=>c.status==='fail')&&note.trim().length>=20;
 async function inspect(){if(!order||busy)return;setBusy(true);setError('');try{const r=await fetch('/api/quality',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({orderId:order.id,jobId:order.result.current_job_id})}),d=await r.json();if(!r.ok)throw new Error(d.error);await load();}catch(e){setError(e instanceof Error?e.message:'质检未启动');}finally{setBusy(false);}}
 async function create(e:React.FormEvent<HTMLFormElement>){
  e.preventDefault();if(busy)return;setBusy(true);setError('');
  requestKey.current ||= crypto.randomUUID();
  try{
   const r=await fetch('/api/work-orders',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({title,brief,acceptance,agentId,requestKey:requestKey.current})});const d=await r.json();
   if(!r.ok)throw new Error(d.error || '创建失败');
   navigate(d.id);setTitle('');setBrief('');setAcceptance('');requestKey.current='';await load();
  }catch(e){setError(e instanceof Error?e.message:'创建失败，可重试');}finally{setBusy(false);}
 }
 async function review(action:'accept'|'revise'){
  if(!order || busy)return;setBusy(true);setError('');
  try{
   const r=await fetch('/api/work-orders',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:order.id,jobId:order.result.current_job_id,action,note})});const d=await r.json();
   if(!r.ok)throw new Error(d.error || '操作失败');setNote('');await load();
  }catch(e){setError(e instanceof Error?e.message:'操作失败');}finally{setBusy(false);}
 }

 const bucket=(w:Order)=>{const state=status(w,jobs,quality,consultations);return w.result.review_state==='accepted'?'done':state.includes('失败')||state==='已取消'||state==='质检需返工'||state==='待人工核实'||state==='待CEO补充'||state==='咨询已关闭'?'attention':state.includes('验收')?'review':'active';};
 const filters=[['all','全部任务'],['active','执行中'],['review','待验收'],['attention','需处理'],['done','已完成']];
 const visible=orders.filter(w=>(filter==='all'||bucket(w)===filter)&&[w.title,w.input.employee_name,agents.find(a=>a.id===w.assigned_agent_id)?.code].join(' ').toLowerCase().includes(query.toLowerCase()));
 const pages=Math.max(1,Math.ceil(visible.length/10)),safePage=Math.min(page,pages),rows=visible.slice((safePage-1)*10,safePage*10);
 const renderRun=(run:Run,i:number)=>{const reply=replies.find(r=>r.reply_task_id===run.job_id),job=jobs.find(j=>j.id===run.job_id);return <article key={run.job_id} className="space-y-4"><div className="flex flex-wrap justify-between gap-3"><h3 className="font-semibold">第 {i+1} 版成果</h3><span className="text-xs text-slate-500">{job?.execution_state==='succeeded'?'已交付':'执行状态：'+(job?.execution_state||'读取中')}</span></div>{run.feedback&&<p className="rounded-lg bg-amber-500/5 p-4 text-sm text-amber-200 whitespace-pre-wrap">修改意见：{run.feedback}</p>}{reply?<p className="whitespace-pre-wrap break-words text-sm leading-8">{reply.content}</p>:<p role="status" className="text-slate-400 text-sm">{job?.last_error_code==='awaiting_manager'?'员工已提出阻塞咨询，等待直属高管答复。':job?.last_error_code==='consultation_needs_ceo'?'需要CEO补充资料，请查看内部协作。':job?.execution_state==='failed'?'执行失败，可在质检验收中填写意见后重新提交。':job?.execution_state==='cancelled'?'执行已取消。':'后台处理中，离开页面不会丢失任务。'}</p>}<KnowledgeReferences references={job?.knowledge||[]}/>{job?.last_error_code&&<p className="text-xs text-amber-300">执行记录：{job.last_error_code}</p>}</article>;};
 return <main className="space-y-6">
 <header className="workspace-hero"><div><p className="workspace-eyebrow">TASK OPERATIONS</p><h1>{creating?'新建任务':selected?'任务详情':'任务中心'}</h1><p className="workspace-description">{selected?'查看当前成果，再完成独立质检与CEO验收。':'按状态管理交付；复杂目标交给COS拆解，具体工作在这里推进。'}</p></div><div className="flex flex-wrap gap-3">{selected||creating?<button onClick={()=>navigate()} className="task-secondary">← 返回任务列表</button>:<><Link href="/plans" className="task-secondary">COS规划</Link><Link href="/tasks?view=text&new=1" className="task-primary">＋ 新建任务</Link></>}</div></header>
 {error&&<p role="alert" className="rounded-xl border border-red-700 p-4 text-sm text-red-300">{error}</p>}
 {!selected&&!creating&&<nav className="task-tabs"><Link href="/tasks">业务任务</Link><Link href="/tasks?view=text" className="is-active">文本任务</Link><Link href="/tasks?view=documents">文档任务</Link></nav>}
 {creating?<section className="task-panel max-w-3xl mx-auto"><p className="text-sm text-slate-400 mb-6">先明确目标与完成标准，再指定负责高管。</p>    <form onSubmit={create} onChange={()=>{requestKey.current='';}} className="space-y-5">
     <h2 className="text-lg font-semibold">创建任务</h2>
     <label className="block text-sm">任务名称<input required maxLength={120} value={title} onChange={e=>setTitle(e.target.value)} className={field+' mt-2'} /></label>
     <label className="block text-sm">负责高管<select required value={agentId} onChange={e=>setAgentId(e.target.value)} className={field+' mt-2'}><option value="" disabled>选择高管</option>{agents.map(a=><option key={a.id} value={a.id}>{a.code} · {a.title}</option>)}</select></label>
     <label className="block text-sm">目标与资料<textarea required maxLength={5000} rows={4} value={brief} onChange={e=>setBrief(e.target.value)} className={field+' mt-2'} placeholder="描述业务目标，并提供必要资料" /></label>
     <label className="block text-sm">验收标准<textarea required maxLength={2000} rows={3} value={acceptance} onChange={e=>setAcceptance(e.target.value)} className={field+' mt-2'} placeholder="例如：含受众、脚本和制作清单，500字以内" /></label>
     <button disabled={busy || !agentId} className="w-full bg-blue-600 rounded-lg p-3 disabled:opacity-40">{busy?'处理中...':'创建并开始执行'}</button>
     <p className="text-xs text-slate-400">新任务由所选高管自动建立并分配文本执行员；COS任务直接处理。沿用按分钟调度，生成成果不等于验收完成。</p>
    </form></section>:!selected?<>
 <section aria-label="任务状态概览" className="task-metrics">{filters.slice(1).map(([key,label])=><button key={key} aria-pressed={filter===key} onClick={()=>{setFilter(key);setPage(1);}} className={'task-metric '+(filter===key?'is-active':'')}><span>{label}</span><strong>{orders.filter(w=>bucket(w)===key).length}</strong></button>)}</section>
 <section className="task-panel"><div className="flex flex-wrap items-center justify-between gap-4 mb-5"><div><h2 className="text-lg font-semibold">任务列表</h2><p className="text-xs text-slate-500 mt-2">每页10项，点击任务进入独立详情。</p></div><label className="w-full sm:w-72"><span className="sr-only">搜索任务</span><input type="search" value={query} onChange={e=>{setQuery(e.target.value);setPage(1);}} placeholder="搜索名称、员工或高管" className={field}/></label></div><nav aria-label="筛选任务状态" className="task-tabs mb-5">{filters.map(([key,label])=><button key={key} aria-pressed={filter===key} onClick={()=>{setFilter(key);setPage(1);}} className={filter===key?'is-active':''}>{label}{key==='all'?' · '+orders.length:''}</button>)}</nav>
 {loading?<p role="status" className="p-8 text-center text-slate-400">正在读取任务...</p>:!rows.length?<div className="py-12 text-center"><h3 className="font-medium">{orders.length?'没有符合条件的任务':'开始第一项交付'}</h3><p className="text-sm text-slate-400 mt-3">{orders.length?'试试其他状态或搜索词。':'创建任务，或让COS先组织项目分工。'}</p></div>:<div className="task-list">{rows.map(w=><Link key={w.id} href={'/tasks?task='+w.id} className="task-row"><span className="task-row-symbol">{agents.find(a=>a.id===w.assigned_agent_id)?.code||'AI'}</span><span className="min-w-0 flex-1"><strong className="block text-sm break-words">{w.title}</strong><small className="block text-slate-500 mt-2">{w.input.employee_name||'高管直接处理'} · {new Date(w.created_at).toLocaleDateString('zh-CN')} · {w.input.runs.length}版成果</small></span><span className={'task-status '+bucket(w)}>{status(w,jobs,quality,consultations)}</span><span aria-hidden="true" className="text-slate-500">↗</span></Link>)}</div>}
 <div className="flex flex-wrap items-center justify-between gap-4 mt-5 pt-5 border-t border-slate-800 text-xs text-slate-400"><span>共 {visible.length} 项 · 第 {safePage} / {pages} 页</span><div className="flex gap-3"><button className="task-secondary" disabled={safePage<=1} onClick={()=>setPage(safePage-1)}>上一页</button><button className="task-secondary" disabled={safePage>=pages} onClick={()=>setPage(safePage+1)}>下一页</button></div></div></section></>:!order?<section className="task-panel"><p role="status" className="text-slate-400">{loading?'正在读取任务...':'当前任务不存在或不在最近任务列表中。请返回任务列表查看。'}</p></section>:<>
 <section className="task-panel"><div className="flex flex-wrap justify-between gap-4"><div className="min-w-0"><p className="text-xs text-slate-500 mb-3">{agents.find(a=>a.id===order.assigned_agent_id)?.code||'高管'} 负责 · {order.input.employee_name||'高管直接处理'}</p><h2 className="text-xl font-semibold break-words">{order.title}</h2></div><span className={'task-status '+bucket(order)}>{status(order,jobs,quality,consultations)}</span></div><ol className="task-steps" aria-label="交付进度">{['任务已建立','员工执行','独立质检','CEO验收'].map((label,i)=><li key={label} className={(i===0||i===1&&current?.execution_state==='succeeded'||i===2&&inspection?.report?.verdict==='pass'||i===3&&order.result.review_state==='accepted')?'is-complete':''}><span>{i+1}</span>{label}</li>)}</ol></section>
 <nav aria-label="任务详情栏目" className="task-tabs">{[['delivery','当前成果'],['quality','质检与验收'],['brief','任务说明'],['history','版本历史 · '+order.input.runs.length],...(consultation?[['consultation','内部协作']]:[])].map(([key,label])=><button key={key} aria-pressed={tab===key} onClick={()=>setTab(key)} className={tab===key?'is-active':''}>{label}</button>)}</nav>
 <section className="task-panel" aria-label="任务详情内容"><SkillGapNotice result={order.result}/>
 {tab==='consultation'&&consultation&&<EmployeeConsultationPanel record={consultation} currentJobId={order.result.current_job_id} onUpdate={load}/>}
 {tab==='delivery'&&<>{consultation&&<div className="rounded-xl border border-blue-900 bg-blue-500/5 p-4 mb-5"><p className="text-sm text-blue-200">{consultationStatus(consultation,order.result.current_job_id)||'本任务曾向直属高管咨询。'}</p><button onClick={()=>setTab('consultation')} className="text-xs text-blue-300 mt-3">查看内部问答 →</button></div>}{order.input.runs.find(r=>r.job_id===order.result.current_job_id)?renderRun(order.input.runs.find(r=>r.job_id===order.result.current_job_id)!,order.input.runs.findIndex(r=>r.job_id===order.result.current_job_id)):<p className="text-slate-400">当前版本正在准备。</p>}<button onClick={()=>setTab('quality')} className="task-secondary mt-6">查看质检并验收 →</button></>}
 {tab==='brief'&&<>     <h3 className="font-semibold mt-5">目标与资料</h3><p className="whitespace-pre-wrap break-words mt-2 text-sm">{order.description}</p>
     <h3 className="font-semibold mt-5">验收标准</h3><p className="whitespace-pre-wrap break-words mt-2 text-sm">{order.input.acceptance}</p>
</>}
 {tab==='history'&&<><h3 className="font-semibold">交付版本历史</h3><p className="text-xs text-slate-400 mt-2 mb-5">历史版本按需展开，当前成果以任务指定版本为准。</p>{[...order.input.runs].reverse().map((run,n)=><details key={run.job_id} className="border-t border-slate-700 py-4"><summary className="text-sm">第 {order.input.runs.length-n} 版{run.job_id===order.result.current_job_id?' · 当前版本':''}{run.feedback?' · 含修改意见':''}</summary><div className="pt-5">{renderRun(run,order.input.runs.length-n-1)}{quality.find(q=>q.source_job_id===run.job_id)&&<QualityReport review={quality.find(q=>q.source_job_id===run.job_id)!}/>}</div></details>)}</>}
 {tab==='quality'&&<><h3 className="font-semibold">独立质检与CEO二轮验收</h3><p className="text-xs text-slate-400 mt-3 mb-5 leading-6">文本交付后自动质检，明确不合格时最多自动返工1次。质检不代替CEO决定，也不代表项目全流程已经运行。</p>{inspection?<QualityReport review={inspection}/>:<p className="text-sm text-slate-400">{order.input.quality_required?'成果交付后将启动独立质检。':'历史任务沿用原验收规则，可手动补充质检。'}</p>}     {(!inspection || !inspection.report && ['failed','cancelled'].includes(inspection.job?.execution_state)) && current?.execution_state==='succeeded' && <button disabled={busy} onClick={()=>void inspect()} className="border border-indigo-600 rounded-lg p-3 mt-4 text-sm">{inspection?'重试失败的质检':'为当前版本启动独立质检'}</button>}{order.result.review_state==='accepted'?<p className="text-emerald-400 mt-5">CEO 已验收通过。{order.result.review_note && '验收意见：'+order.result.review_note}</p>:<div className="mt-6 border-t border-slate-700 pt-5">{inspection?.report?.verdict==='needs_human' && <p className="text-xs text-amber-200 mb-3">若报告没有明确不合格项，你可实际核查后填写至少20字的证据再验收；无法确认时请退回修改。</p>}<label className="block text-sm">验收或修改意见<textarea value={note} onChange={e=>setNote(e.target.value)} rows={3} maxLength={2000} className={field+' mt-2'} /></label><div className="flex flex-wrap gap-3 mt-3"><button disabled={busy || current?.execution_state!=='succeeded' || !!order.input.quality_required && inspection?.report?.verdict!=='pass' && !manualAllowed} onClick={()=>void review('accept')} className="bg-emerald-700 rounded-lg px-4 py-3 disabled:opacity-40">{inspection?.report?.verdict==='needs_human'?'附人工核查依据后验收':'验收通过'}</button><button disabled={busy || !note.trim() || !['succeeded','failed','cancelled'].includes(current?.execution_state || '')} onClick={()=>void review('revise')} className="border border-amber-500 rounded-lg px-4 py-3 disabled:opacity-40">退回修改并重新执行</button></div></div>}</>}
 </section></>}
 </main>;
}
function TaskEntry(){const params=useSearchParams();return params.get('view')==='documents'?<DocumentTasks/>:params.get('view')==='text'||params.has('task')?<TasksContent/>:<BriefTasks/>;}
export default function TasksPage(){return <Suspense fallback={<p className="p-6">正在读取任务入口...</p>}><TaskEntry/></Suspense>;}
