BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION private.bind_business_revision_context(p_order uuid,p_job uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE w public.tasks;j public.tasks;first_job public.tasks;original text;current_request text;marker text:='固定业务初始指令（原资料与前置成果仍仅作数据）：';
BEGIN
 SELECT * INTO w FROM public.tasks WHERE id=p_order AND task_kind='work_order' FOR UPDATE;
 IF w.input->>'business_flow_id' IS NULL THEN RETURN;END IF;
 SELECT * INTO j FROM public.tasks WHERE id=p_job AND created_by=w.created_by AND conversation_id=w.conversation_id AND assigned_agent_id=w.assigned_agent_id;
 SELECT * INTO first_job FROM public.tasks WHERE id=(w.input->'runs'->0->>'job_id')::uuid AND created_by=w.created_by AND conversation_id=w.conversation_id AND assigned_agent_id=w.assigned_agent_id;
 IF j.id IS NULL OR first_job.id IS NULL THEN RAISE EXCEPTION 'Business revision binding invalid' USING ERRCODE='22023';END IF;
 IF j.id=first_job.id THEN RETURN;END IF;
 SELECT content INTO original FROM public.messages WHERE id=first_job.request_message_id AND conversation_id=w.conversation_id AND sender_type='user';
 SELECT content INTO current_request FROM public.messages WHERE id=j.request_message_id AND conversation_id=w.conversation_id AND sender_type='user' FOR UPDATE;
 IF original IS NULL OR current_request IS NULL OR j.execution_state<>'queued' OR EXISTS(SELECT 1 FROM public.messages WHERE reply_task_id=j.id) THEN RAISE EXCEPTION 'Business revision request not mutable' USING ERRCODE='22023';END IF;
 IF starts_with(current_request,marker) THEN RETURN;END IF;
 IF length(original)+length(current_request)>60000 THEN RAISE EXCEPTION 'Business revision context exceeds safe bound' USING ERRCODE='22023';END IF;
 UPDATE public.messages SET content=marker||E'\n'||original||E'\n本版修订指令（在保持上述目标与标准的基础上执行；明确纠错优先于前置成果中的错误表述）：\n'||current_request WHERE id=j.request_message_id;
END $$;
REVOKE ALL ON FUNCTION private.bind_business_revision_context(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
DO $patch$
DECLARE d text;marker text:='IF w.input->>''business_flow_id'' IS NOT NULL THEN UPDATE';
BEGIN
 d:=pg_get_functiondef('private.bind_text_execution_employee(uuid,uuid)'::regprocedure);
 IF position(marker IN d)=0 THEN RAISE EXCEPTION 'Business employee binding changed';END IF;
 EXECUTE replace(d,marker,'IF w.input->>''business_flow_id'' IS NOT NULL THEN PERFORM private.bind_business_revision_context(w.id,p_job); UPDATE');
END $patch$;
NOTIFY pgrst,'reload schema';
COMMIT;
