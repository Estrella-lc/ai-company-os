-- Rollback-only integration test using the accepted live sample as immutable source.
BEGIN;
CREATE FUNCTION pg_temp.finish_film_fixture(j uuid,body text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE token uuid:=gen_random_uuid();BEGIN
 UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=token,lease_expires_at=now()+interval '1 minute' WHERE id=j;
 PERFORM public.complete_chat_reply(j,token,body,'[]');END $$;
DO $test$
DECLARE f uuid;j uuid;g uuid:='ca02a51c-d540-4aa1-a500-c3bcfbe0d894';
BEGIN
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 f:=public.request_film_planning(g);
 IF public.request_film_planning(g)<>f THEN RAISE EXCEPTION 'Duplicate workflow';END IF;
 SELECT (employee_jobs->>'storyboard')::uuid INTO j FROM public.film_workflows WHERE id=f;
 PERFORM pg_temp.finish_film_fixture(j,'{"shots":[{"id":"fixture"}]}');PERFORM public.advance_film_planning();
 SELECT (employee_jobs->>'capabilities')::uuid INTO j FROM public.film_workflows WHERE id=f;
 IF j IS NULL THEN RAISE EXCEPTION 'Technical check not queued';END IF;
 PERFORM pg_temp.finish_film_fixture(j,'{"status":"ready","summary":"rollback fixture","missing_skills":[]}');PERFORM public.advance_film_planning();
 SELECT (employee_jobs->>'inspection')::uuid INTO j FROM public.film_workflows WHERE id=f;
 IF j IS NULL THEN RAISE EXCEPTION 'Inspection not queued';END IF;
 PERFORM pg_temp.finish_film_fixture(j,'{"verdict":"pass","summary":"rollback fixture","evidence":["fixture"]}');PERFORM public.advance_film_planning();
 IF NOT EXISTS(SELECT 1 FROM public.film_workflows WHERE id=f AND state='ready') THEN RAISE EXCEPTION 'Planning not ready';END IF;
 IF has_table_privilege('authenticated','public.film_workflows','UPDATE') OR has_function_privilege('anon','public.request_film_planning(uuid)','EXECUTE') THEN RAISE EXCEPTION 'Privilege boundary';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: idempotent request, sequential three-employee dispatch and planning-only result; all fixtures rolled back' AS checks;
