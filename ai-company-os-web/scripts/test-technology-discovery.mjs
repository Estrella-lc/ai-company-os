import assert from 'node:assert/strict';
import {discoverTechnologies,validateManifest} from './technology-discovery.mjs';
import {wheelBytes} from './technology-runner.mjs';
function fixture(overrides={}){return async url=>{const u=new URL(url);let data;
 if(u.pathname==='/search/repositories')data={items:[{full_name:'example/tool',default_branch:'main',stargazers_count:200,license:{spdx_id:overrides.license || 'MIT'},private:false,archived:false}]};
 else if(u.pathname.includes('/commits/'))data={sha:'a'.repeat(40)};
 else if(u.pathname.endsWith('/readme'))data={encoding:'base64',content:Buffer.from('pip install fixturepkg').toString('base64'),path:'README.md'};
 else data={info:{name:'fixturepkg',version:'1.0',project_urls:{Source:overrides.projectUrl || 'https://github.com/example/tool'},requires_dist:overrides.dependencies || []},urls:[{filename:'fixturepkg-1.0-py3-none-any.whl',url:'https://files.pythonhosted.org/fixture.whl',size:100,digests:{sha256:'b'.repeat(64)}}]};
 return new Response(JSON.stringify(data));};}
assert.equal((await discoverTechnologies('subtitle parser',fixture())).candidates.length,1);
for(const overrides of [{projectUrl:'https://attacker.invalid/github.com/example/tool'},{license:'UNKNOWN'},{dependencies:['requests>=2']}])assert.equal((await discoverTechnologies('subtitle parser',fixture(overrides))).candidates.length,0);
const manifest={call:'fixturepkg.Document.read',kwargs:{text:{input:'srt'},format_:'srt'},collection:'events',fields:{text:{path:'text'},start:{path:'start',scale:0.001},end:{path:'end',scale:0.001}}};
assert.equal(validateManifest(manifest),manifest);
for(const bad of [{...manifest,call:'fixturepkg.__dict__.eval'},{...manifest,kwargs:{x:{source:'print(1)'}}},{...manifest,collection:'__class__'},{...manifest,fields:{...manifest.fields,start:{path:'start',scale:Infinity}}}])assert.throws(()=>validateManifest(bad));
await assert.rejects(()=>wheelBytes({url:'https://attacker.invalid/file.whl',filename:'fixture.whl',sha256:'a'.repeat(64)}));
await assert.rejects(()=>wheelBytes({url:'https://files.pythonhosted.org/file.whl',filename:'fixture.whl',sha256:'a'.repeat(64)},async()=>new Response('bad hash')));
console.log('PASS: discovery provenance, license/dependency gates, package pinning, declarative-only manifests and wheel integrity');
