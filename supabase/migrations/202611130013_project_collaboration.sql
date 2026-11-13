BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.project_discussions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),project_id uuid NOT NULL REFERENCES public.company_projects(id),request_key uuid NOT NULL,
 sender_agent_id uuid NOT NULL REFERENCES public.agents(id),recipient_agent_id uuid NOT NULL REFERENCES public.agents(id),topic text NOT NULL CHECK(length(trim(topic)) BETWEEN 1 AND 2000),
 max_rounds integer NOT NULL CHECK(max_rounds BETWEEN 1 AND 2),state text NOT NULL DEFAULT 'active' CHECK(state IN ('active','completed','cancelled')),snapshot jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),completed_at timestamptz,
 CHECK(sender_agent_id<>recipient_agent_id),UNIQUE(created_by,request_key)
);
CREATE UNIQUE INDEX one_active_discussion_per_project ON public.project_discussions(project_id) WHERE state='active';
CREATE INDEX project_discussions_owner_recent ON public.project_discussions(created_by,created_at DESC);
CREATE TABLE public.discussion_turns(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),discussion_id uuid NOT NULL REFERENCES public.project_discussions(id),
 round_number integer NOT NULL CHECK(round_number BETWEEN 1 AND 2),phase integer NOT NULL CHECK(phase IN (0,1)),agent_id uuid NOT NULL REFERENCES public.agents(id),job_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),
 content text CHECK(length(content) BETWEEN 1 AND 5000),created_at timestamptz NOT NULL DEFAULT now(),completed_at timestamptz,UNIQUE(discussion_id,round_number,phase)
);
ALTER TABLE public.project_discussions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discussion_turns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.project_discussions,public.discussion_turns FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.project_discussions,public.discussion_turns TO authenticated,service_role;
CREATE POLICY discussions_ceo_read ON public.project_discussions FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE POLICY discussion_turns_ceo_read ON public.discussion_turns FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));

CREATE FUNCTION private.queue_discussion_turn(p_discussion uuid,p_round integer,p_phase integer) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.project_discussions; tid uuid:=gen_random_uuid(); existing uuid; speaker uuid; c uuid; m uuid; j uuid;
BEGIN
 SELECT * INTO d FROM public.project_discussions WHERE id=p_discussion FOR UPDATE;
 IF d.id IS NULL OR d.state<>'active' OR p_round NOT BETWEEN 1 AND d.max_rounds OR p_phase NOT IN (0,1) OR p_round IS NULL OR p_phase IS NULL THEN RAISE EXCEPTION 'Invalid discussion turn' USING ERRCODE='22023';END IF;
 SELECT id INTO existing FROM public.discussion_turns WHERE discussion_id=d.id AND round_number=p_round AND phase=p_phase;
 IF existing IS NOT NULL THEN RETURN existing;END IF;
 IF (p_phase=1 AND NOT EXISTS(SELECT 1 FROM public.discussion_turns WHERE discussion_id=d.id AND round_number=p_round AND phase=0 AND content IS NOT NULL)) OR (p_round>1 AND p_phase=0 AND NOT EXISTS(SELECT 1 FROM public.discussion_turns WHERE discussion_id=d.id AND round_number=p_round-1 AND phase=1 AND content IS NOT NULL)) THEN RAISE EXCEPTION 'Previous turn unfinished' USING ERRCODE='22023';END IF;
 speaker:=CASE WHEN p_phase=0 THEN d.sender_agent_id ELSE d.recipient_agent_id END;
 IF NOT EXISTS(SELECT 1 FROM public.agents WHERE id=speaker AND is_active) THEN RAISE EXCEPTION 'Participant unavailable' USING ERRCODE='22023';END IF;
 INSERT INTO public.conversations(agent_id,conversation_type,title,created_by) VALUES(speaker,'direct','项目内部协作 · 第'||p_round||'轮',d.created_by) RETURNING id INTO c;
 INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(c,'user','请完成项目内部协作的当前回合。只能提问或答复，不执行外部操作，不修改项目标准。') RETURNING id INTO m;
 INSERT INTO public.tasks(title,task_kind,execution_state,conversation_id,request_message_id,request_key,created_by,assigned_agent_id,input)
 VALUES('项目协作 · '||left(d.topic,70),'chat_reply','queued',c,m,gen_random_uuid(),d.created_by,speaker,jsonb_build_object('discussion_turn_id',tid,'capability','project_dialogue_v1')) RETURNING id INTO j;
 INSERT INTO public.discussion_turns(id,created_by,discussion_id,round_number,phase,agent_id,job_id) VALUES(tid,d.created_by,d.id,p_round,p_phase,speaker,j);
 RETURN tid;
END $$;

