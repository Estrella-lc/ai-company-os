"use client";
import {useState} from 'react';
import type {skillSample} from '@/lib/skill-sample';
export type Sample=NonNullable<ReturnType<typeof skillSample>>;
export default function SampleDelivery({taskId,sample,reload}:{taskId:string;sample:Sample;reload:()=>Promise<void>}){
 const [note,setNote]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState('');
 async function review(action:'accept'|'revise'){
  if(busy)return;setBusy(true);setError('');
  try{const r=await fetch('/api/skills',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({taskId,action,note})}),d=await r.json();if(!r.ok)throw new Error(d.error || '验收未保存');await reload();setNote('');}catch(e){setError(e instanceof Error?e.message:'验收未保存');}finally{setBusy(false);}
 }
 const accepted=sample.review?.state==='accepted';
 return <section aria-label="字幕样例交付与验收" className="mt-4 rounded-lg border border-emerald-900 bg-emerald-950/20 p-4">
  <h4 className="font-semibold">字幕样例交付与验收</h4>
  <p className="text-sm mt-2">研究员已通过固定适配器生成合成视频样例，可下载检查字幕成片与验证报告。</p>
  <p className="text-xs text-amber-200 mt-2">仅限合成样例；没有处理你的真实素材，也没有运行下载技能的脚本。验收此样例不会将整个商业任务标为完成。</p>
  <ul className="list-disc pl-5 text-sm mt-3">{sample.files.map(f=><li key={f}>{f.split('/').at(-1)}</li>)}</ul>
  <p className="text-xs text-slate-400 mt-2">{sample.duration!==null?sample.duration+' 秒 · ':''}{sample.cues!==null?sample.cues+' 段字幕':''}</p>
  <details className="mt-2 text-xs"><summary>成片校验值 SHA-256</summary><p className="break-all mt-2">{sample.sha256}</p></details>
  <a className="inline-block text-blue-400 text-sm mt-3" href={sample.runUrl} target="_blank" rel="noreferrer">打开交付文件（GitHub Artifacts）</a>
  <p className="text-xs text-slate-400 mt-1">打开运行页底部 Artifacts，下载 skill-research-evidence。文件仅保留1天，可能已过期；验收记录会持续保存。</p>
  <p role="status" className="mt-4 text-sm text-emerald-300">{accepted?'样例已验收':sample.review?.state==='changes_requested'?'已记录退回意见 · 待安排后续执行':'样例待验收'}</p>
  {sample.review && <p className="text-xs text-slate-300 mt-2 whitespace-pre-wrap">{sample.review.note || '未填写补充意见'} · {new Date(sample.review.reviewedAt).toLocaleString()}</p>}
  {!accepted && <div className="mt-3"><label className="block text-sm">样例验收意见<textarea value={note} onChange={e=>setNote(e.target.value)} maxLength={2000} rows={2} className="block mt-2 w-full rounded-lg border border-slate-700 bg-[#0b1020] p-3 text-sm" placeholder="退回时请填写需要改进的内容"/></label><div className="flex gap-3 mt-3"><button disabled={busy} onClick={()=>void review('accept')} className="rounded-lg bg-emerald-700 px-3 py-2 text-sm disabled:opacity-40">通过样例验收</button><button disabled={busy || !note.trim()} onClick={()=>void review('revise')} className="rounded-lg border border-amber-600 px-3 py-2 text-sm disabled:opacity-40">记录退回意见</button></div><p className="text-xs text-slate-400 mt-2">退回会保存意见，本轮不会自动重跑或消耗执行额度。</p></div>}
  {error && <p role="alert" className="mt-3 text-sm text-red-300">{error}</p>}
 </section>;
}
