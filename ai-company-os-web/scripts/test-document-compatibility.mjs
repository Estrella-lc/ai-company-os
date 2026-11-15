import assert from 'node:assert/strict';
import {claimDocumentJob} from './document-runner.mjs';
assert.equal(await claimDocumentJob(async()=>{throw new Error('Invalid skill callback');}),null);
assert.equal(await claimDocumentJob(async()=>({job:null})),null);
const job={id:'leased-document'};assert.equal(await claimDocumentJob(async request=>{assert.equal(request.action,'document_claim');return {job};}),job);
for(const message of ['Unauthorized workload identity','Document grants unavailable','Skill callback failed','fetch failed'])await assert.rejects(()=>claimDocumentJob(async()=>{throw new Error(message);}),{message});
console.log('PASS: old Worker compatibility without masking authorization, document backend or transport failures');

