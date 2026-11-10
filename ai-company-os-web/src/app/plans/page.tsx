"use client";
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState } from 'react';
import type { CosPlan, PlanStep } from '@/lib/cos-plan';
type Agent={id:string;code:string;title:string;is_active:boolean};
type Planning={id:string;title:string;description:string;input:{acceptance:string};result:{stage:string;revision:number};draft:CosPlan|null;raw:string;job?:{execution_state:string;last_error_code:string|null}};
type Assignment={id:string;title:string;assigned_agent_id:string;input:{plan_id:string;step_index:number;dependencies:string[]};result:{work_order_id?:string}};
type Work={id:string;result:{review_state:string}};
const field='w-full rounded-lg border border-slate-700 bg-[#0b1020] p-3 text-sm';
const modes={direct:'COS 直接处理',single:'单人专业任务',team:'多人协作'};
export default function PlansPage(){
 const [plans,setPlans]=useState<Planning[]>([]),[agents,setAgents]=useState<Agent[]>([]),[assignments,setAssignments]=useState<Assignment[]>([]),[work,setWork]=useState<Work[]>([]);
 const [selected,setSelected]=useState(''),[goal,setGoal]=useState(''),[acceptance,setAcceptance]=useState(''),[draft,setDraft]=useState<CosPlan|null>(null),[draftRev,setDraftRev]=useState(0),[dirty,setDirty]=useState(false);
 const [error,setError]=useState(''),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true);
 const requestKey=useRef(''),sequence=useRef(0);
 const load=useCallback(async()=>{
  const seq=++sequence.current;
  try{const r=await fetch('/api/work-plans',{cache:'no-store'}),d=await r.json();if(!r.ok)throw new Error(d.error || '无法读取规划');if(seq!==sequence.current)return;setPlans(d.plans);setAssignments(d.assignments);setWork(d.workOrders);setSelected(old=>old || d.plans[0]?.id || '');}
  catch(e){if(seq===sequence.current)setError(e instanceof Error?e.message:'加载失败');}finally{if(seq===sequence.current)setLoading(false);}
 },[]);
 useEffect(()=>{
  let active=true;
  void fetch('/api/agents',{cache:'no-store'}).then(async r=>{const d=await r.json();if(!r.ok)throw new Error();if(active)setAgents(d.agents.filter((a:Agent)=>a.is_active));}).catch(()=>{if(active)setError('无法读取高管，请刷新页面');});
  const initial=setTimeout(()=>void load(),0),timer=setInterval(()=>void load(),5000);
  return()=>{active=false;clearTimeout(initial);clearInterval(timer);};
 },[load]);
 const current=plans.find(p=>p.id===selected),serverDraft=JSON.stringify(current?.draft || null),revision=current?.result.revision || 0;
 useEffect(()=>{if(dirty)return;const timer=setTimeout(()=>{setDraft(JSON.parse(serverDraft));setDraftRev(revision);},0);return()=>clearTimeout(timer);},[selected,serverDraft,revision,dirty]);
 const related=assignments.filter(a=>a.input.plan_id===selected).sort((a,b)=>a.input.step_index-b.input.step_index);
 const approved=current?.result.stage==='approved',ready=current?.job?.execution_state==='succeeded';
 function edit(update:CosPlan){setDraft(update);setDirty(true);}
 function editStep(i:number,changes:Partial<PlanStep>){if(draft)edit({...draft,tasks:draft.tasks.map((s,n)=>n===i?{...s,...changes}:s)});}
 async function create(e:React.FormEvent<HTMLFormElement>){
  e.preventDefault();if(busy)return;setBusy(true);setError('');requestKey.current ||= crypto.randomUUID();
  try{const r=await fetch('/api/work-plans',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({goal,acceptance,requestKey:requestKey.current})}),d=await r.json();if(!r.ok)throw new Error(d.error || '创建失败');setSelected(d.id);setDirty(false);setDraft(null);requestKey.current='';await load();}
  catch(e){setError(e instanceof Error?e.message:'创建失败');}finally{setBusy(false);}
 }
 async function action(kind:'save'|'approve'|'start',id=selected){
  if(busy)return;setBusy(true);setError('');
  try{const r=await fetch('/api/work-plans',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,action:kind,revision:draftRev,plan:draft})}),d=await r.json();if(!r.ok)throw new Error(d.error || '操作失败');setDirty(false);await load();}
  catch(e){setError(e instanceof Error?e.message:'操作失败');}finally{setBusy(false);}
 }
 return <main className="min-h-screen bg-[#0b1020] text-slate-100 p-5 md:p-9">
  <header className="max-w-6xl mx-auto mb-6"><p className="text-xs text-slate-500">AI COMPANY OS</p><h1 className="text-2xl font-bold mt-2">COS 任务规划</h1><p className="text-sm text-slate-400 mt-2">先判断处理方式，再确认分工。批准前不会启动执行任务。</p><nav className="flex gap-5 mt-3 text-blue-400"><Link href="/">CEO 总部</Link><Link href="/tasks">任务中心</Link><Link href="/skills">技能研究</Link></nav></header>
  {error && <p role="alert" className="max-w-6xl mx-auto mb-4 border border-red-500 rounded-lg p-3 text-red-300">{error}</p>}
  <div className="max-w-6xl mx-auto grid lg:grid-cols-[320px_1fr] gap-6">
   <aside className="space-y-5">
    <form onSubmit={create} onChange={()=>{requestKey.current='';}} className="border border-slate-800 rounded-xl p-5 bg-[#151e32] space-y-4">
     <h2 className="font-semibold">交给 COS 规划</h2>
     <label className="block text-sm">业务目标与资料<textarea required maxLength={4000} rows={5} value={goal} onChange={e=>setGoal(e.target.value)} className={field+' mt-2'} placeholder="描述要达到的结果，COS会判断是否需要分工" /></label>
     <label className="block text-sm">总验收标准<textarea required maxLength={2000} rows={3} value={acceptance} onChange={e=>setAcceptance(e.target.value)} className={field+' mt-2'} /></label>
     <button disabled={busy} className="bg-blue-600 rounded-lg p-3 w-full disabled:opacity-40">{busy?'处理中...':'生成规划建议'}</button>
     <p className="text-xs text-slate-400">目前可执行文本任务。开发、剪辑和发布工具员工尚未接入。</p>
    </form>
    <section className="border border-slate-800 rounded-xl p-4"><h2 className="font-semibold mb-3">规划记录</h2>{loading && <p>正在读取...</p>}{!loading && !plans.length && <p className="text-sm text-slate-400">提交第一个目标，先规划再执行。</p>}<div className="space-y-2">{plans.map(p=><button key={p.id} onClick={()=>{setSelected(p.id);setDraft(p.draft);setDraftRev(p.result.revision);setDirty(false);setError('');}} className={'w-full text-left rounded-lg border p-3 '+(selected===p.id?'border-blue-500 bg-blue-500/10':'border-slate-800')}><span className="block text-sm break-words">{p.description}</span><span className="text-xs text-slate-400">{p.result.stage==='approved'?'已批准':p.job?.execution_state==='succeeded'?'待确认':p.job?.execution_state==='failed'?'规划失败':'COS规划中'}</span></button>)}</div></section>
   </aside>
   <section className="border border-slate-800 rounded-xl p-5 bg-[#151e32] min-w-0">
    {!current?<p className="text-slate-400">选择规划查看建议和分工。</p>:<>
     <h2 className="text-lg font-semibold break-words">{current.description}</h2><p className="text-sm text-slate-400 mt-3 whitespace-pre-wrap">总验收标准：{current.input.acceptance}</p>
     {!ready && <p className="text-amber-300 mt-4">{current.job?.execution_state==='failed'?'规划生成失败，请补充目标后重新规划。':'COS 正在规划，按分钟调度，刷新不会丢失。'}</p>}
     {ready && !draft && <div className="mt-4"><p className="text-amber-300">COS未返回有效的结构化计划，系统已阻止派发。可重新规划。</p><pre className="text-xs whitespace-pre-wrap break-words mt-3">{current.raw}</pre></div>}
     {draft && <div className="mt-5 space-y-4">
      <label className="block text-sm">处理方式<select disabled={approved} value={draft.mode} onChange={e=>edit({...draft,mode:e.target.value as CosPlan['mode']})} className={field+' mt-2'}>{Object.entries(modes).map(([v,label])=><option key={v} value={v}>{label}</option>)}</select></label>
      <label className="block text-sm">判断原因<textarea disabled={approved} rows={3} maxLength={2000} value={draft.reason} onChange={e=>edit({...draft,reason:e.target.value})} className={field+' mt-2'} /></label>
      <label className="block text-sm">待补充事项（每行一项，解决后可删除）<textarea disabled={approved} rows={2} value={draft.missing_information.join('\n')} onChange={e=>edit({...draft,missing_information:e.target.value.split('\n').filter(x=>x.trim())})} className={field+' mt-2'} /></label>
      {draft.missing_information.length>0 && <p className="text-amber-300 text-sm">请先补齐资料或调整到现有能力范围，再批准。工具能力缺口会自动交给研究员。<Link href="/skills" className="text-blue-400 underline ml-2">查看技能研究</Link></p>}
      <h3 className="font-semibold">建议分工</h3>
      {draft.tasks.map((s,i)=><article key={i} className="rounded-lg border border-slate-700 p-4 space-y-3">
       <h4 className="font-semibold">步骤 {i+1}</h4>
       <label className="block text-sm">步骤 {i+1} 名称<input disabled={approved} maxLength={120} value={s.title} onChange={e=>editStep(i,{title:e.target.value})} className={field+' mt-1'} /></label>
       <label className="block text-sm">步骤 {i+1} 负责人<select disabled={approved} value={s.agent_code} onChange={e=>editStep(i,{agent_code:e.target.value})} className={field+' mt-1'}>{agents.map(a=><option key={a.id} value={a.code}>{a.code} · {a.title}</option>)}</select></label>
       <label className="block text-sm">步骤 {i+1} 工作要求<textarea disabled={approved} rows={3} maxLength={4000} value={s.instruction} onChange={e=>editStep(i,{instruction:e.target.value})} className={field+' mt-1'} /></label>
       <label className="block text-sm">步骤 {i+1} 验收标准<textarea disabled={approved} rows={2} maxLength={2000} value={s.acceptance} onChange={e=>editStep(i,{acceptance:e.target.value})} className={field+' mt-1'} /></label>
       <div className="text-sm"><p>前置步骤（验收后才可执行）</p>{i===0?<p className="text-slate-400">无</p>:draft.tasks.slice(0,i).map((t,n)=><label key={n} className="block mt-2"><input type="checkbox" disabled={approved} checked={s.after.includes(n)} onChange={e=>editStep(i,{after:e.target.checked?[...s.after,n]:s.after.filter(x=>x!==n)})} /> 步骤 {n+1}：{t.title}</label>)}</div>
       {!approved && draft.tasks.length>1 && <button onClick={()=>{const tasks=draft.tasks.filter((_,n)=>n!==i).map(t=>({...t,after:t.after.filter(n=>n!==i).map(n=>n>i?n-1:n)}));edit({...draft,tasks,mode:tasks.length===1?(tasks[0].agent_code==='COS'?'direct':'single'):'team'});}} className="text-red-300 text-sm">删除步骤 {i+1}</button>}
      </article>)}
      {!approved && <div className="space-y-3"><button disabled={draft.tasks.length>=6} onClick={()=>edit({...draft,mode:'team',tasks:[...draft.tasks,{title:'新步骤',agent_code:'COS',instruction:'',acceptance:'',after:[]}]})} className="text-blue-400 disabled:opacity-40">添加步骤</button><p className="text-xs text-slate-400">批准后会创建分工记录并启动无前置依赖的步骤。其余步骤在前置成果验收后，由你点击启动。</p><div className="flex flex-wrap gap-3"><button disabled={busy || !ready} onClick={()=>void action('save')} className="border border-slate-600 rounded-lg p-3 disabled:opacity-40">保存修改</button><button disabled={busy || !ready || draft.missing_information.length>0} onClick={()=>void action('approve')} className="bg-emerald-700 rounded-lg p-3 disabled:opacity-40">批准计划并启动可执行步骤</button></div>{dirty && <p className="text-amber-300 text-sm">有未保存修改；批准时会一并保存。</p>}</div>}
     </div>}
     {!approved && <button onClick={()=>{setGoal(current.description+'\n补充说明：');setAcceptance(current.input.acceptance);requestKey.current='';}} className="text-blue-400 mt-5">补充要求后重新规划</button>}
     {approved && <section className="mt-6 border-t border-slate-700 pt-5"><h3 className="font-semibold text-emerald-400">计划已批准 · 实际分工</h3>{related.map(a=>{const order=work.find(w=>w.id===a.result.work_order_id);const canStart=a.input.dependencies.every(id=>{const previous=assignments.find(s=>s.id===id);return work.find(w=>w.id===previous?.result.work_order_id)?.result.review_state==='accepted';});return <div key={a.id} className="border border-slate-700 rounded-lg p-4 mt-3"><h4 className="font-medium">步骤 {a.input.step_index+1}：{a.title}</h4><p className="text-sm text-slate-400 mt-2">负责人：{agents.find(x=>x.id===a.assigned_agent_id)?.code || '高管'}</p>{a.result.work_order_id?<Link href={'/tasks?task='+a.result.work_order_id} className="text-blue-400 block mt-3">{order?.result.review_state==='accepted'?'已验收 · 查看成果':'已派发 · 查看执行任务'}</Link>:<><p className="text-sm mt-2">{canStart?'前置条件已满足':'等待前置成果验收'}</p><button disabled={busy || !canStart} onClick={()=>void action('start',a.id)} className="bg-blue-600 rounded-lg p-3 mt-3 disabled:opacity-40">启动步骤 {a.input.step_index+1}</button></>}</div>;})}</section>}
    </>}
   </section>
  </div>
 </main>;
}

