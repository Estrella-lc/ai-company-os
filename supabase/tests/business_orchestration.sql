BEGIN;
CREATE FUNCTION pg_temp.business_complete(p_job uuid,p_body text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE token uuid:=gen_random_uuid();BEGIN
 UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=p_job;
 PERFORM public.complete_chat_reply(p_job,token,p_body,'[]');
END $$;
CREATE FUNCTION pg_temp.business_pass(p_job uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE q uuid;BEGIN
 SELECT job_id INTO q FROM public.quality_reviews WHERE source_job_id=p_job;
 IF q IS NULL THEN RAISE EXCEPTION 'Independent inspection missing';END IF;
 PERFORM pg_temp.business_complete(q,'{"verdict":"pass","summary":"合成事务验证通过","checks":[{"id":"task_goal","status":"pass","evidence":"合成成果。","reason":"测试文本存在"},{"id":"task_acceptance","status":"pass","evidence":"合成成果。","reason":"测试标准满足"},{"id":"truthfulness","status":"pass","evidence":"合成成果。","reason":"没有外部执行声明"}]}');
END $$;
DO $test$
DECLARE owner uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135';f uuid;k uuid:=gen_random_uuid();j uuid;w uuid;final_version uuid;spec jsonb;status jsonb;denied boolean;gapflow uuid;research uuid;token uuid:=gen_random_uuid();
BEGIN
 PERFORM set_config('request.jwt.claim.sub',owner::text,true);
 denied:=false;BEGIN PERFORM public.create_business_workflow('TEST','goal',NULL,k,false);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Consent bypass';END IF;
 f:=public.create_business_workflow('BUSINESS ROLLBACK','分析后并行产出方案和文案，再整体交付',NULL,k,true);
 IF public.create_business_workflow('BUSINESS ROLLBACK','same',NULL,k,true)<>f THEN RAISE EXCEPTION 'Duplicate workflow';END IF;
 SELECT plan_job_id INTO j FROM public.business_workflows WHERE id=f;
 spec:='{"summary":"资料分析后并行，再汇总","steps":[{"id":"analysis","manager_code":"COO","assignment":"分析资料","depends_on":[],"capabilities":["text"],"acceptance":["提交合成成果。"]},{"id":"strategy","manager_code":"CTO","assignment":"拟定方案","depends_on":["analysis"],"capabilities":["text"],"acceptance":["提交合成成果。"]},{"id":"content","manager_code":"COO","assignment":"编写内容","depends_on":["analysis"],"capabilities":["text"],"acceptance":["提交合成成果。"]},{"id":"delivery","manager_code":"CTO","assignment":"汇总所有成果并检查一致性","depends_on":["analysis","strategy","content"],"capabilities":["text"],"acceptance":["提交合成成果。"]}]}';
 PERFORM pg_temp.business_complete(j,spec::text);
 IF NOT private.business_dispatch_ready() THEN RAISE EXCEPTION 'COS completion did not wake scheduler';END IF;
 PERFORM public.advance_business_workflows();
 IF (SELECT state FROM public.business_workflows WHERE id=f)<>'active' THEN RAISE EXCEPTION 'Plan failed: %',(SELECT last_error FROM public.business_workflows WHERE id=f);END IF;
 IF (SELECT count(*) FROM public.business_steps WHERE workflow_id=f AND work_order_id IS NOT NULL)<>1 THEN RAISE EXCEPTION 'Dependency gate bypass';END IF;
 SELECT t.id INTO j FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks t ON t.id::text=w.result->>'current_job_id' WHERE s.workflow_id=f AND s.step_key='analysis';
 PERFORM pg_temp.business_complete(j,'合成成果。');PERFORM public.advance_business_workflows();
 IF (SELECT count(*) FROM public.business_steps WHERE workflow_id=f AND work_order_id IS NOT NULL)<>1 THEN RAISE EXCEPTION 'Uninspected result unlocked successors';END IF;
 PERFORM pg_temp.business_pass(j);PERFORM public.advance_business_workflows();PERFORM public.advance_business_workflows();
 IF (SELECT count(*) FROM public.business_steps WHERE workflow_id=f AND work_order_id IS NOT NULL)<>3 THEN RAISE EXCEPTION 'Parallel fanout or idempotency failed';END IF;
 FOR j IN SELECT t.id FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks t ON t.id::text=w.result->>'current_job_id' WHERE s.workflow_id=f AND s.step_key IN ('strategy','content') LOOP
  PERFORM pg_temp.business_complete(j,'合成成果。');PERFORM pg_temp.business_pass(j);
 END LOOP;
 PERFORM public.advance_business_workflows();
 SELECT s.work_order_id,t.id INTO w,final_version FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks t ON t.id::text=w.result->>'current_job_id' WHERE s.workflow_id=f AND s.step_key='delivery';
 IF final_version IS NULL THEN RAISE EXCEPTION 'Integration employee not created';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.messages m JOIN public.tasks t ON t.request_message_id=m.id WHERE t.id=final_version AND m.content LIKE '%前置员工成果 strategy%' AND m.content LIKE '%前置员工成果 content%') THEN RAISE EXCEPTION 'Missing real predecessor outputs';END IF;
 denied:=false;BEGIN PERFORM public.review_business_workflow(f,'accept','bypass',final_version);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Premature CEO gate';END IF;
 PERFORM pg_temp.business_complete(final_version,'合成成果。');PERFORM pg_temp.business_pass(final_version);
 IF NOT private.business_ready(f) THEN RAISE EXCEPTION 'Validated integration not ready';END IF;
 status:=public.business_workflow_status(f);
 IF status->>'state'='accepted' OR jsonb_array_length(status->'steps')<>4 THEN RAISE EXCEPTION 'AI accepted business or graph missing steps';END IF;
 IF EXISTS(SELECT 1 FROM public.quality_reviews q JOIN public.business_steps s ON s.work_order_id=q.work_order_id JOIN public.tasks w ON w.id=s.work_order_id WHERE s.workflow_id=f AND q.employee_id::text=w.input->>'employee_id') THEN RAISE EXCEPTION 'Self inspection';END IF;
 -- A revision of a predecessor invalidates the whole delivery even though its old report passed.
 SELECT s.work_order_id,t.id INTO w,j FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks t ON t.id::text=w.result->>'current_job_id' WHERE s.workflow_id=f AND s.step_key='analysis';
 PERFORM public.review_work_order(w,j,'revise','合成测试：要求修改前置版本');
 IF private.business_ready(f) THEN RAISE EXCEPTION 'Stale upstream result accepted';END IF;
 denied:=false;BEGIN PERFORM public.review_business_workflow(f,'accept','bypass stale',final_version);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Stale integration accepted';END IF;
 -- Restore only in this rollback fixture to exercise the final CEO acceptance branch.
 UPDATE public.tasks SET result=jsonb_set(result,'{current_job_id}',to_jsonb(j::text)) WHERE id=w;
 PERFORM public.review_business_workflow(f,'accept','仅限回滚合成测试验收',final_version);
 IF (SELECT state FROM public.business_workflows WHERE id=f)<>'accepted' THEN RAISE EXCEPTION 'CEO acceptance not persisted';END IF;
 denied:=false;BEGIN PERFORM public.review_work_order(w,j,'revise','不得修改已验收业务的前置版本');EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Accepted business was mutable';END IF;
 IF has_table_privilege('authenticated','public.business_steps','UPDATE') OR has_function_privilege('authenticated','public.advance_business_workflows()','EXECUTE') OR has_function_privilege('anon','public.business_workflow_status(uuid)','EXECUTE') THEN RAISE EXCEPTION 'Excess permission';END IF;
 -- Existing skill research callbacks must resume the same business employee, with verified company skill reuse.
 gapflow:=public.create_business_workflow('SKILL CALLBACK ROLLBACK','检查文档能力缺口',NULL,gen_random_uuid(),true);
 SELECT plan_job_id INTO j FROM public.business_workflows WHERE id=gapflow;
 PERFORM pg_temp.business_complete(j,'{"summary":"检索所需工具","steps":[{"id":"research","manager_code":"COO","assignment":"先找技能再执行，未验证不得宣称完成","depends_on":[],"capabilities":["pdf_docx_documents"],"acceptance":["真实技能验证记录"]}]}');
 PERFORM public.advance_business_workflows();
 SELECT s.work_order_id,t.id INTO w,j FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks t ON t.id::text=w.result->>'current_job_id' WHERE s.workflow_id=gapflow;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 research:=public.pause_for_skill_search(j,token,'pdf docx document processing','[]');
 IF NOT EXISTS(SELECT 1 FROM public.task_skill_requests WHERE work_order_id=w AND source_job_id=j AND research_job_id=research AND state='verified') OR NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND execution_state='queued' AND input->>'business_flow_id'=gapflow::text AND input->>'skill_search_enabled'='false') THEN RAISE EXCEPTION 'Verified skill callback did not resume bound business employee';END IF;
 IF EXISTS(SELECT 1 FROM public.messages WHERE reply_task_id=j) THEN RAISE EXCEPTION 'Skill search treated as delivery';END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 denied:=false;BEGIN PERFORM public.business_workflow_status(f);EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Foreign workflow access';END IF;
END $test$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.business_workflows) OR EXISTS(SELECT 1 FROM public.business_steps) THEN RAISE EXCEPTION 'Foreign RLS leak';END IF;END $$;
RESET ROLE;
ROLLBACK;
SELECT 'PASS: durable COS DAG, quality-gated parallel fanout, idempotency, immutable dependency versions, integration quality and CEO gate, skill research callback reuse/resume, independent identities, private RPCs and RLS; all synthetic changes rolled back' AS checks;
