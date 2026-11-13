"use client";
import Link from 'next/link';
import {usePathname} from 'next/navigation';
const links=[['/company','公司总览'],['/','高管会话'],['/plans','COS 规划'],['/tasks','任务中心'],['/skills','技能中心'],['/knowledge','公司知识库'],['/subtitles','字幕交付']] as const;
export default function PlatformNav(){
  const path=usePathname();
  if(path==='/login')return null;
  return <nav aria-label="公司主导航" className="border-b border-slate-800 bg-[#0b1020] px-5 py-3 text-slate-200"><div className="mx-auto max-w-7xl flex flex-wrap items-center gap-2"><Link href="/company" className="mr-5 font-semibold tracking-wide text-sm">AI COMPANY OS</Link>{links.map(([href,label])=><Link key={href} href={href} aria-current={path===href?'page':undefined} className={'rounded-lg px-3 py-2 text-sm '+(path===href?'bg-cyan-950 text-cyan-200':'text-slate-400 hover:bg-slate-800 hover:text-white')}>{label}</Link>)}</div></nav>;
}
