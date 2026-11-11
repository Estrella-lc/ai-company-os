import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {prepareDevelopmentImage,evaluateCandidate} from './development-runner.mjs';
import {acceptanceCases,checkAnswer} from './development-contract.mjs';
assert.ok(acceptanceCases().length>=22);
assert.ok(checkAnswer({result:{valid:true,cue_count:1,issues:[]}}, {count:1,codes:['OVERLAP']}));
assert.ok(checkAnswer({result:{valid:false,cue_count:1,issues:[{code:'OTHER',cue:1}]}},{count:1,codes:['OVERLAP']}));
await prepareDevelopmentImage();
const reference=await readFile('ai-company-os-web/scripts/fixtures/srt-reference.py','utf8'),good=await evaluateCandidate(reference);
assert.equal(good.passed,true,JSON.stringify(good.failures));
assert.equal(good.passed_count,good.case_count);assert.equal(good.isolation_passed,true);
for(const source of ["import os\ndef analyze_srt(text,duration_seconds=None): return {}", "def analyze_srt(text,duration_seconds=None):\n while True: pass", "def analyze_srt(text,duration_seconds=None):\n return {'valid':True,'cue_count':1,'issues':[]}", "def analyze_srt(text,duration_seconds=None):\n return text.__class__"]){const bad=await evaluateCandidate(source,{timeout:800});assert.equal(bad.passed,false);assert.ok(bad.failures.length>0);}
console.log('PASS: immutable semantic tests, calibration fixture, import/dunder restrictions, CPU timeout, false-pass rejection and real isolation probes');
