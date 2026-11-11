import {createHash} from 'node:crypto';
const repoPattern=/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
export async function publicJson(url,fetcher=fetch){const u=new URL(url);if(u.protocol!=='https:' || !['api.github.com','pypi.org'].includes(u.hostname))throw new Error('source_host');const r=await fetcher(u,{headers:{'User-Agent':'AI-Company-OS-Technology-Research','Accept':'application/json'},redirect:'error',signal:AbortSignal.timeout(15000)});if(!r.ok)throw new Error('source_http_'+r.status);const text=await r.text();if(text.length>2000000)throw new Error('source_size');return JSON.parse(text);}
export async function discoverTechnologies(query,fetcher=fetch){
 const trace=[],candidates=[];const search=await publicJson('https://api.github.com/search/repositories?q='+encodeURIComponent(query+' archived:false')+'&sort=stars&per_page=8',fetcher);
 for(const repo of (search.items || []).filter(r=>!r.private && !r.archived && repoPattern.test(r.full_name) && r.stargazers_count>=25).slice(0,5)){
  try{
   const commit=await publicJson('https://api.github.com/repos/'+repo.full_name+'/commits/'+encodeURIComponent(repo.default_branch),fetcher);if(!/^[0-9a-f]{40}$/.test(commit.sha))throw new Error('commit_pin');
   const readme=await publicJson('https://api.github.com/repos/'+repo.full_name+'/readme?ref='+commit.sha,fetcher);if(readme.encoding!=='base64')throw new Error('readme_encoding');const document=Buffer.from(readme.content,'base64').toString('utf8').slice(0,30000);
   const names=[...document.matchAll(/pypi\.org\/project\/([A-Za-z0-9_.-]+)|pip(?:3)?\s+install\s+([A-Za-z][A-Za-z0-9_.-]*)/gi)].map(m=>m[1] || m[2]);
   for(const name of [...new Set(names)].slice(0,2)){
    try{const data=await publicJson('https://pypi.org/pypi/'+encodeURIComponent(name)+'/json',fetcher),info=data.info;
     const urls=Object.values(info.project_urls || {}).concat(info.home_page || '').filter(u=>typeof u==='string');if(!urls.some(value=>{try{const u=new URL(value);return u.protocol==='https:' && u.hostname==='github.com' && u.pathname.split('/').filter(Boolean).slice(0,2).join('/').toLowerCase()===repo.full_name.toLowerCase();}catch{return false;}}))throw new Error('package_repository_mismatch');
     if(!['MIT','Apache-2.0','BSD-2-Clause','BSD-3-Clause','ISC'].includes(repo.license?.spdx_id))throw new Error('license_review_needed');
     if((info.requires_dist || []).some(d=>!/(?:extra\s*==|extra\s+in)/.test(d)))throw new Error('dependency_setup_needed');
     const wheel=(data.urls || []).find(f=>!f.yanked && /-py3(?:\.py2)?-none-any\.whl$|-py2\.py3-none-any\.whl$/.test(f.filename) && f.size<=10000000 && /^[a-f0-9]{64}$/.test(f.digests?.sha256 || '') && new URL(f.url).hostname==='files.pythonhosted.org');
     if(!wheel)throw new Error('compatible_pure_wheel_needed');
     candidates.push({repository:repo.full_name,commit_sha:commit.sha,readme_path:readme.path,readme:document,readme_sha256:createHash('sha256').update(document).digest('hex'),stars:repo.stargazers_count,pushed_at:repo.pushed_at,license:repo.license.spdx_id,package:{name:info.name,version:info.version,filename:wheel.filename,url:wheel.url,sha256:wheel.digests.sha256,size:wheel.size},description:info.summary || repo.description || ''});
     trace.push({repository:repo.full_name,package:info.name,result:'eligible_pinned_package'});break;
    }catch(e){trace.push({repository:repo.full_name,package:name,blocked:String(e.message)});}
   }
  }catch(e){trace.push({repository:repo.full_name,blocked:String(e.message)});}
  if(candidates.length>=3)break;
 }
 return {candidates,trace,query};
}
export function validateManifest(m){
 const path=p=>typeof p==='string' && p.length<160 && p.split('.').every(s=>/^[A-Za-z][A-Za-z0-9_]*$/.test(s));
 if(!m || !path(m.call) || !m.call.includes('.') || !m.kwargs || typeof m.kwargs!=='object' || Array.isArray(m.kwargs) || Object.keys(m.kwargs).length>8 || !m.fields)throw new Error('manifest_shape');
 for(const [k,v] of Object.entries(m.kwargs))if(!/^[A-Za-z][A-Za-z0-9_]*$/.test(k) || !(v===null || ['string','number','boolean'].includes(typeof v) || (typeof v==='object' && Object.keys(v).length===1 && v.input==='srt')))throw new Error('manifest_argument');
 if(m.collection && m.collection!=='@' && !path(m.collection))throw new Error('manifest_collection');
 for(const key of ['text','start','end']){const f=m.fields[key];if(!f || !path(f.path) || (f.call!==undefined && typeof f.call!=='boolean') || (f.scale!==undefined && (typeof f.scale!=='number' || !Number.isFinite(f.scale) || f.scale<=0 || f.scale>1000)))throw new Error('manifest_field');}
 if(JSON.stringify(m).length>4000)throw new Error('manifest_size');return m;
}
