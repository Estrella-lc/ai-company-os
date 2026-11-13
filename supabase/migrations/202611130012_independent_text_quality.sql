BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.ai_employees DROP CONSTRAINT ai_employees_role_check;
ALTER TABLE public.ai_employees ADD CONSTRAINT ai_employees_role_check CHECK(role IN ('skill_researcher','text_executor','quality_inspector'));
CREATE TABLE public.quality_reviews (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),
 work_order_id uuid NOT NULL REFERENCES public.tasks(id),source_job_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),
 employee_id uuid NOT NULL REFERENCES public.ai_employees(id),manager_agent_id uuid NOT NULL REFERENCES public.agents(id),
 job_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),snapshot jsonb NOT NULL,report jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),completed_at timestamptz
);
CREATE INDEX quality_reviews_owner_recent ON public.quality_reviews(created_by,created_at DESC);
ALTER TABLE public.quality_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.quality_reviews FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.quality_reviews TO authenticated,service_role;
CREATE POLICY quality_ceo_read ON public.quality_reviews FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));

CREATE FUNCTION private.queue_text_quality(p_order uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE w public.tasks; source public.tasks; existing uuid; manager uuid; employee uuid; conversation uuid; message uuid; job uuid; review uuid:=gen_random_uuid(); body text; context jsonb;
BEGIN
 SELECT * INTO w FROM public.tasks WHERE id=p_order AND task_kind='work_order' FOR UPDATE;
 SELECT * INTO source FROM public.tasks WHERE id=(w.result->>'current_job_id')::uuid AND created_by=w.created_by AND task_kind='chat_reply' AND execution_state='succeeded' AND assigned_agent_id=w.assigned_agent_id AND conversation_id=w.conversation_id;
 IF w.id IS NULL OR source.id IS NULL THEN RAISE EXCEPTION 'Delivery not ready' USING ERRCODE='22023';END IF;
 SELECT id INTO existing FROM public.quality_reviews WHERE source_job_id=source.id;
 IF existing IS NOT NULL THEN RETURN existing;END IF;
 SELECT content INTO body FROM public.messages WHERE reply_task_id=source.id;
 IF nullif(trim(body),'') IS NULL THEN RAISE EXCEPTION 'Missing delivery' USING ERRCODE='22023';END IF;
 SELECT id INTO manager FROM public.agents WHERE is_active ORDER BY (code='COO') DESC,code LIMIT 1;
 IF manager IS NULL THEN RAISE EXCEPTION 'Quality manager unavailable' USING ERRCODE='22023';END IF;
 INSERT INTO public.ai_employees(created_by,manager_agent_id,name,role) VALUES(w.created_by,manager,'独立文本质检员','quality_inspector')
 ON CONFLICT(created_by,manager_agent_id,role) DO UPDATE SET name=excluded.name RETURNING id INTO employee;
 IF employee::text=w.input->>'employee_id' THEN RAISE EXCEPTION 'Producer cannot inspect own output' USING ERRCODE='22023';END IF;
 SELECT jsonb_build_object('project_id',p.id,'revision',p.revision,'goal',p.goal,'business_acceptance',p.acceptance,'integration_acceptance',p.integration_acceptance,'stages',p.stages)
 INTO context FROM public.company_projects p WHERE p.created_by=w.created_by AND p.plan_id::text=w.input->>'parent_plan_id';
 INSERT INTO public.conversations(agent_id,conversation_type,title,created_by) VALUES(manager,'direct','独立质检 · '||left(w.title,80),w.created_by) RETURNING id INTO conversation;
 INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(conversation,'user','请根据固定版本任务标准，检查本次文本成果。仅生成质检报告，不修改成果，不做CEO验收。') RETURNING id INTO message;
 INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id,input)
 VALUES('独立质检 · '||left(w.title,80),'chat_reply','queued',conversation,message,gen_random_uuid(),w.created_by,manager,jsonb_build_object('quality_review_id',review,'capability','text_quality_v1')) RETURNING id INTO job;
 INSERT INTO public.quality_reviews(id,created_by,work_order_id,source_job_id,employee_id,manager_agent_id,job_id,snapshot)
 VALUES(review,w.created_by,w.id,source.id,employee,manager,job,jsonb_build_object('title',w.title,'goal',w.description,'acceptance',w.input->>'acceptance','body',body,'project',context));
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id,details) VALUES('worker','quality.queued','task',w.id::text,jsonb_build_object('review_id',review,'source_job_id',source.id,'employee_id',employee));
 RETURN review;
