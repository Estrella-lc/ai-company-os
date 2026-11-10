-- Run after the work-order migration. All test data rolls back.
BEGIN;

DO $test$
DECLARE ceo uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135'; a uuid; w uuid; k uuid:=gen_random_uuid(); j uuid; j2 uuid; token uuid:=gen_random_uuid();
BEGIN
 SELECT id INTO a FROM public.agents WHERE code='COS' AND is_active;
 PERFORM set_config('request.jwt.claim.sub',ceo::text,true);
 w:=public.create_work_order('TASK CENTER ROLLBACK TEST','Prepare a short plan','Two concrete steps',a,k);
 IF w IS DISTINCT FROM public.create_work_order('TASK CENTER ROLLBACK TEST','Prepare a short plan','Two concrete steps',a,k) THEN RAISE EXCEPTION 'Idempotency failed'; END IF;
 SELECT (result->>'current_job_id')::uuid INTO j FROM public.tasks WHERE id=w;
 BEGIN PERFORM public.review_work_order(w,j,'accept',''); RAISE EXCEPTION 'Queued accepted'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM public.review_work_order(w,gen_random_uuid(),'accept',''); RAISE EXCEPTION 'Stale review allowed'; EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.complete_chat_reply(j,token,'First test result','[]');
 BEGIN PERFORM public.review_work_order(w,j,'revise',''); RAISE EXCEPTION 'Empty feedback allowed'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 PERFORM public.review_work_order(w,j,'revise','Make the second step specific');
 SELECT (result->>'current_job_id')::uuid INTO j2 FROM public.tasks WHERE id=w;
 IF j2=j THEN RAISE EXCEPTION 'Revision not queued'; END IF;
 BEGIN PERFORM public.review_work_order(w,j,'revise','duplicate'); RAISE EXCEPTION 'Duplicate revision allowed'; EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j2;
 PERFORM public.complete_chat_reply(j2,token,'Second test result','[]');
 PERFORM public.review_work_order(w,j2,'accept','Meets criteria');
 PERFORM public.review_work_order(w,j2,'accept','Meets criteria');
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=w AND result->>'review_state'='accepted' AND jsonb_array_length(input->'runs')=2) THEN RAISE EXCEPTION 'Review result missing'; END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 BEGIN PERFORM public.create_work_order('Unauthorized','goal','criteria',a,gen_random_uuid()); RAISE EXCEPTION 'Non CEO created'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.review_work_order(w,j2,'accept',''); RAISE EXCEPTION 'Non CEO reviewed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF has_function_privilege('anon','public.create_work_order(text,text,text,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous execute allowed'; END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: create, idempotency, ready/stale guards, revision history, acceptance, non-CEO rejection; rolled back' AS checks;
