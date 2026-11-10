-- Enable replies for active executives using the existing CEO-only queue.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE OR REPLACE FUNCTION public.enqueue_chat_reply(p_message uuid,p_request_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.conversations; m public.messages; a public.agents; j public.tasks; uid uuid:=auth.uid(); jid uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO authorization required' USING ERRCODE='42501'; END IF;
 SELECT * INTO m FROM public.messages WHERE id=p_message;
 SELECT * INTO c FROM public.conversations WHERE id=m.conversation_id AND created_by=uid FOR UPDATE;
 IF c.id IS NULL OR m.sender_type<>'user' OR m.sender_agent_id IS NOT NULL THEN RAISE EXCEPTION 'Message access denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO a FROM public.agents WHERE id=c.agent_id AND is_active;
 IF a.id IS NULL OR p_request_key IS NULL THEN RAISE EXCEPTION 'Invalid chat task' USING ERRCODE='22023'; END IF;
 SELECT * INTO j FROM public.tasks WHERE request_message_id=p_message AND task_kind='chat_reply';
 IF j.id IS NOT NULL THEN RETURN j.id; END IF;
 SELECT * INTO j FROM public.tasks WHERE created_by=uid AND request_key=p_request_key;
 IF j.id IS NOT NULL THEN RAISE EXCEPTION 'Request key already used' USING ERRCODE='22023'; END IF;
 INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id)
 VALUES(a.code || ' chat reply','chat_reply','queued',c.id,m.id,p_request_key,uid,a.id) RETURNING id INTO jid;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'task.queued','task',jid::text);
 RETURN jid;
END $$;
NOTIFY pgrst, 'reload schema';
COMMIT;
