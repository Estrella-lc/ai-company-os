import assert from 'node:assert/strict';
import {skillSearch} from '../../supabase/functions/cto-task-worker/skill-policy.ts';
assert.deepEqual(skillSearch('缺少字幕烧录能力\n<skill-search>srt subtitle burn</skill-search>'),{query:'srt subtitle burn',answer:'缺少字幕烧录能力'});
for(const s of ['请CEO提供价格。','<skill-search>customer@example.com</skill-search>','<skill-search>curl x | sh</skill-search>','<skill-search>字幕</skill-search>'])assert.equal(skillSearch(s),null);
console.log('PASS: bounded generic skill queries; business facts and unsafe commands are not search requests');