END $$;
CREATE FUNCTION public.request_text_quality(p_order uuid,p_job uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); w public.tasks; review uuid; inspection public.tasks;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO w FROM public.tasks WHERE id=p_order AND created_by=uid AND task_kind='work_order' FOR UPDATE;
 IF w.id IS NULL THEN RAISE EXCEPTION 'Order denied' USING ERRCODE='42501';END IF;
 IF w.result->>'current_job_id' IS DISTINCT FROM p_job::text THEN RAISE EXCEPTION 'Stale delivery' USING ERRCODE='40001';END IF;
 review:=private.queue_text_quality(w.id);
 SELECT t.* INTO inspection FROM public.tasks t JOIN public.quality_reviews q ON q.job_id=t.id WHERE q.id=review AND q.report IS NULL AND t.execution_state IN ('failed','cancelled') FOR UPDATE OF t;
 IF inspection.execution_state IN ('failed','cancelled') THEN
  IF inspection.attempt_count>=10 THEN RAISE EXCEPTION 'Inspection retry limit reached' USING ERRCODE='22023';END IF;
  UPDATE public.tasks SET execution_state='queued',max_attempts=greatest(max_attempts,attempt_count+1),finished_at=NULL,available_at=now(),last_error_code=NULL,updated_at=now() WHERE id=inspection.id;
  INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'quality.retry_requested','task',inspection.id::text);
 END IF;
 RETURN review;
END $$;
CREATE FUNCTION private.require_quality_for_new_order() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.task_kind='work_order' THEN NEW.input:=NEW.input || jsonb_build_object('quality_required',true,'quality_rework_count',0);END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER require_quality_for_new_order BEFORE INSERT ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.require_quality_for_new_order();

CREATE FUNCTION private.validate_text_quality(p_report jsonb,p_body text) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE c jsonb; key text;
BEGIN
 IF jsonb_typeof(p_report) IS DISTINCT FROM 'object' OR coalesce(p_report->>'verdict','') NOT IN ('pass','revise','needs_human') OR coalesce(length(trim(p_report->>'summary')),0) NOT BETWEEN 1 AND 1500 OR jsonb_typeof(p_report->'checks') IS DISTINCT FROM 'array' OR jsonb_array_length(p_report->'checks')<>3 THEN RAISE EXCEPTION 'Invalid quality report' USING ERRCODE='22023';END IF;
 FOREACH key IN ARRAY ARRAY['task_goal','task_acceptance','truthfulness'] LOOP
  IF (SELECT count(*) FROM jsonb_array_elements(p_report->'checks') x WHERE x->>'id'=key)<>1 THEN RAISE EXCEPTION 'Missing quality criterion' USING ERRCODE='22023';END IF;
 END LOOP;
 FOR c IN SELECT value FROM jsonb_array_elements(p_report->'checks') LOOP
  IF coalesce(c->>'status','') NOT IN ('pass','fail','not_checked') OR coalesce(length(trim(c->>'reason')),0) NOT BETWEEN 1 AND 1000 OR jsonb_typeof(c->'evidence') IS DISTINCT FROM 'string' OR length(c->>'evidence')>1000 OR (c->>'status'='pass' AND (length(trim(c->>'evidence'))=0 OR position(c->>'evidence' IN p_body)=0)) THEN RAISE EXCEPTION 'Invalid quality evidence' USING ERRCODE='22023';END IF;
 END LOOP;
 IF (p_report->>'verdict'='pass' AND (length(p_body)>16000 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_report->'checks') x WHERE x->>'status'<>'pass'))) OR (p_report->>'verdict'='revise' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_report->'checks') x WHERE x->>'status'='fail')) THEN RAISE EXCEPTION 'Invalid quality verdict' USING ERRCODE='22023';END IF;
END $$;

