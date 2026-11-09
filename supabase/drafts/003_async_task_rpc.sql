BEGIN;
SET LOCAL lock_timeout='5s';
-- Explicit CEO allowlist reuses the identity already present in audited RLS.
CREATE FUNCTION public.is_company_ceo(p_user uuid) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$ SELECT p_user = 'b8cbf27e-2391-4fb5-b061-f1488e8c3135'::uuid $$;
CREATE FUNCTION public.enqueue_chat_reply(p_message uuid,p_request_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.conversations; m public.messages; a public.agents; j public.tasks; uid uuid:=auth.uid(); jid uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO authorization required' USING ERRCODE='42501'; END IF;
 SELECT * INTO m FROM public.messages WHERE id=p_message;
 SELECT * INTO c FROM public.conversations WHERE id=m.conversation_id AND created_by=uid FOR UPDATE;
 IF c.id IS NULL OR m.sender_type<>'user' OR m.sender_agent_id IS NOT NULL THEN RAISE EXCEPTION 'Message access denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO a FROM public.agents WHERE id=c.agent_id AND code='CTO' AND is_active;
 IF a.id IS NULL OR p_request_key IS NULL THEN RAISE EXCEPTION 'Invalid chat task' USING ERRCODE='22023'; END IF;
 SELECT * INTO j FROM public.tasks WHERE request_message_id=p_message AND task_kind='chat_reply';
 IF j.id IS NOT NULL THEN RETURN j.id; END IF;
 SELECT * INTO j FROM public.tasks WHERE created_by=uid AND request_key=p_request_key;
 IF j.id IS NOT NULL THEN RAISE EXCEPTION 'Request key already used' USING ERRCODE='22023'; END IF;
 INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id)
 VALUES('CTO chat reply','chat_reply','queued',c.id,m.id,p_request_key,uid,a.id) RETURNING id INTO jid;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'task.queued','task',jid::text);
 RETURN jid;
END $$;
CREATE FUNCTION public.claim_chat_reply() RETURNS SETOF public.tasks LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE jid uuid;
BEGIN
 SELECT id INTO jid FROM public.tasks WHERE task_kind='chat_reply' AND execution_state='queued' AND available_at<=now() AND attempt_count<max_attempts ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,created_at,id FOR UPDATE SKIP LOCKED LIMIT 1;
 RETURN QUERY UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=gen_random_uuid(),lease_expires_at=now()+interval '90 seconds',started_at=coalesce(started_at,now()),updated_at=now() WHERE id=jid RETURNING *;
END $$;
CREATE FUNCTION public.heartbeat_chat_reply(p_task uuid,p_token uuid) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 UPDATE public.tasks SET lease_expires_at=now()+interval '90 seconds',updated_at=now() WHERE id=p_task AND execution_state='running' AND lease_token=p_token AND lease_expires_at>now();
 RETURN FOUND;
END $$;
CREATE FUNCTION public.complete_chat_reply(p_task uuid,p_token uuid,p_content text,p_usage jsonb DEFAULT '[]') RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.tasks; c public.conversations; m public.messages; mid uuid; u jsonb;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task FOR UPDATE;
 IF j.execution_state='succeeded' THEN SELECT id INTO mid FROM public.messages WHERE reply_task_id=j.id; RETURN mid; END IF;
 IF j.execution_state IS DISTINCT FROM 'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RAISE EXCEPTION 'Stale task lease' USING ERRCODE='40001'; END IF;
 SELECT * INTO c FROM public.conversations WHERE id=j.conversation_id AND created_by=j.created_by AND agent_id=j.assigned_agent_id;
 SELECT * INTO m FROM public.messages WHERE id=j.request_message_id AND conversation_id=c.id AND sender_type='user';
 IF c.id IS NULL OR m.id IS NULL OR NOT public.is_company_ceo(j.created_by) OR nullif(trim(p_content),'') IS NULL THEN RAISE EXCEPTION 'Invalid task completion' USING ERRCODE='22023'; END IF;
 INSERT INTO public.messages(conversation_id,sender_type,sender_agent_id,content,reply_task_id) VALUES(c.id,'assistant',j.assigned_agent_id,p_content,j.id) RETURNING id INTO mid;
 FOR u IN SELECT value FROM jsonb_array_elements(p_usage) LOOP
  INSERT INTO public.model_usage(agent_id,provider,model_name,input_tokens,output_tokens,task_id,attempt_number,duration_ms,call_status,provider_request_id)
  VALUES(j.assigned_agent_id,'google',u->>'model',(u->>'input_tokens')::int,(u->>'output_tokens')::int,j.id,j.attempt_count,(u->>'duration_ms')::int,u->>'status',u->>'request_id');
 END LOOP;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id,details) VALUES('worker','task.succeeded','task',j.id::text,jsonb_build_object('reply_message_id',mid));
 UPDATE public.tasks SET execution_state='succeeded',finished_at=now(),lease_token=NULL,lease_expires_at=NULL,result=jsonb_build_object('reply_message_id',mid),last_error_code=NULL,updated_at=now() WHERE id=j.id;
 RETURN mid;
