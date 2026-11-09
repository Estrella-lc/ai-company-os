-- Execute only in a disposable database restored from audited catalog.
BEGIN;
DO $$
DECLARE owner_id uuid:=gen_random_uuid(); agent_id uuid:=gen_random_uuid(); conv_id uuid:=gen_random_uuid(); other_conv uuid:=gen_random_uuid(); request_id uuid:=gen_random_uuid(); job_id uuid:=gen_random_uuid();
BEGIN
 IF has_table_privilege('anon','public.tasks','TRUNCATE') THEN RAISE EXCEPTION 'anon retains TRUNCATE'; END IF;
 IF has_table_privilege('authenticated','public.tasks','TRUNCATE') THEN RAISE EXCEPTION 'authenticated retains TRUNCATE'; END IF;
 IF NOT has_table_privilege('authenticated','public.tasks','SELECT') THEN RAISE EXCEPTION 'polling grant absent'; END IF;
 IF has_table_privilege('authenticated','public.tasks','UPDATE') THEN RAISE EXCEPTION 'browser can mutate tasks'; END IF;
 IF NOT has_table_privilege('service_role','public.agents','SELECT') THEN RAISE EXCEPTION 'worker agent read absent'; END IF;
 INSERT INTO auth.users(id) VALUES(owner_id);
 INSERT INTO public.agents(id,code,name,title) VALUES(agent_id,'TEST_ASYNC','Test','Test');
 INSERT INTO public.conversations(id,created_by,agent_id) VALUES(conv_id,owner_id,agent_id),(other_conv,owner_id,agent_id);
 INSERT INTO public.messages(id,conversation_id,sender_type,content) VALUES(request_id,conv_id,'user','test');
 INSERT INTO public.tasks(title) VALUES('legacy task');
 INSERT INTO public.tasks(id,title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id)
 VALUES(job_id,'async test','chat_reply','queued',conv_id,request_id,gen_random_uuid(),owner_id,agent_id);
 BEGIN
  INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id)
  VALUES('duplicate','chat_reply','queued',conv_id,request_id,gen_random_uuid(),owner_id,agent_id);
  RAISE EXCEPTION 'duplicate request accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
 BEGIN
  UPDATE public.tasks SET conversation_id=other_conv WHERE id=job_id;
  RAISE EXCEPTION 'cross-conversation request accepted';
 EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 BEGIN
  UPDATE public.tasks SET execution_state='running' WHERE id=job_id;
  RAISE EXCEPTION 'running without lease accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
  UPDATE public.tasks SET attempt_count=4 WHERE id=job_id;
  RAISE EXCEPTION 'exhausted attempts accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
 INSERT INTO public.messages(conversation_id,sender_type,sender_agent_id,content,reply_task_id)
 VALUES(conv_id,'assistant',agent_id,'reply',job_id);
 BEGIN
  INSERT INTO public.messages(conversation_id,sender_type,sender_agent_id,content,reply_task_id)
  VALUES(conv_id,'assistant',agent_id,'duplicate reply',job_id);
  RAISE EXCEPTION 'duplicate reply accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
 UPDATE public.tasks SET execution_state='succeeded',finished_at=now() WHERE id=job_id;
 RAISE NOTICE 'PASS: legacy compatibility, request uniqueness, conversation FK, lease checks, attempt limit, reply uniqueness, grants';
END $$;
ROLLBACK;
