BEGIN;
CREATE FUNCTION pg_temp.quality_fixture_complete(p_job uuid,p_body text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE token uuid:=gen_random_uuid();BEGIN
 UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=p_job;
 PERFORM public.complete_chat_reply(p_job,token,p_body,'[]');
END $$;
DO $test$
DECLARE f uuid;j uuid;w uuid;q public.quality_reviews;old_job uuid;new_job uuid;original_snapshot jsonb;invalid jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 f:=public.create_business_workflow('QUALITY EVIDENCE ROLLBACK','合成成果逐字检查',NULL,gen_random_uuid(),true);
 SELECT plan_job_id INTO j FROM public.business_workflows WHERE id=f;
 PERFORM pg_temp.quality_fixture_complete(j,'{"summary":"单项合成任务","steps":[{"id":"delivery","manager_code":"CTO","assignment":"提交合成成果。","depends_on":[],"capabilities":["text"],"acceptance":["提交合成成果。"]}]}');
 PERFORM public.advance_business_workflows();
 SELECT s.work_order_id,t.id INTO w,j FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks t ON t.id::text=w.result->>'current_job_id' WHERE s.workflow_id=f;
 PERFORM pg_temp.quality_fixture_complete(j,'合成成果。');
 SELECT * INTO q FROM public.quality_reviews WHERE source_job_id=j;
 old_job:=q.job_id;original_snapshot:=q.snapshot;
 invalid:=jsonb_build_object('verdict','needs_human','summary','通过项的证据不是本版成果中的逐字原文。系统未自动判为合格，需要人工复核。','checks',jsonb_build_array(jsonb_build_object('id','task_goal','status','not_checked','evidence','','reason','逐字引用不符'),jsonb_build_object('id','task_acceptance','status','not_checked','evidence','','reason','逐字引用不符'),jsonb_build_object('id','truthfulness','status','not_checked','evidence','','reason','逐字引用不符')));
 PERFORM pg_temp.quality_fixture_complete(old_job,invalid::text);
 UPDATE public.business_workflows SET state='blocked' WHERE id=f;
 UPDATE public.quality_reviews SET report=jsonb_set(report,'{summary}','"外部事实无法核实"') WHERE id=q.id;
 SELECT * INTO q FROM public.quality_reviews WHERE id=q.id;
 IF private.business_quality_repairable(q) THEN RAISE EXCEPTION 'Genuine uncertainty auto retried';END IF;
 UPDATE public.quality_reviews SET report=invalid WHERE id=q.id;
 UPDATE public.tasks SET result=jsonb_set(result,'{current_job_id}',to_jsonb(old_job::text)) WHERE id=w;
 SELECT * INTO q FROM public.quality_reviews WHERE id=q.id;
 IF private.business_quality_repairable(q) THEN RAISE EXCEPTION 'Stale source repair permitted';END IF;
 UPDATE public.tasks SET result=jsonb_set(result,'{current_job_id}',to_jsonb(j::text)) WHERE id=w;
 IF NOT private.business_dispatch_ready() THEN RAISE EXCEPTION 'Blocked evidence repair not scheduled';END IF;
 PERFORM public.repair_business_quality_reports();
 SELECT job_id INTO new_job FROM public.quality_reviews WHERE id=q.id;
 IF new_job=old_job OR new_job IS NULL THEN RAISE EXCEPTION 'No fresh independent inspection';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.quality_report_history WHERE review_id=q.id AND job_id=old_job AND report=invalid AND source_job_id=j) THEN RAISE EXCEPTION 'Old report lost';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.quality_reviews WHERE id=q.id AND snapshot=original_snapshot AND source_job_id=j AND report IS NULL AND employee_id=q.employee_id) THEN RAISE EXCEPTION 'Fixed snapshot or inspector changed';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.messages WHERE reply_task_id=old_job) OR NOT EXISTS(SELECT 1 FROM public.messages WHERE reply_task_id=j AND content='合成成果。') THEN RAISE EXCEPTION 'Old result overwritten';END IF;
 PERFORM public.repair_business_quality_reports();
 IF (SELECT job_id FROM public.quality_reviews WHERE id=q.id)<>new_job THEN RAISE EXCEPTION 'Duplicate repair job';END IF;
 PERFORM pg_temp.quality_fixture_complete(new_job,invalid::text);
 SELECT * INTO q FROM public.quality_reviews WHERE id=q.id;
 IF private.business_quality_repairable(q) THEN RAISE EXCEPTION 'Unbounded report repair';END IF;
 IF private.business_ready(f) THEN RAISE EXCEPTION 'Failed inspection unlocked CEO acceptance';END IF;
 IF has_function_privilege('authenticated','public.repair_business_quality_reports()','EXECUTE') OR has_function_privilege('anon','public.repair_business_quality_reports()','EXECUTE') OR has_table_privilege('service_role','public.quality_report_history','UPDATE') OR has_table_privilege('authenticated','public.quality_report_history','INSERT') THEN RAISE EXCEPTION 'Excess repair permissions';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: fixed-version independent evidence repair, immutable history, semantic uncertainty/stale/duplicate/repeat guards, CEO gate and restricted roles; rollback' AS checks;
