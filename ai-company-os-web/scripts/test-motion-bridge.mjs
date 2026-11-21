import assert from 'node:assert/strict';
import {motionBridge} from '../../supabase/functions/cto-task-worker/motion-bridge.ts';
const b={action:'motion_context',taskId:'11111111-1111-4111-8111-111111111111',leaseToken:'22222222-2222-4222-8222-222222222222'},identity={runner:'123/1',runUrl:'https://example.test/run'};
const denied={storage:{from(){throw Error('Unauthorized storage access');}}};
assert.equal((await motionBridge(denied,async()=>[],b,identity)).status,403);
const context={created_by:'owner',prompt:'fictional adult raises a hand',provider_event_id:'a'.repeat(32)};
const r=await motionBridge(denied,async()=>[context],b,identity);assert.equal((await r.json()).prompt,context.prompt);
assert.equal((await motionBridge(denied,async()=>[context],{...b,action:'motion_submitted',provider:{provider:'evil',event_id:'a'.repeat(32)}},identity)).status,400);
assert.equal((await motionBridge(denied,async()=>[context],{...b,action:'motion_complete',report:{ceo_acceptance:true}},identity)).status,400);
console.log('PASS: lease denial, frozen context, provider allowlist and no automatic acceptance');

