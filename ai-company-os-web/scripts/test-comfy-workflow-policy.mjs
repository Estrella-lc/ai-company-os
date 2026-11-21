import assert from 'node:assert/strict';
import {inspectComfyWorkflow} from './comfy-workflow-policy.mjs';
const workflow={'1':{class_type:'LoadImage',inputs:{image:'approved-character.png'}},'2':{class_type:'WanImageToVideo',inputs:{start_image:['1',0]}}};
const result=inspectComfyWorkflow(workflow,['LoadImage','WanImageToVideo']);
assert.equal(result.static_passed,true);assert.equal(result.runtime_verified,false);assert.equal(result.character_quality_verified,false);
assert.equal(inspectComfyWorkflow(workflow,[]).static_passed,false);
assert.throws(()=>inspectComfyWorkflow({nodes:[]}));
assert.throws(()=>inspectComfyWorkflow({'1':{class_type:'LoadImage',inputs:{image:'https://evil.test/image'}}}));
assert.throws(()=>inspectComfyWorkflow({'1':{class_type:'LoadImage',inputs:{image:['99',0]}}}));
assert.equal(inspectComfyWorkflow({'1':{class_type:'LoadImage',inputs:{image:'test.png'}}},['LoadImage']).image_conditioned,false);
console.log('PASS: API format, image conditioning, missing nodes, path/link boundaries and no false runtime verification');

