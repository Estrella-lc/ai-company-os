BEGIN;
CREATE TABLE public.motion_jobs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),goal_id uuid NOT NULL UNIQUE REFERENCES public.company_goals(id),
 task_id uuid NOT NULL UNIQUE REFERENCES public.tasks(id),prompt text NOT NULL CHECK(length(prompt) BETWEEN 1 AND 1500),
 provider_event_id text CHECK(provider_event_id ~ '^[a-f0-9]{32}$'),state text NOT NULL DEFAULT 'queued' CHECK(state IN('queued','generating','pending','reviewing','needs_revision','awaiting_ceo','accepted')),
 output_path text,report jsonb,quality_job uuid REFERENCES public.tasks(id),created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.motion_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.motion_jobs FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.motion_jobs TO authenticated,service_role;
CREATE POLICY motion_owner ON public.motion_jobs FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE POLICY motion_video_owner ON storage.objects FOR SELECT TO authenticated USING(bucket_id='company-films' AND public.is_company_ceo(auth.uid()) AND EXISTS(SELECT 1 FROM public.motion_jobs m WHERE m.created_by=auth.uid() AND m.output_path=name));
CREATE FUNCTION public.request_motion_job(p_goal uuid,p_prompt text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.company_goals;j uuid;m uuid;a uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO g FROM public.company_goals WHERE id=p_goal AND created_by=auth.uid() FOR UPDATE;
 IF g.id IS NULL OR g.state<>'accepted' OR length(trim(p_prompt)) NOT BETWEEN 1 AND 1500 THEN RAISE EXCEPTION 'Accepted goal and bounded prompt required';END IF;
 SELECT id INTO m FROM public.motion_jobs WHERE goal_id=p_goal;IF m IS NOT NULL THEN RETURN m;END IF;
 SELECT id INTO a FROM public.agents WHERE code='CTO' AND is_active LIMIT 1;
 INSERT INTO public.tasks(title,description,task_kind,created_by,assigned_agent_id,request_key,input,execution_state,max_attempts)
 VALUES('动态人物镜头 · 免费技术验证','Lightricks 文生视频：人物真实动作，5至8秒；不保证原角色一致性','skill_research',g.created_by,a,gen_random_uuid(),'{"mode":"motion_video","capability":"video"}','queued',2) RETURNING id INTO j;
 INSERT INTO public.motion_jobs(created_by,goal_id,task_id,prompt) VALUES(g.created_by,p_goal,j,p_prompt) RETURNING id INTO m;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',auth.uid()::text,'motion.requested','task',j::text);
 RETURN m;
END $$;
CREATE FUNCTION public.motion_task_context(p_task uuid,p_token uuid,p_runner text) RETURNS SETOF public.motion_jobs LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT m.* FROM public.motion_jobs m JOIN public.tasks t ON t.id=m.task_id AND t.created_by=m.created_by WHERE t.id=p_task AND t.input->>'mode'='motion_video' AND t.execution_state='running' AND t.lease_token=p_token AND t.lease_expires_at>now() AND t.input->>'runner_id'=p_runner;
$$;
CREATE FUNCTION public.update_motion_task(p_task uuid,p_token uuid,p_runner text,p_action text,p_payload jsonb) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.motion_jobs;t public.tasks;path text;
BEGIN
 SELECT * INTO t FROM public.tasks WHERE id=p_task FOR UPDATE;
 SELECT * INTO m FROM public.motion_task_context(p_task,p_token,p_runner);IF m.id IS NULL THEN RETURN false;END IF;
 IF p_action='submitted' THEN
  IF coalesce(p_payload->>'event_id','') !~ '^[a-f0-9]{32}$' OR (m.provider_event_id IS NOT NULL AND m.provider_event_id IS DISTINCT FROM p_payload->>'event_id') THEN RAISE EXCEPTION 'Provider binding invalid';END IF;
  UPDATE public.motion_jobs SET provider_event_id=p_payload->>'event_id',state='generating' WHERE id=m.id;
 ELSIF p_action='pending' THEN
  IF m.provider_event_id IS NULL THEN RETURN false;END IF;
  UPDATE public.motion_jobs SET state='pending' WHERE id=m.id;
  UPDATE public.tasks SET execution_state=CASE WHEN attempt_count<max_attempts THEN 'queued' ELSE 'failed' END,available_at=now()+interval '5 minutes',lease_token=NULL,lease_expires_at=NULL,finished_at=CASE WHEN attempt_count>=max_attempts THEN now() ELSE NULL END,last_error_code='motion_provider_unverified' WHERE id=t.id;
 ELSIF p_action='complete' THEN
  path:=m.created_by::text||'/'||t.id::text||'/'||p_token::text||'/motion.mp4';
  IF m.provider_event_id IS NULL OR p_payload->>'provider_event_id' IS DISTINCT FROM m.provider_event_id OR p_payload->>'output_path' IS DISTINCT FROM path OR coalesce(p_payload->>'sha256','') !~ '^[a-f0-9]{64}$' OR p_payload->>'motion_review' IS DISTINCT FROM 'required' OR p_payload->>'ceo_acceptance' IS DISTINCT FROM 'false' OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-films' AND name=path AND (metadata->>'size')::bigint BETWEEN 12 AND 20971520 AND (metadata->>'size')::bigint=(p_payload->>'bytes')::bigint) THEN RAISE EXCEPTION 'Motion output evidence invalid';END IF;
  UPDATE public.motion_jobs SET output_path=path,report=p_payload,state='reviewing',quality_job=private.goal_reply(m.created_by,'COO','独立动态视频质检',jsonb_build_object('motion_review_id',m.id),'quality_inspector') WHERE id=m.id;
  UPDATE public.tasks SET execution_state='succeeded',result=p_payload,lease_token=NULL,lease_expires_at=NULL,finished_at=now() WHERE id=t.id;
 ELSE RETURN false;
 END IF;
 RETURN true;
END $$;
CREATE FUNCTION public.advance_motion_reviews() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.motion_jobs;r jsonb;n integer:=0;
BEGIN
 FOR m IN SELECT * FROM public.motion_jobs WHERE state='reviewing' AND quality_job IS NOT NULL FOR UPDATE SKIP LOCKED LOOP
  IF EXISTS(SELECT 1 FROM public.tasks WHERE id=m.quality_job AND execution_state IN('failed','cancelled')) THEN UPDATE public.motion_jobs SET state='needs_revision' WHERE id=m.id;CONTINUE;END IF;
  IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=m.quality_job AND created_by=m.created_by AND execution_state='succeeded') THEN CONTINUE;END IF;
  BEGIN
   SELECT content::jsonb INTO r FROM public.messages WHERE reply_task_id=m.quality_job;
   IF r->>'verdict'='pass' AND r->>'motion_present'='true' AND r->>'face_visible'='true' AND r->>'coherent'='true' AND (r->>'duration')::numeric BETWEEN 5 AND 8 AND jsonb_array_length(r->'evidence')>=2 THEN
    UPDATE public.motion_jobs SET state='awaiting_ceo',report=report||jsonb_build_object('quality',r) WHERE id=m.id;
   ELSE UPDATE public.motion_jobs SET state='needs_revision',report=report||jsonb_build_object('quality',r) WHERE id=m.id;END IF;
   n:=n+1;
  EXCEPTION WHEN OTHERS THEN UPDATE public.motion_jobs SET state='needs_revision' WHERE id=m.id;
  END;
 END LOOP;RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.advance_motion_reviews() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.advance_motion_reviews() TO service_role;
REVOKE ALL ON FUNCTION public.request_motion_job(uuid,text),public.motion_task_context(uuid,uuid,text),public.update_motion_task(uuid,uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.request_motion_job(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.motion_task_context(uuid,uuid,text),public.update_motion_task(uuid,uuid,text,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;

