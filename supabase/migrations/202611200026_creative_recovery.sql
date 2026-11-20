BEGIN;
-- Recover the same failed capability task without granting an extra attempt.
CREATE OR REPLACE FUNCTION public.retry_company_goal(p_goal uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.company_goals;j public.tasks;n integer:=0;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO g FROM public.company_goals WHERE id=p_goal AND created_by=auth.uid() FOR UPDATE;
 IF g.id IS NULL OR g.state<>'blocked' THEN RETURN false;END IF;
 SELECT * INTO j FROM public.tasks WHERE id=g.research_job AND created_by=g.created_by FOR UPDATE;
 IF j.id IS NOT NULL AND j.task_kind='skill_research' AND j.input->>'mode'='creative_samples' AND j.execution_state='failed' AND j.last_error_code='creative_validation_failed' AND j.attempt_count<least(j.max_attempts,2) THEN
  UPDATE public.tasks SET execution_state='queued',finished_at=NULL,available_at=now(),lease_token=NULL,lease_expires_at=NULL,last_error_code=NULL,result=NULL,
   input=(input-'runner_id')||jsonb_build_object('creative_attempt_history',coalesce(input->'creative_attempt_history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('attempt',j.attempt_count,'result',j.result,'last_error_code',j.last_error_code,'runner_id',j.input->>'runner_id','finished_at',j.finished_at))),updated_at=now() WHERE id=j.id;
  UPDATE public.company_goals SET state='researching',last_error=NULL,updated_at=now() WHERE id=g.id;
  INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',auth.uid()::text,'goal.creative_recovered','company_goal',g.id::text,jsonb_build_object('task_id',j.id,'attempt_count',j.attempt_count,'max_attempts',j.max_attempts));
  RETURN true;
 END IF;
 UPDATE public.tasks SET execution_state='queued',finished_at=NULL,available_at=now(),max_attempts=greatest(max_attempts,attempt_count+1),updated_at=now()
 WHERE created_by=g.created_by AND execution_state='failed' AND last_error_code='provider_unavailable' AND attempt_count<6 AND id IN(SELECT value::uuid FROM jsonb_each_text(g.proposal_jobs||g.review_jobs));
 GET DIAGNOSTICS n=ROW_COUNT;IF n=0 THEN RETURN false;END IF;
 UPDATE public.company_goals SET state=CASE WHEN g.selected_job IS NULL THEN 'comparing' ELSE 'reviewing' END,last_error=NULL,updated_at=now() WHERE id=g.id;RETURN true;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
