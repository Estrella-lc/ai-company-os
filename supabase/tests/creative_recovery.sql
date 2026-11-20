BEGIN;
DO $test$
DECLARE owner uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135';g uuid;j uuid;row record;chosen uuid;snapshot jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',owner::text,true);
 g:=public.create_company_goal('RECOVERY ROLLBACK','虚构成年角色恢复事务测试',gen_random_uuid(),true);
 FOR row IN SELECT * FROM public.tasks WHERE input->>'creative_goal_id'=g::text LOOP
  UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=gen_random_uuid(),lease_expires_at=now()+interval '1 minute' WHERE id=row.id RETURNING * INTO row;
  PERFORM public.complete_chat_reply(row.id,row.lease_token,'{"title":"合成方案","concept":"职场反转","rationale":"简单可行","tradeoffs":"固定声音","character_description":"成年男性","image_prompt_en":"one fictional adult male office worker","voice_text":"这份方案每个数字我都核对过"}','[]');chosen:=row.id;
 END LOOP;
 PERFORM public.advance_company_goals();PERFORM public.select_company_goal_proposal(g,chosen);
 SELECT research_job,selected_spec INTO j,snapshot FROM public.company_goals WHERE id=g;
 UPDATE public.tasks SET execution_state='failed',attempt_count=1,last_error_code='creative_validation_failed',finished_at=now(),input=input||'{"runner_id":"111/1"}',result='{"stage":"prepare","error_code":"phase_timeout"}' WHERE id=j;
 UPDATE public.company_goals SET state='blocked' WHERE id=g;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
 BEGIN IF public.retry_company_goal(g) THEN RAISE EXCEPTION 'Foreign owner recovered task';END IF;EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub',owner::text,true);
 IF NOT public.retry_company_goal(g) OR public.retry_company_goal(g) THEN RAISE EXCEPTION 'Recovery not idempotent';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND attempt_count=1 AND max_attempts=2 AND execution_state='queued' AND input->'creative_attempt_history'->0->'result'->>'stage'='prepare' AND NOT input?'runner_id') THEN RAISE EXCEPTION 'Attempt/history invariant';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.company_goals WHERE id=g AND research_job=j AND selected_spec=snapshot AND state='researching') THEN RAISE EXCEPTION 'Original task or proposal changed';END IF;
 UPDATE public.tasks SET execution_state='failed',finished_at=now(),attempt_count=2,last_error_code='creative_validation_failed' WHERE id=j;
 UPDATE public.company_goals SET state='blocked' WHERE id=g;
 IF public.retry_company_goal(g) THEN RAISE EXCEPTION 'Two-attempt limit bypassed';END IF;
 IF has_function_privilege('anon','public.retry_company_goal(uuid)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous recovery allowed';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: owner-only same-task recovery, frozen selection, preserved failure and lifetime two-attempt cap; fixtures rolled back' AS checks;
