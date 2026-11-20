"use client";
import Link from 'next/link';
import {usePathname} from 'next/navigation';
import {useState,type ReactNode} from 'react';
const groups=[
 {name:'工作空间',items:[{href:'/company',label:'公司总览',icon:'overview'},{href:'/goals',label:'业务目标',icon:'flow'},{href:'/projects',label:'项目中心',icon:'flow'},{href:'/plans',label:'COS 规划',icon:'flow'},{href:'/tasks',label:'任务中心',icon:'tasks'}]},
 {name:'公司能力',items:[{href:'/',label:'高管团队',icon:'team'},{href:'/skills',label:'技能中心',icon:'skills'},{href:'/knowledge',label:'公司知识库',icon:'book'}]},
 {name:'协作与演进',items:[{href:'/roadmap',label:'建设路线',icon:'roadmap'}]},
];
const iconPaths:Record<string,string>={overview:'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',flow:'M5 5h14v5H5z M12 10v4 M5 14h14 M5 14v5 M19 14v5 M3 19h4 M17 19h4',tasks:'M8 5h12 M8 12h12 M8 19h12 M3 5h.01 M3 12h.01 M3 19h.01',team:'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M22 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75',skills:'m13 2-9 12h7l-1 8 10-12h-7z',book:'M4 3h7a4 4 0 0 1 4 4v14a4 4 0 0 0-4-4H4z M15 7a4 4 0 0 1 4-4h2v14h-2a4 4 0 0 0-4 4',roadmap:'M5 4v16 M5 4h13l-3 4 3 4H5 M3 20h4'};
function Icon({name}:{name:string}){return <svg aria-hidden="true" width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d={iconPaths[name] || iconPaths.tasks}/></svg>;}
export default function PlatformNav({children}:{children:ReactNode}){
 const path=usePathname(),[open,setOpen]=useState(false);
 if(path==='/login')return children;
 const isSkills=path.startsWith('/skills') || path==='/subtitles';
 const current=path==='/skills/subtitles' || path==='/subtitles'?'字幕烧录':path==='/skills/research'?'发现与接入':groups.flatMap(g=>g.items).find(i=>path===i.href || i.href!=='/' && path.startsWith(i.href+'/'))?.label || (path.startsWith('/chat/')?'高管会话':'工作空间');
 const active=(href:string)=>href==='/'?path==='/' || path.startsWith('/chat/'):href==='/skills'?isSkills:path===href || path.startsWith(href+'/');
 return <div className="platform-frame"><a href="#workspace-main" className="workspace-skip">跳到主要内容</a>
  {open && <button className="sidebar-backdrop" aria-label="关闭导航" onClick={()=>setOpen(false)}/>}
  <aside className={'workspace-sidebar '+(open?'is-open':'')}><Link href="/company" className="workspace-brand" onClick={()=>setOpen(false)}><span className="brand-symbol">A</span><span><strong>AI Company</strong><small>你的智能组织</small></span></Link>
   <nav aria-label="公司主导航" className="workspace-navigation">{groups.map(g=><section key={g.name} className="nav-group"><p>{g.name}</p>{g.items.map(item=><div key={item.href}><Link href={item.href} onClick={()=>setOpen(false)} aria-current={active(item.href)?'page':undefined} className={'workspace-nav-link '+(active(item.href)?'is-active':'')}><Icon name={item.icon}/><span>{item.label}</span>{active(item.href) && <span className="nav-active-dot"/>}</Link>{item.href==='/skills' && isSkills && <div className="workspace-subnav">{[['/skills','技能总览'],['/skills/research','发现与接入'],['/skills/subtitles','字幕烧录']].map(([href,label])=><Link href={href} key={href} aria-current={path===href?'page':undefined} onClick={()=>setOpen(false)}>{label}</Link>)}</div>}</div>)}</section>)}</nav>
   <div className="workspace-sidebar-footer"><span className="workspace-avatar">C</span><div><strong>CEO 工作空间</strong><small>目标 · 协作 · 交付</small></div><span className="workspace-footer-mark">◈</span></div>
  </aside>
   <div className="workspace-stage"><header className="workspace-topbar"><div className="workspace-crumb"><button className="workspace-menu-button" aria-label="打开公司导航" aria-expanded={open} onClick={()=>setOpen(!open)}>☰</button><span className="crumb-root">工作空间</span><span className="crumb-separator">/</span>{isSkills && path!=='/skills' && <><Link href="/skills">技能中心</Link><span className="crumb-separator">/</span></>}<span>{current}</span></div><div className="workspace-topbar-actions"><Link href="/roadmap" className="workspace-quiet-link">建设路线 ↗</Link><Link href="/goals?new=1" className="workspace-primary-link">＋ 新建业务目标</Link></div></header>
   <div id="workspace-main" className="workspace-content">{children}</div><footer className="workspace-bottomline"><span>AI COMPANY OS</span><span>每一次交付，都成为公司的积累。</span></footer>
  </div>
 </div>;
}
