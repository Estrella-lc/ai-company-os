import {createHash} from 'node:crypto';
const repoPattern=/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
export function scanSkill(document){
 const flags=[];
 for(const [name,pattern] of [['credential_access',/\.ssh\/|\.aws\/|vault\.decrypted_secrets|SUPABASE_SERVICE_ROLE_KEY/i],['remote_shell',/curl[^\n]{0,200}\|\s*(?:ba)?sh|wget[^\n]{0,200}\|\s*(?:ba)?sh/i],['instruction_override',/ignore (?:all )?(?:previous|system) instructions|disable (?:all )?security/i]])if(pattern.test(document))flags.push(name);
 const header=document.match(/^---\r?\n([\s\S]*?)\r?\n---/),metadata={};
 if(header)for(const line of header[1].split(/\r?\n/)){const m=line.match(/^([a-z_-]+):\s*(.+)$/);if(m)metadata[m[1]]=m[2].replace(/^['"]|['"]$/g,'');}
 return {name:metadata.name || 'unnamed-skill',description:metadata.description || '',flags,format_valid:!!header && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(metadata.name || '') && !!metadata.description};
}
export async function discoverSkills(input,fetcher=fetch){
 const trace=[];
 async function get(path,raw=false){
  const url=new URL(path,raw?'https://raw.githubusercontent.com/':'https://api.github.com/');
  if(!['api.github.com','raw.githubusercontent.com'].includes(url.hostname) || url.protocol!=='https:')throw new Error('Unsupported source host');
  const response=await fetcher(url,{headers:{Accept:'application/vnd.github+json','User-Agent':'AI-Company-OS-Skill-Research'},signal:AbortSignal.timeout(15000),redirect:'error'});
  if(!response.ok)throw new Error('GitHub request '+response.status);
  const text=await response.text();if(text.length>5000000)throw new Error('Source response too large');return raw?text:JSON.parse(text);
 }
 // Company adaptation of skills/find-skills: consult the catalog before GitHub fallback.
 let catalog=[];
 try{
  const response=await fetcher('https://skills.sh/',{signal:AbortSignal.timeout(15000)});
  if(!response.ok)throw new Error('Catalog request '+response.status);
  const html=await response.text();if(html.length>5000000)throw new Error('Catalog too large');
  const words=String(input.query || '').toLowerCase().split(/\s+/).filter(w=>w.length>2 && !['agent','skills'].includes(w));
  const links=[...html.matchAll(/href=["']\/(?:([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+))["']/g)];
  catalog=[...new Set(links.filter(m=>words.some(w=>m[0].toLowerCase().includes(w))).map(m=>m[1]+'/'+m[2]))].slice(0,2);
  trace.push({action:'find_skills_catalog',source:'https://skills.sh/',repositories:catalog});
 }catch(e){trace.push({action:'find_skills_catalog',error:String(e.message).slice(0,100)});}
 let found=[];
 try{const search=await get('/search/repositories?q='+encodeURIComponent(input.query+' archived:false')+'&per_page=3&sort=stars');found=(search.items || []).filter(r=>!r.private && repoPattern.test(r.full_name)).map(r=>r.full_name);trace.push({action:'repository_search',query:input.query,count:found.length});}catch(e){trace.push({action:'repository_search',error:String(e.message).slice(0,100)});}
 // Public catalog seeds are discovery fallbacks, not trusted executable code.
 const seeds=input.capability==='subtitles' || input.capability==='video'?['remotion-dev/skills']:input.capability==='documents'?['anthropics/skills']:['vercel-labs/agent-skills'];
 const repositories=[...new Set([...catalog,...seeds,...found])].slice(0,3),candidates=[];
 for(const repository of repositories){
  try{
   const repo=await get('/repos/'+repository);if(repo.private || repo.archived)continue;
   const commit=await get('/repos/'+repository+'/commits/'+encodeURIComponent(repo.default_branch));if(!/^[0-9a-f]{40}$/.test(commit.sha))throw new Error('Unpinned source');
   const tree=await get('/repos/'+repository+'/git/trees/'+commit.sha+'?recursive=1');
   const files=(tree.tree || []).filter(f=>f.type==='blob' && !f.path.split('/').includes('..'));
   const score=path=>{const p=path.toLowerCase();return (input.capability==='subtitles'?(/caption|subtitle|srt/.test(p)?20:0):input.capability==='video'?(/video|ffmpeg|remotion/.test(p)?20:0):input.capability==='documents'?(/pdf|docx/.test(p)?20:0):(/develop|coding|react/.test(p)?10:0));};
   const skills=files.filter(f=>/(^|\/)SKILL\.md$/.test(f.path) && f.size<=40000).sort((a,b)=>score(b.path)-score(a.path) || a.path.localeCompare(b.path));
   if(!skills.length){trace.push({repository,result:'no_skill_document'});continue;}
   const source=skills[0],document=await get(repository+'/'+commit.sha+'/'+source.path,true);if(document.length>40000)throw new Error('Skill document too large');
   const scan=scanSkill(document),folder=source.path.includes('/')?source.path.slice(0,source.path.lastIndexOf('/')+1):'';
   const related=files.filter(f=>f.path.startsWith(folder) && f.path!==source.path && /\.md$/i.test(f.path) && f.size<=12000).sort((a,b)=>(/srt|caption/i.test(b.path)?1:0)-(/srt|caption/i.test(a.path)?1:0)).slice(0,2),references=[];
   for(const f of related){try{references.push({path:f.path,sha:f.sha,content:(await get(repository+'/'+commit.sha+'/'+f.path,true)).slice(0,6000)});}catch{references.push({path:f.path,error:'unavailable'});}}
   const scripts=files.filter(f=>f.path.startsWith(folder) && /\.(py|sh|mjs|js|ts)$/.test(f.path)).slice(0,20).map(f=>({path:f.path,sha:f.sha,size:f.size}));
   const allText=document+'\n'+references.map(r=>r.content || '').join('\n'),flags=[...new Set([...scan.flags,...scanSkill(allText).flags])];
   candidates.push({repository,commit_sha:commit.sha,skill_path:source.path,name:scan.name,description:scan.description,document,rejected:!scan.format_valid || flags.length>0,metadata:{source_url:'https://github.com/'+repository+'/blob/'+commit.sha+'/'+source.path,document_sha256:createHash('sha256').update(document).digest('hex'),license:repo.license?.spdx_id || 'UNKNOWN',format_valid:scan.format_valid,flags,references,scripts,tree_truncated:!!tree.truncated,dependencies:allText.split('\n').filter(l=>/npm |npx |pip |ffmpeg|python|node /i.test(l)).slice(0,15).map(l=>l.slice(0,200))},verification:{passed:false,scope:'static_review_only',note:'已读取固定版本说明；第三方脚本未执行，静态检查不构成安全或能力保证。'}});
   trace.push({repository,result:'candidate_downloaded',commit:commit.sha,path:source.path});
  }catch(e){trace.push({repository,error:String(e.message).slice(0,120)});}
 }
 return {candidates,trace};
}
