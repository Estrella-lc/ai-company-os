BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.task_skill_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),work_order_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),source_job_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),research_job_id uuid NOT NULL REFERENCES public.tasks(id),query text NOT NULL,state text NOT NULL DEFAULT 'waiting' CHECK(state IN ('waiting','verified','failed')),summary text,created_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz);
ALTER TABLE public.task_skill_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.task_skill_requests FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.task_skill_requests TO authenticated,service_role;
CREATE POLICY skill_request_ceo_read ON public.task_skill_requests FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE FUNCTION private.enable_employee_skill_search() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.input->>'capability'='text_delivery_v1' AND NOT NEW.input?'skill_search_enabled' THEN NEW.input:=NEW.input||jsonb_build_object('skill_search_enabled',NOT EXISTS(SELECT 1 FROM public.task_skill_requests r WHERE r.work_order_id::text=NEW.input->>'work_order_id'));END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER enable_employee_skill_search BEFORE UPDATE OF input ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.enable_employee_skill_search();
CREATE FUNCTION public.pause_for_skill_search(p_task uuid,p_token uuid,p_query text,p_usage jsonb DEFAULT '[]') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.tasks; w public.tasks; existing public.task_skill_requests; research uuid; reuse_manager uuid;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='chat_reply' FOR UPDATE;
 SELECT * INTO existing FROM public.task_skill_requests WHERE source_job_id=p_task;
 IF existing.id IS NOT NULL THEN RETURN existing.research_job_id;END IF;
 IF j.id IS NULL OR j.execution_state<>'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() OR NOT public.is_company_ceo(j.created_by) THEN RAISE EXCEPTION 'Live company lease required' USING ERRCODE='42501';END IF;
 SELECT * INTO w FROM public.tasks WHERE id::text=j.input->>'work_order_id' AND task_kind='work_order' AND created_by=j.created_by FOR UPDATE;
 IF w.id IS NULL OR w.result->>'current_job_id' IS DISTINCT FROM j.id::text OR w.result->>'review_state'='accepted' OR w.assigned_agent_id<>j.assigned_agent_id OR w.conversation_id<>j.conversation_id OR w.input->>'employee_id' IS DISTINCT FROM j.input->>'employee_id' OR j.input->>'capability' IS DISTINCT FROM 'text_delivery_v1' OR j.input->>'skill_search_enabled' IS DISTINCT FROM 'true' OR j.attempt_count>=10 OR NOT EXISTS(SELECT 1 FROM public.ai_employees WHERE id::text=j.input->>'employee_id' AND created_by=j.created_by AND manager_agent_id=j.assigned_agent_id AND role='text_executor') THEN RAISE EXCEPTION 'Employee binding denied' USING ERRCODE='42501';END IF;
 IF p_query IS NULL OR p_query !~ '^[A-Za-z0-9 _-]{2,64}$' OR EXISTS(SELECT 1 FROM public.task_skill_requests WHERE work_order_id=w.id) THEN RAISE EXCEPTION 'Generic keywords and one search per order required' USING ERRCODE='22023';END IF;
 IF p_query ~* 'srt|subtitle burn|caption burn' AND p_query !~* 'transcrib|recogn|speech' THEN SELECT manager_agent_id INTO reuse_manager FROM public.agent_skills WHERE created_by=j.created_by AND status='verified_limited' AND capability='subtitles' AND verification->>'scope'='subtitle_fixture_v1' AND verification->>'passed'='true' ORDER BY created_at DESC LIMIT 1;END IF;
 research:=private.enqueue_skill_research(j.created_by,coalesce(reuse_manager,j.assigned_agent_id),'员工能力缺口：'||p_query,p_query,NULL,j.id);
 IF NOT public.fail_chat_reply(j.id,p_token,'awaiting_skill_research',true,p_usage) THEN RAISE EXCEPTION 'Lease lost' USING ERRCODE='40001';END IF;
 UPDATE public.tasks SET execution_state='queued',available_at='infinity',finished_at=NULL,max_attempts=greatest(max_attempts,attempt_count+1),input=input||'{"skill_search_enabled":false}'::jsonb WHERE id=j.id;
 INSERT INTO public.task_skill_requests(created_by,work_order_id,source_job_id,research_job_id,query) VALUES(j.created_by,w.id,j.id,research,p_query);
 UPDATE public.tasks SET result=result||jsonb_build_object('skill_search',jsonb_build_object('state','waiting','research_id',research,'summary','正在检索与验证技能，未作为交付成果。')) WHERE id=w.id;
 UPDATE public.tasks SET execution_state=execution_state WHERE id=research AND execution_state IN ('succeeded','failed');
 RETURN research;
