import Link from 'next/link';
const phases=[
 {number:'01',status:'已上线',title:'把目标变成可验收的交付',text:'COS 规划分工、高管自动建立文本员工、任务依赖、CEO验收与知识归档，已经用两步文本业务流程验证。',items:['文本执行员工与返工历史','公司知识库与固定版本引用','任务阶段进度与公司总览']},
 {number:'02',status:'项目基础已搭建',title:'以项目组织完整工作流程',text:'项目中心支持自定义阶段、关联COS计划、记录阶段与全流程证据，最后由CEO进行业务验收。目前检查由CEO手动记录，独立AI质检员工与高管定向对话仍待接入。',items:['项目目标与分层验收计划','下一步：独立专业质检与返工','下一步：任务协作室与定向提问']},
 {number:'03',status:'部分基础已具备',title:'让成熟技术成为公司能力',text:'先复用成熟开源工具或平台接口，通过实际用例后才登记为可调用能力。当前接入执行器已搭建，真实工具接入仍需完成复测。',items:['员工自主研究与来源、许可证核对','固定版本、隔离验证与权限审批','员工跨部门复用同一技能']},
 {number:'04',status:'后续规划',title:'用一个商业场景检验公司',text:'以小型AI漫剧为第一个多工具场景，逐项连接剧本、绘图、配音和视频合成，先保证短片质量，再扩展规模。',items:['素材与成品统一归入任务','任务并行、依赖与失败恢复','交付质量、预算与素材生命周期']},
];
export default function RoadmapPage(){return <main className="roadmap-page"><header className="workspace-hero"><div><p className="workspace-eyebrow">THE NEXT CHAPTER</p><h1>让公司真正协同起来</h1><p className="workspace-description">从已验证的文本闭环，走向有边界、有证据的多 Agent 协作。</p></div><span className="workspace-outline-tag">建设路线 · 2026.11</span></header>
 <section className="roadmap-intro"><span className="workspace-eyebrow">当前边界</span><p>已上线的是任务交接与文本员工执行。高管之间尚无私聊频道；这里展示的是下一阶段设计，不是已经发生的内部对话。</p><Link href="/company">查看实际任务进度 →</Link></section>
 <section className="roadmap-grid" aria-label="功能建设路线">{phases.map(p=><article className="roadmap-card" key={p.number}><div className="roadmap-card-top"><span>{p.number}</span><small>{p.status}</small></div><h2>{p.title}</h2><p>{p.text}</p><ul>{p.items.map(i=><li key={i}>{i}</li>)}</ul></article>)}</section>
 <section id="communication" className="communication-panel"><div className="communication-heading"><div><p className="workspace-eyebrow">PRIVATE COLLABORATION · 设计方案</p><h2>高管私下交流，应该发生在哪里？</h2><p>采用“任务协作室 + 定向消息”，而不是让所有高管一直在群里聊天。</p></div><span className="workspace-outline-tag">待建设</span></div>
  <div className="communication-flow" aria-label="高管协作设计流程"><article><small>01 · 目标</small><strong>CEO / COS</strong><p>目标、分工与验收标准</p></article><span>→</span><article className="flow-room"><small>02 · 围绕当前任务</small><strong>私有任务协作室</strong><p>CPO ⇄ CMO ⇄ 所属员工</p><em>提问 · 回复 · 决策 · 交接</em></article><span>→</span><article><small>03 · 交付</small><strong>执行与验收</strong><p>结论进入任务，成果验收后入库</p></article></div>
  <div className="communication-rules"><article><h3>什么情况下才交流</h3><p>缺少资料、需要专业意见、发现冲突或需要交接时，发起明确的定向请求。完整资料优先直接复用。</p></article><article><h3>谁可以看、谁可以答</h3><p>仅限同公司、同任务的授权参与者。CEO可以审计全文；默认只在总览展示结论和待决策事项，不把每条消息推给CEO。</p></article><article><h3>怎样避免空聊和失控</h3><p>建议每个任务默认最多2轮讨论；无新信息不再次唤醒。消息绑定任务、收件人、唯一请求和来源，沿用队列、租约与故障恢复。</p></article><article><h3>哪些事情仍要审批</h3><p>讨论不能自行扩大工具权限。付费、外部发布、敏感素材访问或执行新软件，继续经过相应授权；不能靠对话绕过边界。</p></article></div>
 </section><section className="workspace-next-action"><div><h2>下一项优先搭建什么？</h2><p>先在项目验收记录上接入独立专业质检，再实现高管的任务内提问与回复；随后扩展成熟工具和漫剧业务场景。</p></div><Link href="/projects">进入项目中心 →</Link></section>
 </main>;}