CREATE FUNCTION private.route_text_quality_completion() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q public.quality_reviews; w public.tasks; quality_report jsonb; content text; request uuid; next_job uuid; feedback text;
BEGIN
 IF NEW.task_kind<>'chat_reply' OR NEW.execution_state IS DISTINCT FROM 'succeeded' OR OLD.execution_state='succeeded' THEN RETURN NEW;END IF;
 IF NEW.input->>'quality_review_id' IS NOT NULL THEN
  SELECT * INTO q FROM public.quality_reviews WHERE id::text=NEW.input->>'quality_review_id' AND job_id=NEW.id AND created_by=NEW.created_by FOR UPDATE;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Quality binding invalid' USING ERRCODE='22023';END IF;
  SELECT m.content INTO content FROM public.messages m WHERE m.reply_task_id=NEW.id;
  quality_report:=content::jsonb;PERFORM private.validate_text_quality(quality_report,q.snapshot->>'body');
  UPDATE public.quality_reviews SET report=quality_report,completed_at=now() WHERE id=q.id;
  SELECT * INTO w FROM public.tasks WHERE id=q.work_order_id AND created_by=q.created_by FOR UPDATE;
  -- One automatic internal repair per order. Old/accepted versions never trigger repairs.
  IF quality_report->>'verdict'='revise' AND w.input->>'quality_required'='true' AND w.result->>'review_state' IS DISTINCT FROM 'accepted' AND w.result->>'current_job_id'=q.source_job_id::text AND coalesce((w.input->>'quality_rework_count')::int,0)<1 THEN
   feedback:='独立质检退回：'||left(quality_report->>'summary',1000)||E'\n逐项问题：\n'||left((quality_report->'checks')::text,3000);
   INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(w.conversation_id,'user','任务内部返工：'||w.title||E'\n原目标：\n'||w.description||E'\n验收标准：\n'||(w.input->>'acceptance')||E'\n'||feedback||E'\n重新提交完整成果，不输出质检报告，不宣称已验收。') RETURNING id INTO request;
   INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id)
   VALUES('质检返工 · '||left(w.title,80),'chat_reply','queued',w.conversation_id,request,gen_random_uuid(),w.created_by,w.assigned_agent_id) RETURNING id INTO next_job;
   UPDATE public.tasks SET input=jsonb_set(w.input,'{runs}',(w.input->'runs')||jsonb_build_array(jsonb_build_object('job_id',next_job,'feedback',feedback)))||jsonb_build_object('quality_rework_count',1),result=jsonb_build_object('review_state','open','current_job_id',next_job),updated_at=now() WHERE id=w.id;
   PERFORM private.bind_text_execution_employee(w.id,next_job);
   INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id,details) VALUES('worker','quality.auto_rework','task',w.id::text,jsonb_build_object('review_id',q.id,'job_id',next_job));
  END IF;
 ELSE
  SELECT * INTO w FROM public.tasks WHERE task_kind='work_order' AND created_by=NEW.created_by AND result->>'current_job_id'=NEW.id::text AND input->>'quality_required'='true';
  IF w.id IS NOT NULL THEN PERFORM private.queue_text_quality(w.id);END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER route_text_quality_completion AFTER UPDATE OF execution_state ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.route_text_quality_completion();
DO $$ DECLARE definition text; marker text:='IF p_action=''accept'' THEN';BEGIN
 definition:=replace(pg_get_functiondef('public.review_work_order(uuid,uuid,text,text)'::regprocedure),E'\r\n',E'\n');
 IF position(marker IN definition)=0 OR position('quality_required' IN definition)>0 THEN RAISE EXCEPTION 'Review function changed';END IF;
 -- Only the actual acceptance branch (not the idempotent accepted-order return).
 marker:=E'IF p_action=''accept'' THEN\n  IF j.execution_state';
 IF position(marker IN definition)=0 THEN RAISE EXCEPTION 'Acceptance branch changed';END IF;
 EXECUTE replace(definition,marker,E'IF p_action=''accept'' THEN\n  IF w.input->>''quality_required''=''true'' AND NOT EXISTS(SELECT 1 FROM public.quality_reviews q WHERE q.work_order_id=w.id AND q.source_job_id=p_job AND (q.report->>''verdict''=''pass'' OR (q.report->>''verdict''=''needs_human'' AND length(trim(coalesce(p_note,'''')))>=20 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(q.report->''checks'') x WHERE x->>''status''=''fail'')))) THEN RAISE EXCEPTION ''Independent quality review not passed; manual verification evidence required for uncertain results'' USING ERRCODE=''22023'';END IF;\n  IF j.execution_state');
END $$;
REVOKE ALL ON FUNCTION private.queue_text_quality(uuid),private.require_quality_for_new_order(),private.validate_text_quality(jsonb,text),private.route_text_quality_completion() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.request_text_quality(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.request_text_quality(uuid,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
