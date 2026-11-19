import assert from 'node:assert/strict';
import {businessModelOrder} from '../../supabase/functions/cto-task-worker/business-model-order.ts';
const m=['primary','fallback'],bad={model_name:'primary',call_status:'failed',error_kind:'provider_unavailable'},ok={model_name:'fallback',call_status:'completed'};
assert.deepEqual(businessModelOrder(m,[bad,bad,ok]),['fallback','primary']);
assert.deepEqual(businessModelOrder(m,[bad,{...ok,call_status:'failed'},bad,ok]),['fallback','primary']);
for(const health of [[],[bad,ok],[{...bad,error_kind:'permission'},bad,ok],[bad,bad,{...ok,call_status:'failed'}],[{...bad,call_status:'completed'},bad,ok]])assert.deepEqual(businessModelOrder(m,health),m);
assert.deepEqual(businessModelOrder(['primary','primary'],[bad,bad,ok]),['primary']);
console.log('PASS: recent successful fallback preferred only after two transient primary failures; both models retained');
