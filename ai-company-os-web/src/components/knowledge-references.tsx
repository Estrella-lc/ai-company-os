import Link from 'next/link';
export type KnowledgeReference={id:string;title:string;source_task_id:string;source_job_id:string};
export default function KnowledgeReferences({references}:{references:KnowledgeReference[]}){
 if(!references.length)return null;
 return <details className="mt-3 rounded-lg border border-cyan-900 p-3"><summary className="cursor-pointer text-sm text-cyan-200">本版提供的公司知识参考（{references.length}条）</summary><p className="text-xs text-slate-400 mt-2">来源固定在本次执行；是否采用以成果正文为准。</p><ul className="space-y-3 mt-3">{references.map(r=><li key={r.id} className="text-xs"><Link href={'/knowledge?id='+r.id} className="text-cyan-300 hover:underline">{r.title}</Link><p className="text-slate-500 break-all mt-1">交付版本：{r.source_job_id}</p><Link href={'/tasks?task='+r.source_task_id} className="text-slate-400 underline">查看来源任务</Link></li>)}</ul></details>;
}
