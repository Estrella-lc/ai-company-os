-- Synthetic fixtures only; no real delivery review is changed.
BEGIN;
DO $test$
DECLARE ceo uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135'; manager uuid; j uuid; report jsonb; n integer;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',ceo::text,true);
 SELECT id INTO manager FROM public.agents WHERE code='COS';
 j:=public.request_skill_research(manager,'样例验收回滚测试 general','agent skills',gen_random_uuid());
 BEGIN PERFORM public.review_skill_sample(j,'accept','');RAISE EXCEPTION 'Queued sample accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 report:=jsonb_build_object('run_url','https://github.com/Estrella-lc/ai-company-os/actions/runs/123','candidates',jsonb_build_array(jsonb_build_object('verification',jsonb_build_object('passed',true,'scope','static_review_only','output_sha256',repeat('a',64)))));
 UPDATE public.tasks SET execution_state='succeeded',finished_at=now(),result=report WHERE id=j;
 BEGIN PERFORM public.review_skill_sample(j,'accept','');RAISE EXCEPTION 'Static check accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 report:=jsonb_set(report,'{candidates,0,verification,scope}','"subtitle_fixture_v1"');
 UPDATE public.tasks SET result=report WHERE id=j;
 BEGIN PERFORM public.review_skill_sample(j,'revise',' ');RAISE EXCEPTION 'Blank revision allowed';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 PERFORM public.review_skill_sample(j,'revise','增加样例说明');
 PERFORM public.review_skill_sample(j,'revise','增加样例说明');
 IF (SELECT count(*) FROM public.audit_logs WHERE action='skill_sample.revise' AND resource_id=j::text)<>1 THEN RAISE EXCEPTION 'Duplicate revision';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND result->'sample_review'->>'state'='changes_requested' AND execution_state='succeeded') THEN RAISE EXCEPTION 'Revision lost or executor state modified';END IF;
 PERFORM public.review_skill_sample(j,'accept','自动化验收测试，仅合成样例');
 PERFORM public.review_skill_sample(j,'accept','重复请求');
 SELECT count(*) INTO n FROM public.audit_logs WHERE action='skill_sample.accept' AND resource_id=j::text;
 IF n<>1 THEN RAISE EXCEPTION 'Duplicate acceptance';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND result->'sample_review'->>'state'='accepted' AND result->>'run_url'=report->>'run_url' AND result->'candidates'=report->'candidates') THEN RAISE EXCEPTION 'Evidence overwritten';END IF;
 BEGIN PERFORM public.review_skill_sample(j,'revise','不能修改已验收样例');RAISE EXCEPTION 'Accepted sample revised';EXCEPTION WHEN serialization_failure THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 BEGIN PERFORM public.review_skill_sample(j,'accept','');RAISE EXCEPTION 'Non CEO accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub','',true);
 BEGIN PERFORM public.review_skill_sample(j,'accept','');RAISE EXCEPTION 'Anonymous accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 IF has_function_privilege('anon','public.review_skill_sample(uuid,text,text)','EXECUTE') OR has_table_privilege('authenticated','public.tasks','UPDATE') THEN RAISE EXCEPTION 'Unexpected browser grant';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: review eligibility, authorization, idempotency, evidence preservation, revision and acceptance; rolled back' AS checks;
