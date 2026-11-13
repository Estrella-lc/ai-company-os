"use client";
import Link from 'next/link';
import {useEffect,useState} from 'react';
type Agent={id:string;code:string;name:string;title:string;is_active:boolean};
const responsibilities:Record<string,string>={COS:'判断任务复杂度，拆解目标，组织分工与交接。',CPO:'把需求变成清晰的产品方案与验收标准。',CTO:'评估技术方案，优先研究和复用成熟工具。',CMO:'把产品价值转化为内容与营销方案。',CFO:'梳理预算、成本和业务投入的边界。',COO:'组织执行节奏，关注流程与交付效率。',CDO:'整理数据口径，为业务判断提供依据。',CHRO:'规划组织分工与人员能力需求。',CLO:'梳理合同、合规与业务风险问题。',CRO:'研究收入路径、客户与商业转化。',CSO:'分析方向、优先级与长期竞争策略。'};
export default function Home(){
 const [agents,setAgents]=useState<Agent[]>([]),[loading,setLoading]=useState(true),[error,setError]=useState('');
 useEffect(()=>{const controller=new AbortController();void fetch('/api/agents',{cache:'no-store',signal:controller.signal}).then(async r=>{const d=await r.json();if(!r.ok)throw new Error(r.status===401?'请先登录CEO账户':d.error || '无法读取高管资料');if(!controller.signal.aborted)setAgents(d.agents || []);}).catch(e=>{if(!controller.signal.aborted)setError(e instanceof Error?e.message:'读取失败');}).finally(()=>{if(!controller.signal.aborted)setLoading(false);});return()=>controller.abort();},[]);
 return <main><header className="workspace-hero"><div><p className="workspace-eyebrow">PEOPLE & INTELLIGENCE</p><h1>一支围绕目标工作的高管团队</h1><p className="workspace-description">先向专业角色提问，或把业务目标交给COS组织。高管负责判断与管理，执行员工负责具体交付。</p></div><span className="workspace-outline-tag">{loading?'正在读取组织':agents.filter(a=>a.is_active).length+' 位已启用高管'}</span></header>
  <div className="workspace-section-heading"><div><h2>选择一位高管，开始会话</h2><p>独立会话，保留历史。职责说明是分工定位，不代表具备外部操作权限。</p></div><Link href="/company#organization">查看下属员工 →</Link></div>
  {loading && <p role="status" className="workspace-loading">正在读取公司高管...</p>}{error && <div role="alert" className="workspace-error">{error} <Link href="/login">前往登录 →</Link></div>}
  {!loading && !error && <div className="executive-grid">{agents.map(a=><Link key={a.id} href={'/chat/'+a.code} aria-disabled={!a.is_active} onClick={e=>{if(!a.is_active)e.preventDefault();}} className={'executive-card '+(!a.is_active?'is-disabled':'')}><div className="executive-card-top"><span className="executive-avatar">{a.code}</span><span className="executive-state">{a.is_active?'● 已启用':'○ 已停用'}</span></div><h2>{a.title}</h2><p>{responsibilities[a.code] || a.name}</p><div className="executive-card-footer"><span>{a.code==='COS'?'规划与组织':'专业判断与交付'}</span><span>{a.is_active?'进入会话 ↗':'暂不可用'}</span></div></Link>)}</div>}
  <section className="workspace-next-action"><div><h2>不知道该先找谁？交给 COS。</h2><p>说明业务目标、资料和验收标准。COS判断直接处理还是分工，计划由CEO确认后再开始执行。</p></div><Link href="/plans">创建业务目标 →</Link></section>
 </main>;
}
