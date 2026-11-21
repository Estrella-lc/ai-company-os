import assert from 'node:assert/strict';
import {parseMotionReview} from '../../supabase/functions/cto-task-worker/motion-review.ts';
const good={verdict:'pass',summary:'Visible coherent arm motion',duration:5.1,motion_present:true,face_visible:true,coherent:true,evidence:['0s: hand lowered','4s: hand raised']};
assert.equal(parseMotionReview(JSON.stringify(good)).verdict,'pass');
for(const change of [{motion_present:false},{face_visible:false},{coherent:false},{duration:4.8},{evidence:[]}])assert.throws(()=>parseMotionReview(JSON.stringify({...good,...change})));
assert.equal(parseMotionReview(JSON.stringify({...good,verdict:'revise',face_visible:false})).verdict,'revise');
console.log('PASS: reject static, cropped face, incoherent motion, short duration and missing evidence');

