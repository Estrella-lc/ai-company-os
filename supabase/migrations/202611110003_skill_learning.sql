-- Skill acquisition jobs are separate from chat execution. No arbitrary shell is granted to models.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.ai_employees(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),manager_agent_id uuid NOT NULL REFERENCES public.agents(id),
 name text NOT NULL,role text NOT NULL CHECK(role='skill_researcher'),created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(created_by,manager_agent_id,role));
CREATE TABLE public.agent_skills(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),manager_agent_id uuid NOT NULL REFERENCES public.agents(id),employee_id uuid NOT NULL REFERENCES public.ai_employees(id),
 request_task_id uuid NOT NULL REFERENCES public.tasks(id),repository text NOT NULL,commit_sha text NOT NULL CHECK(commit_sha ~ '^[0-9a-f]{40}$'),skill_path text NOT NULL,
 name text NOT NULL,description text NOT NULL DEFAULT '',capability text NOT NULL,status text NOT NULL CHECK(status IN ('static_checked','verified_limited','needs_setup','rejected')),
 document text NOT NULL CHECK(length(document)<=40000),metadata jsonb NOT NULL DEFAULT '{}',verification jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(created_by,manager_agent_id,repository,commit_sha,skill_path,capability));
ALTER TABLE public.ai_employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_skills ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ai_employees,public.agent_skills FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ai_employees,public.agent_skills TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public.ai_employees,public.agent_skills TO service_role;
GRANT SELECT ON public.audit_logs TO service_role;
CREATE POLICY employees_ceo_read ON public.ai_employees FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE POLICY skills_ceo_read ON public.agent_skills FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));

CREATE FUNCTION private.enqueue_skill_research(p_owner uuid,p_manager uuid,p_need text,p_query text,p_plan uuid,p_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.agents; employee uuid; jid uuid; v_capability text; query text; reusable jsonb;
BEGIN
 IF public.is_company_ceo(p_owner) IS DISTINCT FROM true OR p_key IS NULL OR coalesce(length(trim(p_need)),0) NOT BETWEEN 1 AND 4000 THEN RAISE EXCEPTION 'Invalid skill request' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_owner::text || p_key::text,0));
 SELECT id INTO jid FROM public.tasks WHERE created_by=p_owner AND request_key=p_key AND task_kind='skill_research';IF jid IS NOT NULL THEN RETURN jid; END IF;
 SELECT * INTO a FROM public.agents WHERE id=p_manager AND is_active;
 IF a.id IS NULL THEN RAISE EXCEPTION 'Active manager required' USING ERRCODE='22023'; END IF;
 IF p_plan IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=p_plan AND created_by=p_owner AND task_kind='work_plan') THEN RAISE EXCEPTION 'Plan denied' USING ERRCODE='42501'; END IF;
 v_capability:=CASE WHEN p_need ~* '字幕|subtitle|caption|srt' THEN 'subtitles' WHEN p_need ~* '剪辑|视频|video|ffmpeg' THEN 'video' WHEN p_need ~* '开发|代码|编程|development|coding' THEN 'development' WHEN p_need ~* 'pdf|文档|document' THEN 'documents' ELSE 'general' END;
 query:=CASE v_capability WHEN 'subtitles' THEN 'subtitle agent skills' WHEN 'video' THEN 'ffmpeg agent skills' WHEN 'development' THEN 'coding agent skills' WHEN 'documents' THEN 'pdf agent skills' ELSE 'agent skills' END;
 IF nullif(trim(p_query),'') IS NOT NULL THEN
  IF p_query !~ '^[A-Za-z0-9 _-]{2,64}$' THEN RAISE EXCEPTION 'Use generic English search keywords' USING ERRCODE='22023'; END IF;
  query:=trim(p_query);
 END IF;
 IF (SELECT count(*) FROM public.tasks WHERE task_kind='skill_research' AND created_by=p_owner AND created_at>=date_trunc('day',now()))>=10 THEN RAISE EXCEPTION 'Daily research request limit' USING ERRCODE='22023'; END IF;
 INSERT INTO public.ai_employees(created_by,manager_agent_id,name,role) VALUES(p_owner,a.id,a.code || ' 技能研究与验证员','skill_researcher') ON CONFLICT(created_by,manager_agent_id,role) DO UPDATE SET name=excluded.name RETURNING id INTO employee;
 -- Reuse only the exact bounded capability that was actually verified.
 SELECT jsonb_agg(id) INTO reusable FROM public.agent_skills WHERE created_by=p_owner AND manager_agent_id=a.id AND agent_skills.capability=v_capability AND status='verified_limited' AND agent_skills.capability='subtitles' AND p_need ~* 'srt|字幕烧录|字幕合成|已有字幕' AND p_need !~* '语音|转录|识别|transcrib|recogn';
 INSERT INTO public.tasks(title,description,task_kind,created_by,assigned_agent_id,request_key,input,execution_state,finished_at,result)
 VALUES('技能研究 · ' || left(p_need,60),p_need,'skill_research',p_owner,a.id,p_key,jsonb_build_object('query',query,'capability',v_capability,'employee_id',employee,'plan_id',p_plan),CASE WHEN reusable IS NULL THEN 'queued' ELSE 'succeeded' END,CASE WHEN reusable IS NULL THEN NULL ELSE now() END,CASE WHEN reusable IS NULL THEN NULL ELSE jsonb_build_object('reused',true,'skill_ids',reusable,'summary','复用已有的有限范围验证能力；不代表整个业务目标已完成') END) RETURNING id INTO jid;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('agent',a.id::text,'skill_research.requested','task',jid::text);
 RETURN jid;
