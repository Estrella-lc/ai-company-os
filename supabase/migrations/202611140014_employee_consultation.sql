BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.employee_consultations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),
 work_order_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),source_job_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),
 employee_id uuid NOT NULL REFERENCES public.ai_employees(id),manager_agent_id uuid NOT NULL REFERENCES public.agents(id),
 manager_job_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),question text NOT NULL CHECK(length(trim(question)) BETWEEN 1 AND 1000),
 state text NOT NULL DEFAULT 'waiting' CHECK(state IN ('waiting','resumed','needs_ceo','closed')),
 snapshot jsonb NOT NULL,answer text CHECK(length(answer)<=2000),created_at timestamptz NOT NULL DEFAULT now(),answered_at timestamptz
);
ALTER TABLE public.employee_consultations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.employee_consultations FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.employee_consultations TO authenticated,service_role;
CREATE POLICY consultation_ceo_read ON public.employee_consultations FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE FUNCTION private.enable_new_order_consultation() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN IF NEW.task_kind='work_order' THEN NEW.input:=NEW.input||'{"consultation_enabled":true}'::jsonb;END IF;RETURN NEW;END $$;
CREATE TRIGGER enable_new_order_consultation BEFORE INSERT ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.enable_new_order_consultation();

CREATE FUNCTION public.consultation_context_for_task(p_task uuid,p_token uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.tasks; w public.tasks; c public.employee_consultations;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='chat_reply' AND execution_state='running' AND lease_token=p_token AND lease_expires_at>now();
 IF j.id IS NULL OR NOT public.is_company_ceo(j.created_by) THEN RAISE EXCEPTION 'Live company lease required' USING ERRCODE='42501';END IF;
 SELECT * INTO w FROM public.tasks WHERE id::text=j.input->>'work_order_id' AND created_by=j.created_by AND assigned_agent_id=j.assigned_agent_id AND conversation_id=j.conversation_id AND task_kind='work_order' AND result->>'current_job_id'=j.id::text;
 IF w.id IS NULL OR j.input->>'capability' IS DISTINCT FROM 'text_delivery_v1' OR w.input->>'employee_id' IS DISTINCT FROM j.input->>'employee_id' THEN RAISE EXCEPTION 'Invalid employee binding' USING ERRCODE='42501';END IF;
 SELECT * INTO c FROM public.employee_consultations WHERE work_order_id=w.id;
 RETURN jsonb_build_object('allowed',coalesce(w.input->>'consultation_enabled'='true',false) AND c.id IS NULL AND j.attempt_count<10,'question',CASE WHEN c.state='resumed' AND c.source_job_id=j.id THEN c.question END,'answer',CASE WHEN c.state='resumed' AND c.source_job_id=j.id THEN c.answer END);
END $$;

CREATE FUNCTION public.request_employee_consultation(p_task uuid,p_token uuid,p_question text,p_usage jsonb DEFAULT '[]') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.tasks; w public.tasks; e public.ai_employees; existing public.employee_consultations; cid uuid:=gen_random_uuid(); conversation uuid; message uuid; manager_job uuid; project jsonb;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='chat_reply' FOR UPDATE;
 SELECT * INTO existing FROM public.employee_consultations WHERE source_job_id=p_task;
 IF existing.id IS NOT NULL AND existing.question=trim(p_question) THEN RETURN existing.id;END IF;
 IF j.id IS NULL OR NOT public.is_company_ceo(j.created_by) OR j.execution_state IS DISTINCT FROM 'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RAISE EXCEPTION 'Live company lease required' USING ERRCODE='42501';END IF;
 SELECT * INTO w FROM public.tasks WHERE id::text=j.input->>'work_order_id' AND task_kind='work_order' AND created_by=j.created_by FOR UPDATE;
 SELECT * INTO e FROM public.ai_employees WHERE id::text=j.input->>'employee_id' AND created_by=j.created_by AND manager_agent_id=j.assigned_agent_id AND role='text_executor';
 IF w.id IS NULL OR e.id IS NULL OR w.assigned_agent_id<>j.assigned_agent_id OR w.conversation_id<>j.conversation_id OR w.result->>'current_job_id' IS DISTINCT FROM j.id::text OR w.result->>'review_state'='accepted' OR w.input->>'employee_id' IS DISTINCT FROM e.id::text OR j.input->>'capability' IS DISTINCT FROM 'text_delivery_v1' OR w.input->>'consultation_enabled' IS DISTINCT FROM 'true' OR j.attempt_count>=10 OR NOT EXISTS(SELECT 1 FROM public.agents WHERE id=j.assigned_agent_id AND is_active) THEN RAISE EXCEPTION 'Consultation denied' USING ERRCODE='42501';END IF;
 IF EXISTS(SELECT 1 FROM public.employee_consultations WHERE work_order_id=w.id) OR coalesce(length(trim(p_question)),0) NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'One consultation per order; valid question required' USING ERRCODE='22023';END IF;
 SELECT jsonb_build_object('title',p.title,'goal',p.goal,'business_acceptance',p.acceptance,'integration_acceptance',p.integration_acceptance,'stages',p.stages) INTO project FROM public.company_projects p WHERE p.created_by=w.created_by AND p.plan_id::text=w.input->>'parent_plan_id';
 INSERT INTO public.conversations(agent_id,conversation_type,title,created_by) VALUES(j.assigned_agent_id,'direct','员工阻塞咨询 · '||left(w.title,70),j.created_by) RETURNING id INTO conversation;
 INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(conversation,'user',trim(p_question)) RETURNING id INTO message;
 INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id,input)
 VALUES('答复员工 · '||left(w.title,70),'chat_reply','queued',conversation,message,gen_random_uuid(),j.created_by,j.assigned_agent_id,jsonb_build_object('consultation_id',cid,'capability','employee_consultation_v1')) RETURNING id INTO manager_job;
 INSERT INTO public.employee_consultations(id,created_by,work_order_id,source_job_id,employee_id,manager_agent_id,manager_job_id,question,snapshot)
 VALUES(cid,j.created_by,w.id,j.id,e.id,j.assigned_agent_id,manager_job,trim(p_question),jsonb_build_object('title',w.title,'goal',w.description,'acceptance',w.input->>'acceptance','project_scope',project,'historical_knowledge',coalesce(j.input->'knowledge_context','[]')));
 IF NOT public.fail_chat_reply(j.id,p_token,'awaiting_manager',true,p_usage) THEN RAISE EXCEPTION 'Lease lost' USING ERRCODE='40001';END IF;
 UPDATE public.tasks SET execution_state='queued',available_at='infinity',finished_at=NULL,max_attempts=greatest(max_attempts,attempt_count+1),updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('agent',j.assigned_agent_id::text,'consultation.requested','task',w.id::text,jsonb_build_object('consultation_id',cid,'source_job_id',j.id,'employee_id',e.id));
 RETURN cid;
