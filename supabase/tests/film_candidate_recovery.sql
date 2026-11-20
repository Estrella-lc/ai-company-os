BEGIN;
DO $test$
DECLARE f public.film_workflows;j public.tasks;token uuid:=gen_random_uuid();
BEGIN
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 SELECT * INTO f FROM public.film_workflows WHERE id='9298b01c-c307-4a54-b1a7-708152b1b5a0';
 SELECT * INTO j FROM public.tasks WHERE id=(f.employee_jobs->>'storyboard')::uuid;
 IF NOT public.retry_film_planning(f.goal_id) OR public.retry_film_planning(f.goal_id) THEN RAISE EXCEPTION 'Recovery idempotency';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j.id AND attempt_count=j.attempt_count AND max_attempts=j.max_attempts AND execution_state='queued') THEN RAISE EXCEPTION 'Attempt reset';END IF;
 UPDATE public.tasks SET execution_state='running',lease_token=token,lease_expires_at=now()+interval '1 minute' WHERE id=j.id;
 IF public.record_film_candidate(j.id,gen_random_uuid(),'synthetic invalid JSON','JSON_FORMAT') THEN RAISE EXCEPTION 'Forged lease';END IF;
 IF NOT public.record_film_candidate(j.id,token,'synthetic invalid JSON','JSON_FORMAT') THEN RAISE EXCEPTION 'Bound candidate refused';END IF;
 UPDATE public.tasks SET execution_state='failed',attempt_count=max_attempts,finished_at=now(),lease_token=NULL,lease_expires_at=NULL WHERE id=j.id;
 UPDATE public.film_workflows SET state='blocked' WHERE id=f.id;
 IF public.retry_film_planning(f.goal_id) THEN RAISE EXCEPTION 'Attempt cap bypassed';END IF;
 IF has_function_privilege('authenticated','public.record_film_candidate(uuid,uuid,text,text)','EXECUTE') THEN RAISE EXCEPTION 'Browser candidate injection';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: same-task recovery, unchanged attempt caps, idempotency, bound rejection evidence and no browser injection; fixtures rolled back' AS checks;