END $$;
CREATE FUNCTION public.request_skill_research(p_manager uuid,p_need text,p_query text,p_key uuid,p_plan uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501'; END IF;
 RETURN private.enqueue_skill_research(auth.uid(),p_manager,p_need,p_query,p_plan,p_key);
END $$;

CREATE FUNCTION public.claim_skill_research(p_runner text) RETURNS SETOF public.tasks LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE expired public.tasks; jid uuid;
BEGIN
 IF p_runner IS NULL OR p_runner !~ '^[0-9]+/[0-9]+$' THEN RAISE EXCEPTION 'Invalid runner' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('skill_daily_claim',0));
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker','skill_runner.connected','workflow',p_runner);
 FOR expired IN SELECT * FROM public.tasks WHERE task_kind='skill_research' AND execution_state='running' AND lease_expires_at<=now() FOR UPDATE SKIP LOCKED LIMIT 100 LOOP
  UPDATE public.tasks SET execution_state=CASE WHEN attempt_count<max_attempts THEN 'queued' ELSE 'failed' END,finished_at=CASE WHEN attempt_count<max_attempts THEN NULL ELSE now() END,lease_token=NULL,lease_expires_at=NULL,last_error_code='runner_interrupted',available_at=now(),updated_at=now() WHERE id=expired.id;
 END LOOP;
 SELECT id INTO jid FROM public.tasks WHERE task_kind='skill_research' AND execution_state='running' AND input->>'runner_id'=p_runner AND lease_expires_at>now() LIMIT 1;
 IF jid IS NOT NULL THEN RETURN QUERY SELECT * FROM public.tasks WHERE id=jid; RETURN; END IF;
 -- At most three paid-metered workflow jobs can claim work daily. Existing GitHub $0 overage budget remains authoritative.
 IF (SELECT count(*) FROM public.audit_logs WHERE action='skill_research.claimed' AND created_at>=date_trunc('day',now()))>=3 THEN RETURN; END IF;
 SELECT id INTO jid FROM public.tasks WHERE task_kind='skill_research' AND execution_state='queued' AND available_at<=now() AND attempt_count<max_attempts ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1;
 IF jid IS NULL THEN RETURN; END IF;
 UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=gen_random_uuid(),lease_expires_at=now()+interval '10 minutes',started_at=coalesce(started_at,now()),input=input || jsonb_build_object('runner_id',p_runner),updated_at=now() WHERE id=jid;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker','skill_research.claimed','task',jid::text);
 RETURN QUERY SELECT * FROM public.tasks WHERE id=jid;
END $$;

