-- Accepted text deliveries form immutable, company-scoped knowledge versions.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.company_knowledge(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 200),body text NOT NULL CHECK(length(body) BETWEEN 1 AND 60000),
 source_task_id uuid NOT NULL REFERENCES public.tasks(id),source_job_id uuid NOT NULL REFERENCES public.tasks(id),
 manager_agent_id uuid NOT NULL REFERENCES public.agents(id),employee_id uuid REFERENCES public.ai_employees(id),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(created_by,source_task_id,source_job_id));
CREATE INDEX company_knowledge_owner_recent ON public.company_knowledge(created_by,created_at DESC);
ALTER TABLE public.company_knowledge ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_knowledge FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.company_knowledge TO authenticated,service_role;
CREATE POLICY company_knowledge_ceo_read ON public.company_knowledge FOR SELECT TO authenticated
 USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE FUNCTION private.archive_accepted_text_knowledge() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE content text;employee uuid;
BEGIN
 IF NEW.task_kind<>'work_order' OR NEW.result->>'review_state' IS DISTINCT FROM 'accepted' THEN RETURN NEW;END IF;
 SELECT m.content INTO content FROM public.tasks j JOIN public.messages m ON m.reply_task_id=j.id
 WHERE j.id=(NEW.result->>'current_job_id')::uuid AND j.task_kind='chat_reply' AND j.created_by=NEW.created_by
 AND j.assigned_agent_id=NEW.assigned_agent_id AND j.conversation_id=NEW.conversation_id AND j.execution_state='succeeded';
 IF nullif(trim(content),'') IS NULL THEN RAISE EXCEPTION 'Accepted delivery missing' USING ERRCODE='22023';END IF;
 SELECT id INTO employee FROM public.ai_employees WHERE id=(NEW.input->>'employee_id')::uuid AND created_by=NEW.created_by AND manager_agent_id=NEW.assigned_agent_id;
 INSERT INTO public.company_knowledge(created_by,title,body,source_task_id,source_job_id,manager_agent_id,employee_id)
 VALUES(NEW.created_by,left(NEW.title,200),left(content,60000),NEW.id,(NEW.result->>'current_job_id')::uuid,NEW.assigned_agent_id,employee)
 ON CONFLICT(created_by,source_task_id,source_job_id) DO NOTHING;
 RETURN NEW;
END $$;
CREATE TRIGGER archive_accepted_text_knowledge AFTER UPDATE OF result ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.archive_accepted_text_knowledge();
INSERT INTO public.company_knowledge(created_by,title,body,source_task_id,source_job_id,manager_agent_id,employee_id)
 SELECT w.created_by,left(w.title,200),left(m.content,60000),w.id,j.id,w.assigned_agent_id,e.id
 FROM public.tasks w JOIN public.tasks j ON j.id=(w.result->>'current_job_id')::uuid
 JOIN public.messages m ON m.reply_task_id=j.id
 LEFT JOIN public.ai_employees e ON e.id=(w.input->>'employee_id')::uuid AND e.created_by=w.created_by AND e.manager_agent_id=w.assigned_agent_id
 WHERE w.task_kind='work_order' AND w.result->>'review_state'='accepted' AND j.execution_state='succeeded'
 AND j.created_by=w.created_by AND j.conversation_id=w.conversation_id AND j.assigned_agent_id=w.assigned_agent_id AND nullif(trim(m.content),'') IS NOT NULL;

-- Bounded keyword retrieval, not semantic search: rank the latest 200 accepted records.
CREATE FUNCTION private.find_company_knowledge(p_owner uuid,p_query text,p_exclude uuid,p_limit int) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 WITH chunks AS (SELECT (regexp_matches(lower(left(coalesce(p_query,''),300)),'[a-z0-9_]{3,}|[一-龥]{2,}','g'))[1] AS token),
 terms AS (SELECT DISTINCT token FROM (
   SELECT token FROM chunks WHERE token ~ '^[a-z0-9_]'
   UNION ALL SELECT substr(token,n,2) FROM chunks CROSS JOIN LATERAL generate_series(1,length(token)-1) n WHERE token ~ '^[一-龥]'
 ) t ORDER BY token LIMIT 100),
 recent AS (SELECT * FROM public.company_knowledge WHERE created_by=p_owner AND source_task_id IS DISTINCT FROM p_exclude ORDER BY created_at DESC,id LIMIT 200),
 scored AS (SELECT k.*, (SELECT coalesce(sum(CASE WHEN length(t.token)>2 THEN 3 ELSE 1 END),0) FROM terms t WHERE position(t.token in lower(k.title || ' ' || left(k.body,8000)))>0) AS score FROM recent k),
 chosen AS (SELECT * FROM scored WHERE score>=2 ORDER BY score DESC,created_at DESC,id LIMIT greatest(0,least(p_limit,20)))
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'title',left(title,120),'excerpt',left(body,800),'source_task_id',source_task_id,'source_job_id',source_job_id,'manager_agent_id',manager_agent_id,'employee_id',employee_id) ORDER BY score DESC,created_at DESC,id),'[]') FROM chosen;
$$;
CREATE FUNCTION public.search_company_knowledge(p_query text,p_limit int DEFAULT 20) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR public.is_company_ceo(auth.uid()) IS DISTINCT FROM true THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 IF coalesce(length(trim(p_query)),0) NOT BETWEEN 2 AND 300 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Invalid query' USING ERRCODE='22023';END IF;
 RETURN private.find_company_knowledge(auth.uid(),p_query,NULL,p_limit);
END $$;
CREATE FUNCTION public.knowledge_for_employee_task(p_task uuid,p_token uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.tasks;w public.tasks;refs jsonb;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='chat_reply' FOR UPDATE;
 IF j.id IS NULL OR j.execution_state<>'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RAISE EXCEPTION 'Lease denied' USING ERRCODE='42501';END IF;
 SELECT * INTO w FROM public.tasks WHERE id=(j.input->>'work_order_id')::uuid AND task_kind='work_order' AND created_by=j.created_by AND assigned_agent_id=j.assigned_agent_id AND conversation_id=j.conversation_id;
 IF w.id IS NULL OR w.result->>'current_job_id' IS DISTINCT FROM j.id::text OR j.input->>'capability' IS DISTINCT FROM 'text_delivery_v1'
 OR w.input->>'employee_id' IS DISTINCT FROM j.input->>'employee_id' OR NOT EXISTS(
   SELECT 1 FROM public.ai_employees WHERE id=(j.input->>'employee_id')::uuid AND created_by=j.created_by AND manager_agent_id=j.assigned_agent_id AND role='text_executor'
 ) THEN RAISE EXCEPTION 'Employee binding denied' USING ERRCODE='42501';END IF;
 IF j.input ? 'knowledge_context' THEN RETURN j.input->'knowledge_context';END IF;
 refs:=private.find_company_knowledge(j.created_by,w.title || ' ' || w.description,w.id,3);
 UPDATE public.tasks SET input=input || jsonb_build_object('knowledge_context',refs,'knowledge_retrieval','accepted_keywords_v1'),updated_at=now() WHERE id=j.id;
 RETURN refs;
END $$;
REVOKE ALL ON FUNCTION private.archive_accepted_text_knowledge(),private.find_company_knowledge(uuid,text,uuid,int),public.search_company_knowledge(text,int),public.knowledge_for_employee_task(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.search_company_knowledge(text,int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.knowledge_for_employee_task(uuid,uuid) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
