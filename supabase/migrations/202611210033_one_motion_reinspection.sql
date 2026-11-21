-- Explicit CEO authorization: one additional fallback inspection of the same file.
BEGIN;
DO $review$
DECLARE m public.motion_jobs;old public.tasks;j uuid;
BEGIN
 SELECT * INTO m FROM public.motion_jobs WHERE id='44923769-416e-46ae-98ff-b624486bf3fa' FOR UPDATE;
 IF m.id IS NULL OR m.report->>'sha256' IS DISTINCT FROM 'a5968291d27d54b820af4895b75c251f3f87f98021999e2fd29b4c056aa792da' THEN RAISE EXCEPTION 'Same video required';END IF;
 IF m.report?'fallback_reinspection_job' THEN RETURN;END IF;
 SELECT * INTO old FROM public.tasks WHERE id=m.quality_job AND created_by=m.created_by;
 IF old.execution_state IS DISTINCT FROM 'failed' OR old.attempt_count<>old.max_attempts OR old.last_error_code IS DISTINCT FROM 'provider_unavailable' THEN RAISE EXCEPTION 'Original bounded review must be exhausted';END IF;
 j:=private.goal_reply(m.created_by,'COO','独立动作质检 · CEO授权单次回退复核',jsonb_build_object('motion_review_id',m.id,'motion_use_fallback',true,'prior_quality_job',old.id),'quality_inspector');
 UPDATE public.tasks SET max_attempts=1 WHERE id=j;
 UPDATE public.motion_jobs SET quality_job=j,state='reviewing',report=report||jsonb_build_object('prior_quality_job',old.id,'prior_quality_attempts',old.attempt_count,'fallback_reinspection_job',j) WHERE id=m.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',m.created_by::text,'motion.single_fallback_review_authorized','task',j::text,jsonb_build_object('prior_task',old.id,'max_attempts',1,'video_sha256',m.report->>'sha256'));
END $review$;
COMMIT;