CREATE FUNCTION public.start_project_discussion(p_project uuid,p_revision integer,p_sender uuid,p_recipient uuid,p_topic text,p_rounds integer,p_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); p public.company_projects; did uuid; a uuid; sources jsonb;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.company_projects WHERE id=p_project AND created_by=uid FOR UPDATE;
 IF p.id IS NULL THEN RAISE EXCEPTION 'Project denied' USING ERRCODE='42501';END IF;
 IF p_key IS NULL THEN RAISE EXCEPTION 'Request key required' USING ERRCODE='22023';END IF;
 SELECT id INTO did FROM public.project_discussions WHERE created_by=uid AND request_key=p_key AND project_id=p.id;
 IF did IS NOT NULL THEN RETURN did;END IF;
 IF p.revision IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'Stale project version' USING ERRCODE='40001';END IF;
 IF p.state<>'active' OR p.plan_id IS NULL OR p_sender IS NULL OR p_recipient IS NULL OR p_sender=p_recipient OR p_rounds IS NULL OR p_rounds NOT BETWEEN 1 AND 2 OR coalesce(length(trim(p_topic)),0) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Active project and distinct participants required' USING ERRCODE='22023';END IF;
 FOREACH a IN ARRAY ARRAY[p_sender,p_recipient] LOOP
  IF NOT EXISTS(SELECT 1 FROM public.agents ag WHERE ag.id=a AND ag.is_active AND (ag.code='COS' OR EXISTS(SELECT 1 FROM public.tasks t WHERE t.task_kind='plan_assignment' AND t.created_by=uid AND t.input->>'plan_id'=p.plan_id::text AND t.assigned_agent_id=ag.id))) THEN RAISE EXCEPTION 'Participant not assigned to project' USING ERRCODE='42501';END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.project_discussions WHERE project_id=p.id AND state='active') THEN RAISE EXCEPTION 'Another discussion active' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('task_id',w.id,'job_id',w.result->>'current_job_id','title',w.title,'excerpt',left(m.content,1200))),'[]') INTO sources
 FROM public.tasks s JOIN public.tasks w ON w.id=(s.result->>'work_order_id')::uuid AND w.created_by=uid AND w.task_kind='work_order' AND w.result->>'review_state'='accepted'
 JOIN public.messages m ON m.reply_task_id=(w.result->>'current_job_id')::uuid WHERE s.created_by=uid AND s.task_kind='plan_assignment' AND s.input->>'plan_id'=p.plan_id::text;
 INSERT INTO public.project_discussions(created_by,project_id,request_key,sender_agent_id,recipient_agent_id,topic,max_rounds,snapshot)
 VALUES(uid,p.id,p_key,p_sender,p_recipient,trim(p_topic),p_rounds,jsonb_build_object('project_title',p.title,'project_revision',p.revision,'goal',p.goal,'business_acceptance',p.acceptance,'integration_acceptance',p.integration_acceptance,'stages',p.stages,'accepted_sources',sources)) RETURNING id INTO did;
 PERFORM private.queue_discussion_turn(did,1,0);
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'project.discussion_started','project',p.id::text,jsonb_build_object('discussion_id',did,'rounds',p_rounds));
 RETURN did;
END $$;

CREATE FUNCTION private.advance_project_discussion() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE t public.discussion_turns; d public.project_discussions; answer text;
BEGIN
 IF NEW.task_kind<>'chat_reply' OR NEW.input->>'discussion_turn_id' IS NULL OR NEW.execution_state IS DISTINCT FROM 'succeeded' OR OLD.execution_state='succeeded' THEN RETURN NEW;END IF;
 SELECT * INTO t FROM public.discussion_turns WHERE id::text=NEW.input->>'discussion_turn_id' AND job_id=NEW.id AND created_by=NEW.created_by AND agent_id=NEW.assigned_agent_id FOR UPDATE;
 SELECT * INTO d FROM public.project_discussions WHERE id=t.discussion_id AND created_by=NEW.created_by FOR UPDATE;
 IF t.id IS NULL OR d.id IS NULL OR d.state<>'active' THEN RAISE EXCEPTION 'Invalid discussion completion' USING ERRCODE='22023';END IF;
 SELECT content INTO answer FROM public.messages WHERE reply_task_id=NEW.id;
 IF coalesce(length(trim(answer)),0) NOT BETWEEN 1 AND (CASE WHEN t.phase=0 THEN 1400 ELSE 5000 END) THEN RAISE EXCEPTION 'Discussion output outside bounds' USING ERRCODE='22023';END IF;
 UPDATE public.discussion_turns SET content=answer,completed_at=now() WHERE id=t.id;
 IF EXISTS(SELECT 1 FROM public.company_projects WHERE id=d.project_id AND state='accepted') THEN
  UPDATE public.project_discussions SET state='completed',completed_at=now() WHERE id=d.id;
 ELSIF t.phase=0 THEN PERFORM private.queue_discussion_turn(d.id,t.round_number,1);
 ELSIF t.round_number<d.max_rounds THEN PERFORM private.queue_discussion_turn(d.id,t.round_number+1,0);
 ELSE UPDATE public.project_discussions SET state='completed',completed_at=now() WHERE id=d.id;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER advance_project_discussion AFTER UPDATE OF execution_state ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.advance_project_discussion();
