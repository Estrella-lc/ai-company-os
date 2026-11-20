-- Run only inside the migration's outer rollback test transaction.
DO $test$
DECLARE g uuid:='ca02a51c-d540-4aa1-a500-c3bcfbe0d894';j uuid;token uuid:=gen_random_uuid();f public.film_workflows;n integer;path text;
BEGIN
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 j:=public.request_film_render(g);
 IF public.request_film_render(g)<>j THEN RAISE EXCEPTION 'Duplicate render';END IF;
 IF has_function_privilege('anon','public.request_film_render(uuid)','EXECUTE') OR has_function_privilege('authenticated','public.film_task_context(uuid,uuid,text)','EXECUTE') OR has_function_privilege('authenticated','public.finish_film_render(uuid,uuid,text,jsonb,boolean)','EXECUTE') THEN RAISE EXCEPTION 'Privilege leak';END IF;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000099',true);
 BEGIN PERFORM public.request_film_render(g);RAISE EXCEPTION 'Foreign owner allowed';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '1 minute',input=input||'{"runner_id":"123/1"}'::jsonb WHERE id=j;
 SELECT count(*) INTO n FROM public.film_task_context(j,token,'123/1');IF n<>1 THEN RAISE EXCEPTION 'Valid context missing';END IF;
 SELECT count(*) INTO n FROM public.film_task_context(j,token,'999/1');IF n<>0 THEN RAISE EXCEPTION 'Foreign runner allowed';END IF;
 SELECT count(*) INTO n FROM public.film_task_context(j,gen_random_uuid(),'123/1');IF n<>0 THEN RAISE EXCEPTION 'Foreign lease allowed';END IF;
 UPDATE public.tasks SET lease_expires_at=now()-interval '1 second' WHERE id=j;
 IF public.finish_film_render(j,token,'123/1','{}',true) THEN RAISE EXCEPTION 'Expired callback allowed';END IF;
 UPDATE public.tasks SET lease_expires_at=now()+interval '1 minute' WHERE id=j;
 BEGIN PERFORM public.finish_film_render(j,token,'123/1','{}',false);RAISE EXCEPTION 'Missing output allowed';EXCEPTION WHEN raise_exception THEN IF SQLERRM='Missing output allowed' THEN RAISE;END IF;END;
 IF NOT public.finish_film_render(j,token,'123/1','{}',true) THEN RAISE EXCEPTION 'Failure recovery denied';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND execution_state='queued' AND attempt_count=1 AND max_attempts=2 AND lease_token IS NULL) THEN RAISE EXCEPTION 'Attempt reset or recovery invalid';END IF;
 IF EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND result->>'ceo_acceptance'='true') THEN RAISE EXCEPTION 'CEO acceptance changed';END IF;
END $test$;
SELECT 'PASS: idempotence, owner, function privileges, lease, runner, expiry, missing output and bounded recovery; fixtures rolled back' AS checks;

