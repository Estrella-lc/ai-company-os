import assert from 'node:assert/strict';
import {parseQualityReport,qualityContext,uncertainQuality,qualityFailureReason,qualityResponseFormat} from '../../supabase/functions/cto-task-worker/text-quality.ts';
const body='多高管会话支持业务决策。任务验收确认交付。';
const pass={verdict:'pass',summary:'文本满足要求，等待CEO验收',checks:['task_goal','task_acceptance','truthfulness'].map(id=>({id,status:'pass',evidence:'任务验收确认交付。',reason:'原文证据存在，检查本项要求'}))};
assert.equal(parseQualityReport(JSON.stringify(pass),body).verdict,'pass');
for(const report of [{...pass,checks:pass.checks.slice(0,2)},{...pass,checks:pass.checks.map(c=>({...c,id:'task_goal'}))},{...pass,checks:pass.checks.map(c=>({...c,evidence:'不存在的证据'}))},{...pass,checks:pass.checks.map(c=>({...c,status:'not_checked'}))},{...pass,verdict:'revise'}])assert.throws(()=>parseQualityReport(JSON.stringify(report),body));
assert.throws(()=>parseQualityReport(JSON.stringify(pass),body.repeat(1000)));
assert.equal(parseQualityReport(JSON.stringify(uncertainQuality('无法核实运行状态')),body).verdict,'needs_human');
const job={id:'j',created_by:'ceo',assigned_agent_id:'manager',input:{quality_review_id:'q',capability:'text_quality_v1'}};
const review={id:'q',created_by:'ceo',job_id:'j',work_order_id:'w',source_job_id:'source',employee_id:'qa',manager_agent_id:'manager',snapshot:{title:'t',goal:'g',acceptance:'a',body,project:null}};
const employee={id:'qa',created_by:'ceo',manager_agent_id:'manager',role:'quality_inspector'};
const order={id:'w',created_by:'ceo',input:{employee_id:'producer'}};
assert(qualityContext(job,review,employee,order).system.includes('独立文本质检员'));
const revision={...review,snapshot:{...review.snapshot,execution_request:'CEO补充的合成测试事实：价格为人民币99元。',execution_request_message_id:'request-v2'}};
const evidenceInput=JSON.parse(qualityContext(job,revision,employee,order).input);
assert.equal(evidenceInput.execution_request,revision.snapshot.execution_request);
assert.equal(evidenceInput.execution_request_message_id,'request-v2');
assert.equal(evidenceInput.body,body);
assert.equal(qualityResponseFormat().mime_type,'application/json');
assert.equal(parseQualityReport('```JSON\n'+JSON.stringify(pass)+'\n```',body).verdict,'pass');
let malformed,wrongQuote;
try{parseQualityReport('not json',body);}catch(e){malformed=e;}
try{parseQualityReport(JSON.stringify({...pass,checks:pass.checks.map(c=>({...c,evidence:'CEO补充的合成测试事实：价格为人民币99元。'}))}),body);}catch(e){wrongQuote=e;}
assert(qualityFailureReason(malformed).includes('不是完整JSON'));
assert(qualityFailureReason(wrongQuote).includes('逐字原文'));
assert.equal(uncertainQuality(qualityFailureReason(wrongQuote)).verdict,'needs_human');
assert.throws(()=>parseQualityReport(JSON.stringify({...pass,checks:[null,...pass.checks.slice(1)]}),body));
for(const args of [[job,review,{...employee,role:'text_executor'},order],[job,review,employee,{...order,input:{employee_id:'qa'}}],[job,{...review,job_id:'other'},employee,order],[{...job,created_by:'other'},review,employee,order]])assert.throws(()=>qualityContext(...args));
console.log('PASS: independent identity, owner/job binding, complete criteria, exact evidence, conservative verdicts and oversized delivery guard');
