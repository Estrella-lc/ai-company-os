-- Apply the COS planning migration first. Test-only records are rolled back.
BEGIN;
DO $test$
DECLARE ceo uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135'; k uuid:=gen_random_uuid(); p uuid; j uuid; token uuid:=gen_random_uuid(); plan jsonb; first_id uuid; second_id uuid; work uuid; work2 uuid; job uuid; n integer;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',ceo::text,true);
 plan:='{"mode":"team","reason":"Two specialties with a handoff","missing_information":[],"tasks":[{"title":"Product outline","agent_code":"CPO","instruction":"Write an outline","acceptance":"Two priorities","after":[]},{"title":"Marketing draft","agent_code":"CMO","instruction":"Use the accepted outline","acceptance":"One short draft","after":[0]}]}'::jsonb;
 PERFORM public.validate_cos_plan(plan);
 PERFORM public.validate_cos_plan('{"mode":"direct","reason":"Simple summary","missing_information":[],"tasks":[{"title":"Summary","agent_code":"COS","instruction":"Summarize","acceptance":"One sentence","after":[]}]}');
 PERFORM public.validate_cos_plan('{"mode":"single","reason":"Marketing specialty","missing_information":[],"tasks":[{"title":"Copy","agent_code":"CMO","instruction":"Draft copy","acceptance":"One paragraph","after":[]}]}');
 BEGIN PERFORM public.validate_cos_plan(jsonb_set(plan,'{tasks,0,after}','[1]')); RAISE EXCEPTION 'Forward dependency allowed'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM public.validate_cos_plan(jsonb_set(plan,'{tasks,0,agent_code}','"UNKNOWN"')); RAISE EXCEPTION 'Unknown assignee allowed'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 p:=public.create_work_plan('COS PLANNING ROLLBACK TEST','Plan only',k);
 IF p IS DISTINCT FROM public.create_work_plan('COS PLANNING ROLLBACK TEST','Plan only',k) THEN RAISE EXCEPTION 'Duplicate planning'; END IF;
 IF EXISTS(SELECT 1 FROM public.tasks WHERE task_kind='plan_assignment' AND input->>'plan_id'=p::text) THEN RAISE EXCEPTION 'Dispatched before approval'; END IF;
 BEGIN PERFORM public.review_work_plan(p,0,plan,true); RAISE EXCEPTION 'Approved unfinished planning'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 SELECT (result->>'current_job_id')::uuid INTO j FROM public.tasks WHERE id=p;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.complete_chat_reply(j,token,plan::text,'[]');
 BEGIN PERFORM public.review_work_plan(p,0,jsonb_set(plan,'{missing_information}','["Missing source files"]'),true); RAISE EXCEPTION 'Approved missing information'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 PERFORM public.review_work_plan(p,0,plan,false);
 BEGIN PERFORM public.review_work_plan(p,0,plan,true); RAISE EXCEPTION 'Stale approval allowed'; EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
 PERFORM public.review_work_plan(p,1,plan,true);
 PERFORM public.review_work_plan(p,1,plan,true);
 SELECT count(*) INTO n FROM public.tasks WHERE task_kind='plan_assignment' AND input->>'plan_id'=p::text;
 IF n<>2 THEN RAISE EXCEPTION 'Approval duplicated assignments'; END IF;
 SELECT id,(result->>'work_order_id')::uuid INTO first_id,work FROM public.tasks WHERE task_kind='plan_assignment' AND input->>'plan_id'=p::text AND input->>'step_index'='0';
 SELECT id INTO second_id FROM public.tasks WHERE task_kind='plan_assignment' AND input->>'plan_id'=p::text AND input->>'step_index'='1';
 IF work IS NULL THEN RAISE EXCEPTION 'Root not started'; END IF;
 BEGIN PERFORM public.start_plan_assignment(second_id); RAISE EXCEPTION 'Blocked step started'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 SELECT (result->>'current_job_id')::uuid INTO job FROM public.tasks WHERE id=work;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=job;
 PERFORM public.complete_chat_reply(job,token,'APPROVED_PREDECESSOR_OUTPUT','[]');
 BEGIN PERFORM public.start_plan_assignment(second_id); RAISE EXCEPTION 'Unaccepted predecessor allowed'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 PERFORM public.review_work_order(work,job,'accept','Ready');
 work2:=public.start_plan_assignment(second_id);
 IF work2 IS DISTINCT FROM public.start_plan_assignment(second_id) THEN RAISE EXCEPTION 'Duplicate start'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=work2 AND description LIKE '%APPROVED_PREDECESSOR_OUTPUT%') THEN RAISE EXCEPTION 'Predecessor output not handed off'; END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 BEGIN PERFORM public.review_work_plan(p,2,plan,true); RAISE EXCEPTION 'Non CEO approved'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.start_plan_assignment(second_id); RAISE EXCEPTION 'Non CEO started'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.create_work_plan('Unauthorized','No',gen_random_uuid()); RAISE EXCEPTION 'Non CEO created'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF has_function_privilege('anon','public.review_work_plan(uuid,integer,jsonb,boolean)','EXECUTE') OR has_function_privilege('authenticated','public.validate_cos_plan(jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Unexpected execute privilege'; END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: modes, validation, approval, idempotency, dependencies, handoff and authorization; rolled back' AS checks;

