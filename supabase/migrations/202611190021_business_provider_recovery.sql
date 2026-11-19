BEGIN;
CREATE FUNCTION public.retry_business_workflow(p_flow uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE f public.business_workflows;t public.tasks;n integer:=0;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO f FROM public.business_workflows WHERE id=p_flow AND created_by=auth.uid() FOR UPDATE;
 IF f.id IS NULL OR f.state='accepted' THEN RAISE EXCEPTION 'Workflow denied' USING ERRCODE='42501';END IF;
 FOR t IN SELECT * FROM public.tasks j WHERE j.created_by=f.created_by AND j.execution_state='failed' AND j.last_error_code='provider_unavailable' AND j.attempt_count<5 AND
 (j.id=f.plan_job_id OR EXISTS(SELECT 1 FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id WHERE s.workflow_id=f.id AND (j.id::text=w.result->>'current_job_id' OR EXISTS(SELECT 1 FROM public.quality_reviews q WHERE q.job_id=j.id AND q.source_job_id::text=w.result->>'current_job_id' AND q.work_order_id=w.id)))) FOR UPDATE LOOP
  UPDATE public.tasks SET execution_state='queued',available_at=now(),finished_at=NULL,lease_token=NULL,lease_expires_at=NULL,max_attempts=greatest(max_attempts,t.attempt_count+1),updated_at=now() WHERE id=t.id;
  n:=n+1;
 END LOOP;
 IF n=0 THEN RETURN false;END IF;
 UPDATE public.business_workflows SET state=CASE WHEN EXISTS(SELECT 1 FROM public.tasks WHERE id=f.plan_job_id AND execution_state='queued') THEN 'planning' ELSE 'active' END,last_error=NULL,updated_at=now() WHERE id=f.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',auth.uid()::text,'business.provider_retry_requested','business_workflow',f.id::text,jsonb_build_object('jobs',n,'maximum_attempts',5));
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.retry_business_workflow(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.retry_business_workflow(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
