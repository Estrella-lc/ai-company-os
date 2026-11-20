BEGIN;
ALTER TABLE public.film_workflows ADD COLUMN candidate_history jsonb NOT NULL DEFAULT '[]'::jsonb;
CREATE FUNCTION public.record_film_candidate(p_task uuid,p_token uuid,p_content text,p_error text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.tasks;f public.film_workflows;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='chat_reply' AND execution_state='running' AND lease_token=p_token AND lease_expires_at>now();
 IF j.id IS NULL OR length(p_content)>16000 OR p_error NOT IN ('JSON_FORMAT','SHOT_COUNT','SHOT_ID','SHOT_TIMELINE','UNSUPPORTED_MOTION','UNAPPROVED_IMAGE','UNAPPROVED_VOICE','VOICE_FIDELITY_OR_TRUNCATION','MISSING_VOICE','FILM_DURATION','INVALID_FILM_REPORT','INVALID_FILM_CAPABILITIES','INVALID_FILM_INSPECTION') THEN RETURN false;END IF;
 SELECT * INTO f FROM public.film_workflows WHERE id=(j.input->>'film_workflow_id')::uuid AND created_by=j.created_by FOR UPDATE;
 IF f.id IS NULL OR f.employee_jobs->>(j.input->>'film_phase') IS DISTINCT FROM j.id::text OR jsonb_array_length(f.candidate_history)>=20 THEN RETURN false;END IF;
 UPDATE public.film_workflows SET candidate_history=candidate_history||jsonb_build_array(jsonb_build_object('task',j.id,'phase',j.input->>'film_phase','attempt',j.attempt_count,'error',p_error,'candidate',p_content,'at',now())) WHERE id=f.id;
 RETURN true;
END $$;
CREATE FUNCTION public.retry_film_planning(p_goal uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE f public.film_workflows;j public.tasks;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO f FROM public.film_workflows WHERE goal_id=p_goal AND created_by=auth.uid() FOR UPDATE;
 IF f.id IS NULL OR f.state<>'blocked' THEN RETURN false;END IF;
 SELECT t.* INTO j FROM jsonb_each_text(f.employee_jobs) e JOIN public.tasks t ON t.id=e.value::uuid WHERE t.created_by=f.created_by AND t.execution_state='failed' AND t.attempt_count<t.max_attempts AND (t.last_error_code IN ('execution_failed','provider_unavailable') OR t.last_error_code LIKE 'film_candidate_%') ORDER BY t.created_at DESC LIMIT 1 FOR UPDATE OF t;
 IF j.id IS NULL THEN RETURN false;END IF;
 UPDATE public.tasks SET execution_state='queued',finished_at=NULL,available_at=now(),lease_token=NULL,lease_expires_at=NULL,updated_at=now() WHERE id=j.id;
 UPDATE public.film_workflows SET state=CASE WHEN j.input->>'film_phase'='inspection' THEN 'reviewing' ELSE 'planning' END,last_error=NULL WHERE id=f.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',auth.uid()::text,'film.planning_recovered','film_workflow',f.id::text,jsonb_build_object('task',j.id,'attempt_count',j.attempt_count,'max_attempts',j.max_attempts,'prior_error',j.last_error_code));
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.record_film_candidate(uuid,uuid,text,text),public.retry_film_planning(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.record_film_candidate(uuid,uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.retry_film_planning(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
