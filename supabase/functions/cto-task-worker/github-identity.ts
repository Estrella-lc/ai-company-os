// No persistent GitHub token is shared with Supabase. Trust one workflow in one immutable repository ID.
export function createGithubVerifier(fetcher:typeof fetch=fetch,clock:()=>number=()=>Date.now()) {
 let cached:{keys:JsonWebKey[]}|null=null;let expires=0;
 const decode=(value:string)=>Uint8Array.from(atob(value.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
 return async function verifyGithubIdentity(token:string):Promise<{runner:string;runUrl:string}>{
  if(token.length>20000)throw new Error('Invalid identity');
  const parts=token.split('.');if(parts.length!==3)throw new Error('Invalid identity');
  const header=JSON.parse(new TextDecoder().decode(decode(parts[0]))),claims=JSON.parse(new TextDecoder().decode(decode(parts[1])));
  if(header.alg!=='RS256' || typeof header.kid!=='string')throw new Error('Invalid signing algorithm');
  if(!cached || expires<clock()){
   const response=await fetcher('https://token.actions.githubusercontent.com/.well-known/jwks',{signal:AbortSignal.timeout(8000),redirect:'error'});
   if(!response.ok)throw new Error('Identity provider unavailable');cached=await response.json();expires=clock()+300000;
  }
  const jwk=cached?.keys.find(k=>(k as JsonWebKey & {kid?:string}).kid===header.kid);
  if(!jwk || jwk.kty!=='RSA')throw new Error('Unknown signing key');
  const key=await crypto.subtle.importKey('jwk',jwk,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['verify']);
  if(!await crypto.subtle.verify('RSASSA-PKCS1-v1_5',key,decode(parts[2]),new TextEncoder().encode(parts[0]+'.'+parts[1])))throw new Error('Invalid identity signature');
  const now=clock()/1000;
  if(claims.iss!=='https://token.actions.githubusercontent.com' || claims.aud!=='ai-company-os-skills' || claims.repository_id!=='1445824473' || claims.repository!=='Estrella-lc/ai-company-os' || claims.ref!=='refs/heads/main' || claims.workflow_ref!=='Estrella-lc/ai-company-os/.github/workflows/skill-sandbox.yml@refs/heads/main' || claims.runner_environment!=='github-hosted' || !['schedule','workflow_dispatch'].includes(claims.event_name) || !Number.isFinite(claims.exp) || !Number.isFinite(claims.iat) || claims.exp<=now || claims.iat>now+30 || claims.iat<now-600 || claims.exp-claims.iat>600 || (claims.nbf!==undefined && claims.nbf>now+30) || !/^[0-9]+$/.test(claims.run_id || '') || !/^[0-9]+$/.test(claims.run_attempt || ''))throw new Error('Workflow is not authorized');
  return {runner:claims.run_id+'/'+claims.run_attempt,runUrl:'https://github.com/Estrella-lc/ai-company-os/actions/runs/'+claims.run_id};
 };
}

