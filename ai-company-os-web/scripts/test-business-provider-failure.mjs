import assert from 'node:assert/strict';
import {providerFailure} from '../../supabase/functions/cto-task-worker/provider-failure.ts';
for(const [error,kind,status] of [[{status:503,message:'service unavailable'},'provider_unavailable',503],[{status:429,message:'quota'},'rate_limit',429],[{status:400,message:'API key not valid. secret=value'},'credentials',400],[{status:403,message:'denied'},'permission',403],[{status:404,message:'model not found'},'model_unavailable',404],[{name:'TimeoutError',message:'aborted'},'timeout',null],[{message:'fetch failed'},'network',null],[{message:'MODEL_OUTPUT_INCOMPLETE'},'incomplete',null]])assert.deepEqual(providerFailure(error),{error_kind:kind,http_status:status});
assert.equal(JSON.stringify(providerFailure({status:400,message:'invalid request https://example/?key=secret-value'})).includes('secret-value'),false);
assert.equal(providerFailure({status:'503',message:'unrecognized'}).http_status,null);
console.log('PASS: bounded provider status classification without raw messages, URLs or credentials');