END $$;

CREATE FUNCTION private.finish_employee_consultation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.employee_consultations; w public.tasks; body jsonb;
BEGIN
 IF NEW.task_kind<>'chat_reply' OR NEW.execution_state IS DISTINCT FROM 'succeeded' OR OLD.execution_state='succeeded' OR NEW.input->>'consultation_id' IS NULL THEN RETURN NEW;END IF;
 SELECT * INTO c FROM public.employee_consultations WHERE id::text=NEW.input->>'consultation_id' AND manager_job_id=NEW.id AND created_by=NEW.created_by AND manager_agent_id=NEW.assigned_agent_id FOR UPDATE;
 IF c.id IS NULL OR c.state<>'waiting' THEN RAISE EXCEPTION 'Consultation binding invalid' USING ERRCODE='22023';END IF;
 SELECT content::jsonb INTO body FROM public.messages WHERE reply_task_id=NEW.id;
 IF coalesce(body->>'decision','') NOT IN ('resume','needs_ceo') OR jsonb_typeof(body->'answer') IS DISTINCT FROM 'string' OR coalesce(length(trim(body->>'answer')),0) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Invalid manager answer' USING ERRCODE='22023';END IF;
 SELECT * INTO w FROM public.tasks WHERE id=c.work_order_id AND created_by=c.created_by FOR UPDATE;
 UPDATE public.employee_consultations SET answer=body->>'answer',state=CASE WHEN w.result->>'current_job_id' IS DISTINCT FROM c.source_job_id::text OR w.result->>'review_state'='accepted' THEN 'closed' WHEN body->>'decision'='resume' THEN 'resumed' ELSE 'needs_ceo' END,answered_at=now() WHERE id=c.id;
 IF w.result->>'current_job_id'=c.source_job_id::text AND w.result->>'review_state' IS DISTINCT FROM 'accepted' THEN
  UPDATE public.tasks SET execution_state=CASE WHEN body->>'decision'='resume' THEN 'queued' ELSE 'failed' END,available_at=now(),last_error_code=CASE WHEN body->>'decision'='resume' THEN NULL ELSE 'consultation_needs_ceo' END,finished_at=CASE WHEN body->>'decision'='resume' THEN NULL ELSE now() END,updated_at=now() WHERE id=c.source_job_id AND execution_state='queued' AND available_at='infinity';
 END IF;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('agent',NEW.assigned_agent_id::text,'consultation.answered','task',c.work_order_id::text,jsonb_build_object('consultation_id',c.id,'decision',body->>'decision'));
 RETURN NEW;
