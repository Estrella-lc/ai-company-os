-- Delegate new executive text orders using the existing durable queue; COS direct work stays direct.
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.ai_employees DROP CONSTRAINT ai_employees_role_check;
ALTER TABLE public.ai_employees ADD CONSTRAINT ai_employees_role_check CHECK(role IN ('skill_researcher','text_executor'));
CREATE FUNCTION private.bind_text_execution_employee(p_order uuid,p_job uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE w public.tasks; a public.agents; employee uuid; employee_name text;
BEGIN
 SELECT * INTO w FROM public.tasks WHERE id=p_order AND task_kind='work_order' FOR UPDATE;
 SELECT * INTO a FROM public.agents WHERE id=w.assigned_agent_id AND is_active;
 IF w.id IS NULL OR a.id IS NULL OR (w.result->>'current_job_id')::uuid IS DISTINCT FROM p_job OR NOT EXISTS(
   SELECT 1 FROM public.tasks WHERE id=p_job AND created_by=w.created_by AND assigned_agent_id=a.id AND conversation_id=w.conversation_id AND task_kind='chat_reply' AND execution_state='queued'
 ) THEN RAISE EXCEPTION 'Invalid employee task binding' USING ERRCODE='22023';END IF;
 IF a.code='COS' THEN RETURN;END IF;
 INSERT INTO public.ai_employees(created_by,manager_agent_id,name,role)
 VALUES(w.created_by,a.id,a.code || ' 文本执行员','text_executor')
 ON CONFLICT(created_by,manager_agent_id,role) DO UPDATE SET name=excluded.name RETURNING id,name INTO employee,employee_name;
 UPDATE public.tasks SET input=input || jsonb_build_object('employee_id',employee,'employee_name',employee_name,'capability','text_delivery_v1'),updated_at=now() WHERE id=w.id;
 UPDATE public.tasks SET input=input || jsonb_build_object('employee_id',employee,'work_order_id',w.id,'capability','text_delivery_v1'),updated_at=now() WHERE id=p_job;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details)
 VALUES('agent',a.id::text,'employee.text_delegated','task',w.id::text,jsonb_build_object('employee_id',employee,'job_id',p_job));
END $$;
REVOKE ALL ON FUNCTION private.bind_text_execution_employee(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
DO $$ DECLARE definition text; marker text;BEGIN
 definition:=pg_get_functiondef('public.create_work_order(text,text,text,uuid,uuid)'::regprocedure);
 marker:='RETURNING id INTO w;';
 IF position(marker IN definition)=0 OR position('bind_text_execution_employee' IN definition)>0 THEN RAISE EXCEPTION 'Work-order function changed';END IF;
 EXECUTE replace(definition,marker,marker || E'\n PERFORM private.bind_text_execution_employee(w,j);');
 definition:=pg_get_functiondef('public.review_work_order(uuid,uuid,text,text)'::regprocedure);
 marker:='WHERE id=w.id;';
 IF position('next_job:=public.enqueue_chat_reply' IN definition)=0 OR position(marker IN definition)=0 THEN RAISE EXCEPTION 'Review function changed';END IF;
 -- Invoke only once the revised work order points at its new queued execution.
 EXECUTE replace(definition,marker,marker || E'\n IF p_action=''revise'' THEN PERFORM private.bind_text_execution_employee(w.id,next_job);END IF;');
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
