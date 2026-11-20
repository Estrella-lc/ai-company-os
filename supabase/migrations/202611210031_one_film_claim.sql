-- CEO explicitly authorized one additional claim for this existing film task.
BEGIN;
CREATE TABLE private.film_claim_allowances(
 task_id uuid PRIMARY KEY REFERENCES public.tasks(id),
 expires_at timestamptz NOT NULL,consumed_at timestamptz,runner_id text
);
ALTER TABLE private.film_claim_allowances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.film_claim_allowances FROM PUBLIC,anon,authenticated,service_role;
INSERT INTO private.film_claim_allowances(task_id,expires_at)
SELECT j.id,(date_trunc('day',now() AT TIME ZONE 'UTC')+interval '1 day') AT TIME ZONE 'UTC'
FROM public.tasks j JOIN public.film_workflows f ON f.render_job=j.id AND f.created_by=j.created_by
WHERE j.id='1ca2b05b-bc52-4f2f-9039-e64c0c4cb940' AND j.input->>'mode'='film_render' AND j.execution_state='queued';
CREATE FUNCTION public.claim_authorized_film_once(p_runner text) RETURNS SETOF public.tasks LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a private.film_claim_allowances;j public.tasks;
BEGIN
 IF p_runner IS NULL OR p_runner !~ '^[0-9]+/[0-9]+$' THEN RAISE EXCEPTION 'Invalid runner';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('skill_daily_claim',0));
 SELECT * INTO a FROM private.film_claim_allowances WHERE task_id='1ca2b05b-bc52-4f2f-9039-e64c0c4cb940' FOR UPDATE;
 IF a.task_id IS NULL OR a.expires_at<=now() THEN RETURN;END IF;
 SELECT * INTO j FROM public.tasks WHERE id=a.task_id FOR UPDATE;
 IF a.consumed_at IS NOT NULL THEN
  IF a.runner_id=p_runner AND j.execution_state='running' AND j.lease_expires_at>now() AND j.input->>'runner_id'=p_runner THEN RETURN NEXT j;END IF;
  RETURN;
 END IF;
 IF j.execution_state<>'queued' OR j.available_at>now() OR j.attempt_count>=j.max_attempts OR j.input->>'mode' IS DISTINCT FROM 'film_render' THEN RETURN;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.film_workflows f JOIN public.company_goals g ON g.id=f.goal_id AND g.created_by=f.created_by WHERE f.render_job=j.id AND f.created_by=j.created_by AND f.state='ready' AND g.state='accepted' AND g.research_job=f.source_job) THEN RETURN;END IF;
 UPDATE private.film_claim_allowances SET consumed_at=now(),runner_id=p_runner WHERE task_id=j.id;
 UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=gen_random_uuid(),lease_expires_at=now()+interval '10 minutes',started_at=coalesce(started_at,now()),input=input||jsonb_build_object('runner_id',p_runner),updated_at=now() WHERE id=j.id RETURNING * INTO j;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id,details) VALUES('worker','skill_research.claimed','task',j.id::text,jsonb_build_object('one_time_ceo_authorization',true,'runner',p_runner));
 RETURN NEXT j;
END $$;
REVOKE ALL ON FUNCTION public.claim_authorized_film_once(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.claim_authorized_film_once(text) TO service_role;
INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details)
SELECT 'user',j.created_by::text,'film.extra_claim_authorized','task',j.id::text,'{"additional_claims":1,"additional_paid_budget_usd":0,"reason":"CEO explicitly requested this one film render"}'::jsonb FROM public.tasks j JOIN private.film_claim_allowances a ON a.task_id=j.id;
COMMIT;