CREATE FUNCTION public.finish_skill_research(p_task uuid,p_token uuid,p_runner text,p_report jsonb,p_failed boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.tasks; candidate jsonb; skill uuid; ids jsonb:='[]'; state text;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='skill_research' FOR UPDATE;
 IF j.id IS NULL OR j.input->>'runner_id' IS DISTINCT FROM p_runner THEN RETURN false; END IF;
 IF j.execution_state IN ('succeeded','failed') THEN RETURN true; END IF;
 IF j.execution_state IS DISTINCT FROM 'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false; END IF;
 IF jsonb_typeof(p_report) IS DISTINCT FROM 'object' OR length(p_report::text)>200000 THEN RAISE EXCEPTION 'Invalid report' USING ERRCODE='22023'; END IF;
 IF p_failed THEN
  UPDATE public.tasks SET execution_state=CASE WHEN attempt_count<max_attempts THEN 'queued' ELSE 'failed' END,available_at=now()+interval '5 minutes',finished_at=CASE WHEN attempt_count<max_attempts THEN NULL ELSE now() END,lease_token=NULL,lease_expires_at=NULL,result=p_report,last_error_code='skill_research_failed',updated_at=now() WHERE id=j.id;
  INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker',CASE WHEN j.attempt_count<j.max_attempts THEN 'skill_research.retry' ELSE 'skill_research.failed' END,'task',j.id::text);
  RETURN true;
 END IF;
 IF NOT p_failed THEN
  IF jsonb_typeof(p_report->'candidates') IS DISTINCT FROM 'array' OR jsonb_array_length(p_report->'candidates')>3 THEN RAISE EXCEPTION 'Invalid candidates' USING ERRCODE='22023'; END IF;
  FOR candidate IN SELECT value FROM jsonb_array_elements(p_report->'candidates') LOOP
   IF coalesce(candidate->>'commit_sha','') !~ '^[0-9a-f]{40}$' OR coalesce(candidate->>'repository','') !~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' OR coalesce(candidate->>'skill_path','') !~ '(^|/)SKILL.md$' OR coalesce(length(candidate->>'document'),0) NOT BETWEEN 1 AND 40000 THEN RAISE EXCEPTION 'Invalid source evidence' USING ERRCODE='22023'; END IF;
   state:=CASE WHEN candidate->>'rejected'='true' THEN 'rejected' WHEN j.input->>'capability'='subtitles' AND candidate->'verification'->>'passed'='true' AND candidate->'verification'->>'scope'='subtitle_fixture_v1' THEN 'verified_limited' ELSE 'needs_setup' END;
   INSERT INTO public.agent_skills(created_by,manager_agent_id,employee_id,request_task_id,repository,commit_sha,skill_path,name,description,capability,status,document,metadata,verification)
   VALUES(j.created_by,j.assigned_agent_id,(j.input->>'employee_id')::uuid,j.id,candidate->>'repository',candidate->>'commit_sha',candidate->>'skill_path',left(coalesce(candidate->>'name','Unnamed skill'),100),left(coalesce(candidate->>'description',''),2000),j.input->>'capability',state,candidate->>'document',coalesce(candidate->'metadata','{}'),coalesce(candidate->'verification','{}'))
   ON CONFLICT(created_by,manager_agent_id,repository,commit_sha,skill_path,capability) DO UPDATE SET request_task_id=excluded.request_task_id,status=excluded.status,verification=excluded.verification RETURNING id INTO skill;
   ids:=ids || to_jsonb(skill);
  END LOOP;
 END IF;
 UPDATE public.tasks SET execution_state=CASE WHEN p_failed THEN 'failed' ELSE 'succeeded' END,finished_at=now(),lease_token=NULL,lease_expires_at=NULL,result=p_report || jsonb_build_object('skill_ids',ids),last_error_code=CASE WHEN p_failed THEN 'skill_research_failed' ELSE NULL END,updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker',CASE WHEN p_failed THEN 'skill_research.failed' ELSE 'skill_research.finished' END,'task',j.id::text);
 RETURN true;
END $$;

CREATE FUNCTION private.research_plan_capability_gap() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE plan public.tasks; reply text; parsed jsonb;
BEGIN
 IF NEW.task_kind<>'chat_reply' OR NEW.execution_state<>'succeeded' OR OLD.execution_state='succeeded' THEN RETURN NEW; END IF;
 SELECT * INTO plan FROM public.tasks WHERE task_kind='work_plan' AND result->>'current_job_id'=NEW.id::text LIMIT 1;
 IF plan.id IS NULL THEN RETURN NEW; END IF;
 SELECT content INTO reply FROM public.messages WHERE reply_task_id=NEW.id;
 BEGIN parsed:=regexp_replace(regexp_replace(trim(reply),'^```(json)?\s*','','i'),'\s*```$','')::jsonb; EXCEPTION WHEN others THEN RETURN NEW; END;
 IF jsonb_typeof(parsed->'missing_information') IS DISTINCT FROM 'array' THEN RETURN NEW; END IF;
 IF jsonb_array_length(parsed->'missing_information')>0 AND (parsed->'missing_information')::text ~* '工具|技能|能力|剪辑|开发|skill|tool|subtitle|transcrib' THEN
  -- Same plan is its idempotency key: one research employee/job per capability gap.
  BEGIN
   PERFORM private.enqueue_skill_research(plan.created_by,plan.assigned_agent_id,left(plan.description || E'\n能力缺口：' || (parsed->'missing_information')::text,4000),'',plan.id,plan.id);
  EXCEPTION WHEN others THEN
   INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id,details) VALUES('worker','skill_research.auto_request_failed','task',plan.id::text,jsonb_build_object('sqlstate',SQLSTATE));
  END;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER plan_capability_research AFTER UPDATE OF execution_state ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.research_plan_capability_gap();
REVOKE ALL ON FUNCTION private.enqueue_skill_research(uuid,uuid,text,text,uuid,uuid),private.research_plan_capability_gap(),public.request_skill_research(uuid,text,text,uuid,uuid),public.claim_skill_research(text),public.finish_skill_research(uuid,uuid,text,jsonb,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.request_skill_research(uuid,text,text,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_skill_research(text),public.finish_skill_research(uuid,uuid,text,jsonb,boolean) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;


