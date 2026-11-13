"use client";
import {useState} from 'react';
export type EmployeeConsultation={id:string;work_order_id:string;source_job_id:string;question:string;state:string;answer:string|null;created_at:string;answered_at:string|null;job:{execution_state:string;attempt_count:number;last_error_code:string|null}};
export function consultationStatus(c:EmployeeConsultation|undefined,currentJob:string){
 if(!c||c.source_job_id!==currentJob)return '';
 if(c.state==='waiting')return ['failed','cancelled'].includes(c.job.execution_state)?'咨询失败':'等待高管答复';
 return c.state==='needs_ceo'?'待CEO补充':c.state==='closed'?'咨询已关闭':'';
}
export default function EmployeeConsultationPanel({record,onUpdate}:{record:EmployeeConsultation;onUpdate:()=>Promise<void>}){
 const [busy,setBusy]=useState(false),[error,setError]=useState('');
 const failed=record.state==='waiting'&&['failed','cancelled'].includes(record.job.execution_state);
 async function action(action:'retry'|'close'){if(busy)return;setBusy(true);setError('');try{const r=await fetch('/api/consultations',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:record.id,action})}),d=await r.json();if(!r.ok)throw new Error(d.error);await onUpdate();}catch(e){setError(e instanceof Error?e.message:'操作失败');}finally{setBusy(false);}}
 return <section className="space-y-5"><header><p className="text-xs text-blue-300 mb-2">员工 → 直属高管</p><h3 className="font-semibold">单次阻塞咨询</h3><p className="text-xs text-slate-400 leading-6 mt-3">每项新任务最多自动咨询一次。咨询不是交付或验收；答复只用于澄清已有条件，不增加外部操作权限。</p></header><div className="rounded-xl border border-slate-700 p-4"><h4 className="text-xs text-slate-400 mb-3">员工提出的问题</h4><p className="whitespace-pre-wrap break-words text-sm leading-7">{record.question}</p></div><div className="rounded-xl border border-slate-700 p-4"><h4 className="text-xs text-slate-400 mb-3">高管答复</h4><p className="whitespace-pre-wrap break-words text-sm leading-7">{record.answer|| (failed?'答复执行失败，任务仍暂停，可重试或关闭咨询。':'正在后台排队或答复，任务已暂停。')}</p></div><p role="status" className="text-sm text-blue-200">{record.state==='resumed'?'已恢复员工执行，成果仍须质检与CEO验收。':record.state==='needs_ceo'?'需要CEO补充资料：请在“质检与验收”填写事实依据后，退回修改并重新执行。':record.state==='closed'?'咨询已关闭，任务需CEO补充意见后重新执行。':'等待高管澄清。'}</p>{failed&&<div className="flex flex-wrap gap-3"><button disabled={busy||record.job.attempt_count>=10} onClick={()=>void action('retry')} className="task-secondary disabled:opacity-40">重试高管答复</button><button disabled={busy} onClick={()=>void action('close')} className="task-secondary">关闭失败咨询</button></div>}{error&&<p role="alert" className="text-sm text-red-300">{error}</p>}<p className="text-xs text-slate-500">{new Date(record.created_at).toLocaleString('zh-CN')} · 已尝试答复 {record.job.attempt_count} 次</p></section>;
}
