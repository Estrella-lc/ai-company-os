BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.quality_report_history (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),review_id uuid NOT NULL REFERENCES public.quality_reviews(id),
 created_by uuid NOT NULL REFERENCES auth.users(id),source_job_id uuid NOT NULL REFERENCES public.tasks(id),
 job_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),report jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.quality_report_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.quality_report_history FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.quality_report_history TO authenticated,service_role;
CREATE POLICY quality_history_ceo_read ON public.quality_report_history FOR SELECT TO authenticated
 USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE FUNCTION private.business_quality_repairable(p_review public.quality_reviews) RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT p_review.report->>'verdict'='needs_human'
 AND p_review.report->>'summary'='通过项的证据不是本版成果中的逐字原文。系统未自动判为合格，需要人工复核。'
 AND jsonb_array_length(p_review.report->'checks')=3
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_review.report->'checks') c WHERE c->>'status' IS DISTINCT FROM 'not_checked')
 AND NOT EXISTS(SELECT 1 FROM public.quality_report_history h WHERE h.review_id=p_review.id)
 AND EXISTS(SELECT 1 FROM public.business_steps s JOIN public.business_workflows f ON f.id=s.workflow_id
 JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks j ON j.id::text=w.result->>'current_job_id'
 JOIN public.tasks inspection ON inspection.id=p_review.job_id
 WHERE s.work_order_id=p_review.work_order_id AND f.created_by=p_review.created_by AND w.created_by=f.created_by
 AND f.state IN ('active','blocked') AND j.id=p_review.source_job_id AND j.execution_state='succeeded'
 AND inspection.execution_state='succeeded' AND inspection.created_by=f.created_by
 AND p_review.employee_id::text IS DISTINCT FROM w.input->>'employee_id'
 AND EXISTS(SELECT 1 FROM public.messages m WHERE m.reply_task_id=j.id AND m.content=p_review.snapshot->>'body'));
$$;
CREATE FUNCTION public.repair_business_quality_reports() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q public.quality_reviews;prior public.tasks;message uuid;job uuid;flow uuid;n integer:=0;
BEGIN
 FOR q IN SELECT r.* FROM public.quality_reviews r WHERE private.business_quality_repairable(r) ORDER BY r.created_at LIMIT 5 FOR UPDATE SKIP LOCKED LOOP
  PERFORM 1 FROM public.tasks WHERE id=q.work_order_id FOR UPDATE;
  IF NOT private.business_quality_repairable(q) THEN CONTINUE;END IF;
  SELECT * INTO prior FROM public.tasks WHERE id=q.job_id;
  SELECT s.workflow_id INTO flow FROM public.business_steps s WHERE s.work_order_id=q.work_order_id;
  -- Preserve the rejected report and completed inspection job; never overwrite the employee delivery or snapshot.
  INSERT INTO public.quality_report_history(review_id,created_by,source_job_id,job_id,report) VALUES(q.id,q.created_by,q.source_job_id,q.job_id,q.report);
  INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(prior.conversation_id,'user','原质检报告未通过逐字引用校验。请独立复检同一固定版本，使用原文候选片段，仍逐项判断全部标准，不改写员工成果，不做CEO验收。') RETURNING id INTO message;
  INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id,input)
   VALUES(prior.title,'chat_reply','queued',prior.conversation_id,message,gen_random_uuid(),q.created_by,q.manager_agent_id,prior.input) RETURNING id INTO job;
  UPDATE public.quality_reviews SET job_id=job,report=NULL,completed_at=NULL WHERE id=q.id;
  UPDATE public.business_workflows SET state='active',last_error=NULL,updated_at=now() WHERE id=flow AND state='blocked';
  INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id,details) VALUES('worker','quality.evidence_repair_queued','task',q.work_order_id::text,jsonb_build_object('review_id',q.id,'source_job_id',q.source_job_id,'previous_job_id',q.job_id,'new_job_id',job,'maximum_report_repairs',1));
  n:=n+1;
 END LOOP;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.repair_business_quality_reports() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.repair_business_quality_reports() TO service_role;
REVOKE ALL ON FUNCTION private.business_quality_repairable(public.quality_reviews) FROM PUBLIC,anon,authenticated,service_role;
DO $patch$
DECLARE d text;
BEGIN
 d:=pg_get_functiondef('private.business_dispatch_ready()'::regprocedure);
 IF position('SELECT EXISTS(' IN d)=0 THEN RAISE EXCEPTION 'Dispatcher changed';END IF;
 d:=replace(d,'SELECT EXISTS(','SELECT EXISTS(SELECT 1 FROM public.quality_reviews r WHERE private.business_quality_repairable(r)) OR EXISTS(');
 EXECUTE d;
END $patch$;
NOTIFY pgrst,'reload schema';
COMMIT;
