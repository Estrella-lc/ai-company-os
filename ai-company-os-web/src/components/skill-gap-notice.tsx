import Link from 'next/link';
export default function SkillGapNotice({result}:{result:unknown}){
 const record=result&&typeof result==='object'?(result as {skill_search?:{state?:string;summary?:string}}).skill_search:undefined;
 if(!record||!['waiting','verified','failed'].includes(record.state||''))return null;
 return <aside className="mb-5 rounded-xl border border-blue-900 p-4" aria-label="能力缺口处理"><h3 className="text-sm font-semibold">{record.state==='waiting'?'技能检索与验证中':record.state==='verified'?'已复用验证范围内的公司技能':'能力缺口需要处理'}</h3><p className="text-sm text-slate-300 mt-3">{record.summary}</p><Link href="/skills/research" className="inline-block text-xs text-blue-300 mt-3">查看技能研究报告 →</Link><p className="text-xs text-slate-500 mt-3">找到说明不代表验证通过；技能验证也不代表当前任务已完成或验收。</p></aside>;
}