END $$;
CREATE FUNCTION public.fail_chat_reply(p_task uuid,p_token uuid,p_code text,p_retry boolean,p_usage jsonb DEFAULT '[]') RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.tasks; u jsonb; again boolean;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task FOR UPDATE;
 IF j.execution_state IS DISTINCT FROM 'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false; END IF;
 again:=p_retry AND j.attempt_count<j.max_attempts;
 FOR u IN SELECT value FROM jsonb_array_elements(p_usage) LOOP
  INSERT INTO public.model_usage(agent_id,provider,model_name,input_tokens,output_tokens,task_id,attempt_number,duration_ms,call_status) VALUES(j.assigned_agent_id,'google',u->>'model',(u->>'input_tokens')::int,(u->>'output_tokens')::int,j.id,j.attempt_count,(u->>'duration_ms')::int,u->>'status');
 END LOOP;
 UPDATE public.tasks SET execution_state=CASE WHEN again THEN 'queued' ELSE 'failed' END,available_at=now()+make_interval(secs=>least(60,5*power(4,j.attempt_count-1)::int)+floor(random()*3)::int),finished_at=CASE WHEN again THEN NULL ELSE now() END,last_error_code=left(p_code,80),lease_token=NULL,lease_expires_at=NULL,updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id,details) VALUES('worker',CASE WHEN again THEN 'task.retry' ELSE 'task.failed' END,'task',j.id::text,jsonb_build_object('code',left(p_code,80)));
 RETURN true;
END $$;
CREATE FUNCTION public.reap_expired_chat_replies() RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.tasks; n integer:=0;
BEGIN
 FOR j IN SELECT * FROM public.tasks WHERE task_kind='chat_reply' AND execution_state='running' AND lease_expires_at<=now() FOR UPDATE SKIP LOCKED LIMIT 100 LOOP
  UPDATE public.tasks SET execution_state=CASE WHEN attempt_count<max_attempts THEN 'queued' ELSE 'failed' END,finished_at=CASE WHEN attempt_count<max_attempts THEN NULL ELSE now() END,available_at=now()+interval '5 seconds',lease_token=NULL,lease_expires_at=NULL,last_error_code='lease_expired',updated_at=now() WHERE id=j.id;
  INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker','task.lease_expired','task',j.id::text); n:=n+1;
 END LOOP; RETURN n;
END $$;
CREATE FUNCTION public.cancel_chat_reply(p_task uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO authorization required' USING ERRCODE='42501'; END IF;
 UPDATE public.tasks SET execution_state='cancelled',finished_at=now(),lease_token=NULL,lease_expires_at=NULL,updated_at=now() WHERE id=p_task AND created_by=uid AND task_kind='chat_reply' AND execution_state IN ('queued','running');
 RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.is_company_ceo(uuid),public.enqueue_chat_reply(uuid,uuid),public.claim_chat_reply(),public.heartbeat_chat_reply(uuid,uuid),public.complete_chat_reply(uuid,uuid,text,jsonb),public.fail_chat_reply(uuid,uuid,text,boolean,jsonb),public.reap_expired_chat_replies(),public.cancel_chat_reply(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.is_company_ceo(uuid),public.enqueue_chat_reply(uuid,uuid),public.cancel_chat_reply(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_company_ceo(uuid),public.claim_chat_reply(),public.heartbeat_chat_reply(uuid,uuid),public.complete_chat_reply(uuid,uuid,text,jsonb),public.fail_chat_reply(uuid,uuid,text,boolean,jsonb),public.reap_expired_chat_replies() TO service_role;
-- Costs/usage may be unknown for failed requests: distinguish them from measured zero.
ALTER TABLE public.model_usage ALTER COLUMN input_tokens DROP NOT NULL,ALTER COLUMN output_tokens DROP NOT NULL,ALTER COLUMN estimated_cost DROP NOT NULL;
ALTER TABLE public.model_usage ALTER COLUMN input_tokens DROP DEFAULT,ALTER COLUMN output_tokens DROP DEFAULT,ALTER COLUMN estimated_cost DROP DEFAULT;
COMMIT;
