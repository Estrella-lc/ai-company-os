import assert from 'node:assert/strict';
import {createGithubVerifier} from '../../supabase/functions/cto-task-worker/github-identity.ts';
const now=Date.now(),pair=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
const jwk=await crypto.subtle.exportKey('jwk',pair.publicKey);jwk.kid='test-key';
const verify=createGithubVerifier(async()=>new Response(JSON.stringify({keys:[jwk]})),()=>now);
const claims={iss:'https://token.actions.githubusercontent.com',aud:'ai-company-os-skills',repository_id:'1445824473',repository:'Estrella-lc/ai-company-os',ref:'refs/heads/main',workflow_ref:'Estrella-lc/ai-company-os/.github/workflows/skill-sandbox.yml@refs/heads/main',runner_environment:'github-hosted',event_name:'workflow_dispatch',run_id:'123',run_attempt:'1',iat:Math.floor(now/1000),exp:Math.floor(now/1000)+300};
async function jwt(payload,header={alg:'RS256',kid:'test-key'}){const unsigned=Buffer.from(JSON.stringify(header)).toString('base64url')+'.'+Buffer.from(JSON.stringify(payload)).toString('base64url');const signature=await crypto.subtle.sign('RSASSA-PKCS1-v1_5',pair.privateKey,new TextEncoder().encode(unsigned));return unsigned+'.'+Buffer.from(signature).toString('base64url');}
assert.deepEqual(await verify(await jwt(claims)),{runner:'123/1',runUrl:'https://github.com/Estrella-lc/ai-company-os/actions/runs/123'});
for(const invalid of [{aud:'other'},{repository_id:'another'},{ref:'refs/pull/1/merge'},{workflow_ref:'Estrella-lc/ai-company-os/.github/workflows/untrusted.yml@refs/heads/main'},{event_name:'pull_request'},{runner_environment:'self-hosted'},{exp:Math.floor(now/1000)-1},{iat:Math.floor(now/1000)-1000},{iss:'https://attacker.invalid'}])await assert.rejects(()=>jwt({...claims,...invalid}).then(verify));
await assert.rejects(()=>verify(jwt));
await assert.rejects(()=>jwt(claims,{alg:'HS256',kid:'test-key'}).then(verify));
const valid=await jwt(claims);await assert.rejects(()=>verify(valid.slice(0,-8)+'AAAAAAAA'));
console.log('PASS: signed OIDC identity, audience, workflow, repository, expiry and tamper rejection');

