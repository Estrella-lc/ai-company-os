-- Business task review reuses the durable chat queue and existing CEO RLS.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.create_work_order(p_title text,p_brief text,p_acceptance text,p_agent uuid,p_key uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); a public.agents; c uuid; m uuid; j uuid; w uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501'; END IF;
 IF p_key IS NULL OR coalesce(length(trim(p_title)),0) NOT BETWEEN 1 AND 120 OR coalesce(length(trim(p_brief)),0) NOT BETWEEN 1 AND 5000 OR coalesce(length(trim(p_acceptance)),0) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Invalid task fields' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text || p_key::text,0));
 SELECT id INTO w FROM public.tasks WHERE created_by=uid AND request_key=p_key AND task_kind='work_order';
 IF w IS NOT NULL THEN RETURN w; END IF;
 SELECT * INTO a FROM public.agents WHERE id=p_agent AND is_active;
 IF a.id IS NULL THEN RAISE EXCEPTION 'Active executive required' USING ERRCODE='22023'; END IF;
 SELECT id INTO c FROM public.conversations WHERE created_by=uid AND agent_id=a.id AND conversation_type='direct' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
 IF c IS NULL THEN INSERT INTO public.conversations(agent_id,conversation_type,title,created_by) VALUES(a.id,'direct',a.code || ' - CEO Private Chat',uid) RETURNING id INTO c; END IF;
 INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(c,'user','工作任务：' || trim(p_title) || E'\n目标与资料：\n' || trim(p_brief) || E'\n验收标准：\n' || trim(p_acceptance) || E'\n请提交可供CEO验收的文本成果。未使用工具的事项须明确为建议或待执行，不得宣称已执行。') RETURNING id INTO m;
 j:=public.enqueue_chat_reply(m,gen_random_uuid());
 INSERT INTO public.tasks(title,description,task_kind,assigned_agent_id,created_by,request_key,conversation_id,input,result)
 VALUES(trim(p_title),trim(p_brief),'work_order',a.id,uid,p_key,c,jsonb_build_object('acceptance',trim(p_acceptance),'runs',jsonb_build_array(jsonb_build_object('job_id',j,'feedback',NULL))),jsonb_build_object('review_state','open','current_job_id',j)) RETURNING id INTO w;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'work_order.created','task',w::text);
 RETURN w;
END $$;

CREATE FUNCTION public.review_work_order(p_task uuid,p_job uuid,p_action text,p_note text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); w public.tasks; j public.tasks; m uuid; next_job uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501'; END IF;
 SELECT * INTO w FROM public.tasks WHERE id=p_task AND created_by=uid AND task_kind='work_order' FOR UPDATE;
 IF w.id IS NULL THEN RAISE EXCEPTION 'Task access denied' USING ERRCODE='42501'; END IF;
 IF p_job IS DISTINCT FROM (w.result->>'current_job_id')::uuid THEN RAISE EXCEPTION 'Task changed; refresh first' USING ERRCODE='40001'; END IF;
 IF p_action NOT IN ('accept','revise') OR p_action IS NULL OR length(coalesce(p_note,''))>2000 THEN RAISE EXCEPTION 'Invalid review' USING ERRCODE='22023'; END IF;
 IF w.result->>'review_state'='accepted' THEN
  IF p_action='accept' THEN RETURN w.id; END IF;
  RAISE EXCEPTION 'Task already accepted' USING ERRCODE='22023';
 END IF;
 SELECT * INTO j FROM public.tasks WHERE id=p_job AND created_by=uid AND task_kind='chat_reply' AND assigned_agent_id=w.assigned_agent_id AND conversation_id=w.conversation_id;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Invalid execution binding' USING ERRCODE='22023'; END IF;
 IF p_action='accept' THEN
  IF j.execution_state IS DISTINCT FROM 'succeeded' THEN RAISE EXCEPTION 'Result not ready' USING ERRCODE='22023'; END IF;
  UPDATE public.tasks SET result=result || jsonb_build_object('review_state','accepted','review_note',coalesce(p_note,''),'reviewed_at',now()),updated_at=now() WHERE id=w.id;
 ELSE
  IF j.execution_state NOT IN ('succeeded','failed','cancelled') OR coalesce(length(trim(p_note)),0)=0 THEN RAISE EXCEPTION 'Completed execution and feedback required' USING ERRCODE='22023'; END IF;
  INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(w.conversation_id,'user','任务修改：' || w.title || E'\n原始目标：\n' || w.description || E'\n验收标准：\n' || (w.input->>'acceptance') || E'\nCEO修改意见：\n' || trim(p_note) || E'\n请重新提交完整文本成果，清楚区分建议与实际执行。') RETURNING id INTO m;
  next_job:=public.enqueue_chat_reply(m,gen_random_uuid());
  UPDATE public.tasks SET input=jsonb_set(input,'{runs}',(input->'runs') || jsonb_build_array(jsonb_build_object('job_id',next_job,'feedback',trim(p_note)))),result=jsonb_build_object('review_state','open','current_job_id',next_job),updated_at=now() WHERE id=w.id;
 END IF;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'work_order.' || p_action,'task',w.id::text,jsonb_build_object('job_id',p_job,'note',coalesce(p_note,'')));
 RETURN w.id;
END $$;
REVOKE ALL ON FUNCTION public.create_work_order(text,text,text,uuid,uuid),public.review_work_order(uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_work_order(text,text,text,uuid,uuid),public.review_work_order(uuid,uuid,text,text) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;