END $$;
CREATE TRIGGER finish_employee_consultation AFTER UPDATE OF execution_state ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.finish_employee_consultation();

CREATE FUNCTION public.retry_employee_consultation(p_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.employee_consultations; j public.tasks;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO c FROM public.employee_consultations WHERE id=p_id AND created_by=auth.uid() FOR UPDATE;
 IF c.id IS NULL OR c.state<>'waiting' THEN RAISE EXCEPTION 'Waiting consultation required' USING ERRCODE='22023';END IF;
 SELECT * INTO j FROM public.tasks WHERE id=c.manager_job_id FOR UPDATE;
 IF j.execution_state NOT IN ('failed','cancelled') OR j.attempt_count>=10 THEN RAISE EXCEPTION 'Failed consultation below retry limit required' USING ERRCODE='22023';END IF;
 UPDATE public.tasks SET execution_state='queued',max_attempts=greatest(max_attempts,attempt_count+1),available_at=now(),finished_at=NULL,last_error_code=NULL,updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',auth.uid()::text,'consultation.retry','task',c.work_order_id::text,jsonb_build_object('consultation_id',c.id,'attempt_count',j.attempt_count));
END $$;
CREATE FUNCTION public.close_employee_consultation(p_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.employee_consultations; j public.tasks;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO c FROM public.employee_consultations WHERE id=p_id AND created_by=auth.uid() FOR UPDATE;
 IF c.id IS NULL OR c.state<>'waiting' THEN RAISE EXCEPTION 'Waiting consultation required' USING ERRCODE='22023';END IF;
 SELECT * INTO j FROM public.tasks WHERE id=c.manager_job_id FOR UPDATE;
 IF j.execution_state NOT IN ('failed','cancelled') THEN RAISE EXCEPTION 'Only failed consultation can close' USING ERRCODE='22023';END IF;
 UPDATE public.employee_consultations SET state='closed' WHERE id=c.id;
 UPDATE public.tasks SET execution_state='failed',finished_at=now(),available_at=now(),last_error_code='consultation_closed',updated_at=now() WHERE id=c.source_job_id AND execution_state='queued' AND available_at='infinity';
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',auth.uid()::text,'consultation.closed','task',c.work_order_id::text,jsonb_build_object('consultation_id',c.id));
END $$;
REVOKE ALL ON FUNCTION private.enable_new_order_consultation(),private.finish_employee_consultation() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.consultation_context_for_task(uuid,uuid),public.request_employee_consultation(uuid,uuid,text,jsonb),public.retry_employee_consultation(uuid),public.close_employee_consultation(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.consultation_context_for_task(uuid,uuid),public.request_employee_consultation(uuid,uuid,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.retry_employee_consultation(uuid),public.close_employee_consultation(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