CREATE FUNCTION public.retry_project_discussion(p_discussion uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); d public.project_discussions; turn public.discussion_turns; j public.tasks;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO d FROM public.project_discussions WHERE id=p_discussion AND created_by=uid;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Discussion denied' USING ERRCODE='42501';END IF;
 IF d.state<>'active' THEN RETURN d.id;END IF;
 SELECT * INTO turn FROM public.discussion_turns WHERE discussion_id=d.id ORDER BY round_number DESC,phase DESC LIMIT 1;
 SELECT * INTO j FROM public.tasks WHERE id=turn.job_id AND execution_state IN ('failed','cancelled') FOR UPDATE;
 IF j.id IS NULL THEN RETURN d.id;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.project_discussions WHERE id=d.id AND state='active') THEN RETURN d.id;END IF;
 IF j.attempt_count>=10 THEN RAISE EXCEPTION 'Retry limit reached' USING ERRCODE='22023';END IF;
 UPDATE public.tasks SET execution_state='queued',max_attempts=greatest(max_attempts,attempt_count+1),available_at=now(),finished_at=NULL,last_error_code=NULL,updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'project.discussion_retry','task',j.id::text);
 RETURN d.id;
END $$;
CREATE FUNCTION public.close_failed_project_discussion(p_discussion uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); d public.project_discussions; j uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO d FROM public.project_discussions WHERE id=p_discussion AND created_by=uid;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Discussion denied' USING ERRCODE='42501';END IF;
 IF d.state<>'active' THEN RETURN d.id;END IF;
 SELECT t.id INTO j FROM public.tasks t WHERE t.id=(SELECT job_id FROM public.discussion_turns WHERE discussion_id=d.id ORDER BY round_number DESC,phase DESC LIMIT 1) AND t.execution_state IN ('failed','cancelled') FOR UPDATE;
 IF j IS NULL THEN RAISE EXCEPTION 'Only a failed discussion can be closed' USING ERRCODE='22023';END IF;
 UPDATE public.project_discussions SET state='cancelled',completed_at=now() WHERE id=d.id AND state='active';
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'project.discussion_closed','discussion',d.id::text);
 RETURN d.id;
END $$;
CREATE FUNCTION public.discussion_context_for_task(p_task uuid,p_token uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.tasks; w public.tasks; project uuid; refs jsonb;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='chat_reply' AND execution_state='running' AND lease_token=p_token AND lease_expires_at>now() AND public.is_company_ceo(created_by) FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Live task lease required' USING ERRCODE='42501';END IF;
 SELECT * INTO w FROM public.tasks WHERE task_kind='work_order' AND created_by=j.created_by AND result->>'current_job_id'=j.id::text AND assigned_agent_id=j.assigned_agent_id AND conversation_id=j.conversation_id;
 IF w.id IS NULL THEN RETURN '[]';END IF;
 IF j.input?'discussion_context' THEN RETURN j.input->'discussion_context';END IF;
 SELECT id INTO project FROM public.company_projects WHERE created_by=j.created_by AND plan_id::text=w.input->>'parent_plan_id';
 SELECT coalesce(jsonb_agg(x.item),'[]') INTO refs FROM (
  SELECT jsonb_build_object('discussion_id',d.id,'project_revision',d.snapshot->'project_revision','topic',left(d.topic,300),'reply',left(t.content,1200),'reply_job_id',t.job_id) AS item
  FROM public.project_discussions d JOIN LATERAL(SELECT content,job_id FROM public.discussion_turns WHERE discussion_id=d.id AND phase=1 AND content IS NOT NULL ORDER BY round_number DESC LIMIT 1)t ON true
  WHERE d.project_id=project AND d.created_by=j.created_by AND d.state='completed' ORDER BY d.completed_at DESC,d.id LIMIT 2
 )x;
 UPDATE public.tasks SET input=input||jsonb_build_object('discussion_context',refs) WHERE id=j.id;
 RETURN refs;
END $$;
REVOKE ALL ON FUNCTION private.queue_discussion_turn(uuid,integer,integer),private.advance_project_discussion() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.start_project_discussion(uuid,integer,uuid,uuid,text,integer,uuid),public.retry_project_discussion(uuid),public.close_failed_project_discussion(uuid) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discussion_context_for_task(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.discussion_context_for_task(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.start_project_discussion(uuid,integer,uuid,uuid,text,integer,uuid),public.retry_project_discussion(uuid),public.close_failed_project_discussion(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