END $$;
CREATE FUNCTION private.finish_employee_skill_search() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.task_skill_requests; skills jsonb;
BEGIN
 IF NEW.task_kind<>'skill_research' OR NEW.execution_state NOT IN ('succeeded','failed') THEN RETURN NEW;END IF;
 FOR r IN SELECT * FROM public.task_skill_requests WHERE research_job_id=NEW.id AND created_by=NEW.created_by AND state='waiting' FOR UPDATE LOOP
  SELECT jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'repository',s.repository,'commit_sha',s.commit_sha,'scope',s.verification->>'scope','document',left(s.document,3000))) INTO skills FROM (SELECT a.* FROM public.agent_skills a WHERE a.created_by=r.created_by AND (a.request_task_id=NEW.id OR a.id::text IN (SELECT jsonb_array_elements_text(coalesce(NEW.result->'skill_ids','[]')))) AND a.status='verified_limited' AND a.capability='subtitles' AND a.verification->>'scope'='subtitle_fixture_v1' AND a.verification->>'passed'='true' ORDER BY a.created_at DESC LIMIT 2) s;
  UPDATE public.task_skill_requests SET state=CASE WHEN skills IS NULL THEN 'failed' ELSE 'verified' END,summary=CASE WHEN skills IS NULL THEN '未找到通过适用验证的技能；需要CEO处理能力缺口。' ELSE '已验证的有限能力已登记公司技能中心；不代表原任务已执行或验收。' END,finished_at=now() WHERE id=r.id;
  UPDATE public.tasks SET result=result||jsonb_build_object('skill_search',jsonb_build_object('state',CASE WHEN skills IS NULL THEN 'failed' ELSE 'verified' END,'research_id',NEW.id,'summary',CASE WHEN skills IS NULL THEN '未找到通过适用验证的技能；请CEO查看技能研究报告。' ELSE '适用验证通过，已登记共享技能，恢复执行。' END)) WHERE id=r.work_order_id AND result->>'current_job_id'=r.source_job_id::text;
  UPDATE public.tasks SET execution_state=CASE WHEN skills IS NULL THEN 'failed' ELSE 'queued' END,available_at=now(),finished_at=CASE WHEN skills IS NULL THEN now() ELSE NULL END,last_error_code=CASE WHEN skills IS NULL THEN 'skill_search_unverified' ELSE NULL END,input=input||jsonb_build_object('validated_skill_context',coalesce(skills,'[]')) WHERE id=r.source_job_id AND execution_state='queued' AND available_at='infinity' AND EXISTS(SELECT 1 FROM public.tasks w WHERE w.id=r.work_order_id AND w.result->>'current_job_id'=r.source_job_id::text AND w.result->>'review_state' IS DISTINCT FROM 'accepted');
 END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER finish_employee_skill_search AFTER UPDATE OF execution_state ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.finish_employee_skill_search();
DO $evidence$
DECLARE definition text; marker text:='''execution_request_message_id'',source.request_message_id';
BEGIN
 definition:=pg_get_functiondef('private.queue_text_quality(uuid)'::regprocedure);
 IF position(marker IN definition)=0 OR position('validated_company_skills' IN definition)>0 THEN RAISE EXCEPTION 'Quality evidence function changed';END IF;
 EXECUTE replace(definition,marker,marker||',''validated_company_skills'',(SELECT coalesce(jsonb_agg(x-''document''),''[]''::jsonb) FROM jsonb_array_elements(coalesce(source.input->''validated_skill_context'',''[]''::jsonb)) x)');
END $evidence$;
REVOKE ALL ON FUNCTION private.enable_employee_skill_search(),private.finish_employee_skill_search(),public.pause_for_skill_search(uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.pause_for_skill_search(uuid,uuid,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
