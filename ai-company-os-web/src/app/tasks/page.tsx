"use client";
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState } from 'react';
type Agent={id:string;code:string;title:string;is_active:boolean};
type Run={job_id:string;feedback:string|null};
type Order={id:string;title:string;description:string;assigned_agent_id:string;conversation_id:string;input:{acceptance:string;runs:Run[]};result:{review_state:string;current_job_id:string;review_note?:string};created_at:string};
type Job={id:string;execution_state:string;attempt_count:number;last_error_code:string|null};
type Reply={id:string;reply_task_id:string;content:string;created_at:string};
const field='w-full rounded-lg border border-slate-700 bg-[#0b1020] p-3 text-sm';
function status(order:Order,jobs:Job[]) {
 if(order.result.review_state==='accepted') return '已完成';
 const j=jobs.find(x=>x.id===order.result.current_job_id);
 return ({queued:'排队中',running:'执行中',succeeded:'待验收',failed:'执行失败',cancelled:'已取消'} as Record<string,string>)[j?.execution_state || ''] || '读取中';
}
export default function TasksPage(){
 const [agents,setAgents]=useState<Agent[]>([]),[orders,setOrders]=useState<Order[]>([]),[jobs,setJobs]=useState<Job[]>([]),[replies,setReplies]=useState<Reply[]>([]);
 const [selected,setSelected]=useState(''),[title,setTitle]=useState(''),[brief,setBrief]=useState(''),[acceptance,setAcceptance]=useState(''),[agentId,setAgentId]=useState(''),[note,setNote]=useState('');
 const [error,setError]=useState(''),[loading,setLoading]=useState(true),[busy,setBusy]=useState(false);
 const requestKey=useRef(''),sequence=useRef(0);
 const load=useCallback(async()=>{
  const seq=++sequence.current;
  try{
   const response=await fetch('/api/work-orders',{cache:'no-store'}),data=await response.json();
   if(!response.ok) throw new Error(data.error || '无法读取任务');
   if(seq!==sequence.current)return;
   setOrders(data.orders);setJobs(data.jobs);setReplies(data.replies);
   setSelected(old=>old || data.orders[0]?.id || '');
  } catch(e){if(seq===sequence.current)setError(e instanceof Error?e.message:'加载失败');}
  finally{if(seq===sequence.current)setLoading(false);}
 },[]);
 useEffect(()=>{
  let active=true;
  void fetch('/api/agents',{cache:'no-store'}).then(async r=>{const d=await r.json();if(!r.ok)throw new Error('无法读取高管');if(active){setAgents(d.agents.filter((a:Agent)=>a.is_active));setAgentId(d.agents.find((a:Agent)=>a.code==='COS' && a.is_active)?.id || d.agents.find((a:Agent)=>a.is_active)?.id || '');}}).catch(()=>{if(active)setError('无法读取高管，请刷新页面');});
  void load();const timer=setInterval(()=>void load(),5000);
  return()=>{active=false;sequence.current++;clearInterval(timer);};
 },[load]);
 const order=orders.find(w=>w.id===selected);
 const current=jobs.find(j=>j.id===order?.result.current_job_id);
 async function create(e:React.FormEvent<HTMLFormElement>){
  e.preventDefault();if(busy)return;setBusy(true);setError('');
  requestKey.current ||= crypto.randomUUID();
  try{
   const r=await fetch('/api/work-orders',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({title,brief,acceptance,agentId,requestKey:requestKey.current})});const d=await r.json();
   if(!r.ok)throw new Error(d.error || '创建失败');
   setSelected(d.id);setNote('');setTitle('');setBrief('');setAcceptance('');requestKey.current='';await load();
  }catch(e){setError(e instanceof Error?e.message:'创建失败，可重试');}finally{setBusy(false);}
 }
 async function review(action:'accept'|'revise'){
  if(!order || busy)return;setBusy(true);setError('');
  try{
   const r=await fetch('/api/work-orders',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:order.id,jobId:order.result.current_job_id,action,note})});const d=await r.json();
   if(!r.ok)throw new Error(d.error || '操作失败');setNote('');await load();
  }catch(e){setError(e instanceof Error?e.message:'操作失败');}finally{setBusy(false);}
 }
 return <main className="min-h-screen bg-[#0b1020] text-slate-100 p-5 md:p-9">
  <header className="max-w-6xl mx-auto mb-6 flex items-center justify-between gap-4"><div><p className="text-xs text-slate-500">AI COMPANY OS</p><h1 className="text-2xl font-bold mt-2">任务中心</h1><p className="text-sm text-slate-400 mt-2">指定高管产出文本成果，由 CEO 验收。支持退回修改。</p></div><Link href="/" className="text-blue-400 shrink-0">返回 CEO 总部</Link></header>
  {error && <p role="alert" className="max-w-6xl mx-auto mb-4 rounded-lg border border-red-500 p-3 text-red-300">{error}</p>}
  <div className="max-w-6xl mx-auto grid lg:grid-cols-[340px_1fr] gap-6">
   <aside className="space-y-6">
    <form onSubmit={create} onChange={()=>{requestKey.current='';}} className="rounded-xl border border-slate-800 bg-[#151e32] p-5 space-y-4">
     <h2 className="text-lg font-semibold">创建任务</h2>
     <label className="block text-sm">任务名称<input required maxLength={120} value={title} onChange={e=>setTitle(e.target.value)} className={field+' mt-2'} /></label>
     <label className="block text-sm">负责高管<select required value={agentId} onChange={e=>setAgentId(e.target.value)} className={field+' mt-2'}><option value="" disabled>选择高管</option>{agents.map(a=><option key={a.id} value={a.id}>{a.code} · {a.title}</option>)}</select></label>
     <label className="block text-sm">目标与资料<textarea required maxLength={5000} rows={4} value={brief} onChange={e=>setBrief(e.target.value)} className={field+' mt-2'} placeholder="描述业务目标，并提供必要资料" /></label>
     <label className="block text-sm">验收标准<textarea required maxLength={2000} rows={3} value={acceptance} onChange={e=>setAcceptance(e.target.value)} className={field+' mt-2'} placeholder="例如：含受众、脚本和制作清单，500字以内" /></label>
     <button disabled={busy || !agentId} className="w-full bg-blue-600 rounded-lg p-3 disabled:opacity-40">{busy?'处理中...':'创建并开始执行'}</button>
     <p className="text-xs text-slate-400">后台按分钟调度，多任务可能排队。生成成果不等于验收完成。</p>
    </form>
    <section className="rounded-xl border border-slate-800 p-4"><h2 className="font-semibold mb-3">我的任务</h2>{loading && <p>正在读取任务...</p>}{!loading && !orders.length && <p className="text-sm text-slate-400">创建第一个任务，开始交付流程。</p>}
     <div className="space-y-2">{orders.map(w=><button key={w.id} onClick={()=>{setSelected(w.id);setNote('');setError('');}} className={'w-full text-left rounded-lg p-3 border '+(selected===w.id?'border-blue-500 bg-blue-500/10':'border-slate-800')}><span className="block font-medium break-words">{w.title}</span><span className="text-xs text-slate-400">{agents.find(a=>a.id===w.assigned_agent_id)?.code || '高管'} · {status(w,jobs)}</span></button>)}</div>
    </section>
   </aside>
   <section className="rounded-xl border border-slate-800 bg-[#151e32] p-5 min-w-0">
    {!order ? <p className="text-slate-400">选择任务查看进度和成果。</p> : <>
     <div className="flex flex-wrap justify-between gap-3"><h2 className="text-xl font-semibold break-words">{order.title}</h2><span className="text-emerald-400">{status(order,jobs)}</span></div>
     <p className="text-sm text-slate-400 mt-2">负责人：{agents.find(a=>a.id===order.assigned_agent_id)?.code || '高管'}</p>
     <h3 className="font-semibold mt-5">目标与资料</h3><p className="whitespace-pre-wrap break-words mt-2 text-sm">{order.description}</p>
     <h3 className="font-semibold mt-5">验收标准</h3><p className="whitespace-pre-wrap break-words mt-2 text-sm">{order.input.acceptance}</p>
     <h3 className="font-semibold mt-6">交付记录</h3>
     {order.input.runs.map((run,i)=>{const reply=replies.find(r=>r.reply_task_id===run.job_id),job=jobs.find(j=>j.id===run.job_id);return <article key={run.job_id} className="border border-slate-700 rounded-lg p-4 mt-3"><h4 className="font-medium">第 {i+1} 版</h4>{run.feedback && <p className="text-sm text-amber-300 whitespace-pre-wrap mt-2">修改意见：{run.feedback}</p>}{reply?<p className="whitespace-pre-wrap break-words text-sm mt-3">{reply.content}</p>:<p className="text-slate-400 text-sm mt-3">{job?.execution_state==='failed'?'执行失败，可填写意见后重新提交。':job?.execution_state==='cancelled'?'执行已取消。':'后台处理中，刷新页面不会丢失任务。'}</p>}{job?.last_error_code && <p className="text-xs text-amber-300 mt-2">{['queued','running'].includes(job.execution_state)?'自动重试中':'执行记录'}：{job.last_error_code}</p>}</article>})}
     {order.result.review_state==='accepted'?<p className="text-emerald-400 mt-5">CEO 已验收通过。{order.result.review_note && '验收意见：'+order.result.review_note}</p>:<div className="mt-6 border-t border-slate-700 pt-5"><label className="block text-sm">验收或修改意见<textarea value={note} onChange={e=>setNote(e.target.value)} rows={3} maxLength={2000} className={field+' mt-2'} /></label><div className="flex flex-wrap gap-3 mt-3"><button disabled={busy || current?.execution_state!=='succeeded'} onClick={()=>void review('accept')} className="bg-emerald-700 rounded-lg px-4 py-3 disabled:opacity-40">验收通过</button><button disabled={busy || !note.trim() || !['succeeded','failed','cancelled'].includes(current?.execution_state || '')} onClick={()=>void review('revise')} className="border border-amber-500 rounded-lg px-4 py-3 disabled:opacity-40">退回修改并重新执行</button></div></div>}
    </>}
   </section>
  </div>
 </main>;
}

