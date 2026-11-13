-- Project-specific acceptance gates; no new worker permissions or model execution.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.company_projects (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), created_by uuid NOT NULL REFERENCES auth.users(id),
 request_key uuid NOT NULL, title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 goal text NOT NULL CHECK(length(trim(goal)) BETWEEN 1 AND 4000),
 acceptance text NOT NULL CHECK(length(trim(acceptance)) BETWEEN 1 AND 2000),
 integration_acceptance text NOT NULL CHECK(length(trim(integration_acceptance)) BETWEEN 1 AND 2000),
 stages jsonb NOT NULL, plan_id uuid UNIQUE REFERENCES public.tasks(id), revision integer NOT NULL DEFAULT 0,
 state text NOT NULL DEFAULT 'draft' CHECK(state IN ('draft','active','accepted')),
 integration_state text NOT NULL DEFAULT 'pending' CHECK(integration_state IN ('pending','passed','failed')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(created_by,request_key), CHECK(jsonb_typeof(stages)='array' AND jsonb_array_length(stages) BETWEEN 1 AND 8)
);
CREATE TABLE public.project_checks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.company_projects(id),
 created_by uuid NOT NULL REFERENCES auth.users(id), project_revision integer NOT NULL,
 level text NOT NULL CHECK(level IN ('stage','integration','final')), stage_index integer,
 outcome text NOT NULL CHECK(outcome IN ('passed','failed')),
 evidence text NOT NULL CHECK(length(trim(evidence)) BETWEEN 1 AND 4000),
 actor_kind text NOT NULL DEFAULT 'ceo_manual' CHECK(actor_kind='ceo_manual'),
 snapshot jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((level='stage' AND stage_index IS NOT NULL AND stage_index>=0) OR (level<>'stage' AND stage_index IS NULL))
);
CREATE INDEX company_projects_owner_recent ON public.company_projects(created_by,created_at DESC);
CREATE INDEX project_checks_project_recent ON public.project_checks(project_id,created_at DESC);
ALTER TABLE public.company_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_checks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_projects,public.project_checks FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.company_projects,public.project_checks TO authenticated;
CREATE POLICY projects_ceo_read ON public.company_projects FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE POLICY project_checks_ceo_read ON public.project_checks FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()) AND EXISTS(SELECT 1 FROM public.company_projects p WHERE p.id=project_id AND p.created_by=auth.uid()));

CREATE FUNCTION private.validate_project_stages(p_stages jsonb) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE s jsonb;
BEGIN
 IF jsonb_typeof(p_stages) IS DISTINCT FROM 'array' OR jsonb_array_length(p_stages) NOT BETWEEN 1 AND 8 THEN RAISE EXCEPTION 'Invalid project stages' USING ERRCODE='22023';END IF;
 FOR s IN SELECT value FROM jsonb_array_elements(p_stages) LOOP
  IF jsonb_typeof(s) IS DISTINCT FROM 'object' OR jsonb_typeof(s->'title') IS DISTINCT FROM 'string' OR coalesce(length(trim(s->>'title')),0) NOT BETWEEN 1 AND 120 OR jsonb_typeof(s->'acceptance') IS DISTINCT FROM 'string' OR coalesce(length(trim(s->>'acceptance')),0) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Stage title and criteria required' USING ERRCODE='22023';END IF;
 END LOOP;
END $$;

CREATE FUNCTION public.create_company_project(p_title text,p_goal text,p_acceptance text,p_integration text,p_stages jsonb,p_key uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); pid uuid; clean jsonb;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 IF p_key IS NULL OR coalesce(length(trim(p_title)),0) NOT BETWEEN 1 AND 120 OR coalesce(length(trim(p_goal)),0) NOT BETWEEN 1 AND 4000 OR coalesce(length(trim(p_acceptance)),0) NOT BETWEEN 1 AND 2000 OR coalesce(length(trim(p_integration)),0) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Project fields required' USING ERRCODE='22023';END IF;
 PERFORM private.validate_project_stages(p_stages);
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text || p_key::text,0));
 SELECT id INTO pid FROM public.company_projects WHERE created_by=uid AND request_key=p_key;
 IF pid IS NOT NULL THEN RETURN pid;END IF;
 SELECT jsonb_agg(jsonb_build_object('title',trim(s->>'title'),'acceptance',trim(s->>'acceptance'),'task_ids','[]'::jsonb,'state','pending') ORDER BY n) INTO clean FROM jsonb_array_elements(p_stages) WITH ORDINALITY x(s,n);
 INSERT INTO public.company_projects(created_by,request_key,title,goal,acceptance,integration_acceptance,stages) VALUES(uid,p_key,trim(p_title),trim(p_goal),trim(p_acceptance),trim(p_integration),clean) RETURNING id INTO pid;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'project.created','project',pid::text);
 RETURN pid;
END $$;

CREATE FUNCTION public.plan_company_project(p_project uuid,p_revision integer) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); p public.company_projects; plan uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.company_projects WHERE id=p_project AND created_by=uid FOR UPDATE;
 IF p.id IS NULL THEN RAISE EXCEPTION 'Project denied' USING ERRCODE='42501';END IF;
 IF p_revision IS DISTINCT FROM p.revision THEN RAISE EXCEPTION 'Stale project' USING ERRCODE='40001';END IF;
 IF p.plan_id IS NOT NULL THEN RETURN p.plan_id;END IF;
 plan:=public.create_work_plan(p.goal,p.acceptance,gen_random_uuid());
 -- Same transaction as enqueue: the worker sees the complete project criteria.
 UPDATE public.messages SET content=content || E'\n项目全流程验证条件：\n' || p.integration_acceptance
 WHERE id=(SELECT j.request_message_id FROM public.tasks w JOIN public.tasks j ON j.id=(w.result->>'current_job_id')::uuid WHERE w.id=plan AND w.created_by=uid AND j.created_by=uid);
 UPDATE public.company_projects SET plan_id=plan,revision=revision+1,updated_at=now() WHERE id=p.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'project.planning_requested','project',p.id::text,jsonb_build_object('plan_id',plan));
 RETURN plan;
END $$;

-- Attaches an existing COS plan; neither creates jobs nor approves its execution.
CREATE FUNCTION public.configure_company_project(p_project uuid,p_revision integer,p_plan uuid,p_stages jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); p public.company_projects; s jsonb; tid text; seen text[]:='{}'; clean jsonb:='[]';
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.company_projects WHERE id=p_project AND created_by=uid FOR UPDATE;
 IF p.id IS NULL THEN RAISE EXCEPTION 'Project denied' USING ERRCODE='42501';END IF;
 IF p_revision IS DISTINCT FROM p.revision THEN RAISE EXCEPTION 'Stale project' USING ERRCODE='40001';END IF;
 IF p.state='accepted' THEN RAISE EXCEPTION 'Accepted project immutable' USING ERRCODE='22023';END IF;
 IF p.plan_id IS NOT NULL AND p.plan_id IS DISTINCT FROM p_plan THEN RAISE EXCEPTION 'Project plan already bound' USING ERRCODE='22023';END IF;
 IF p_plan IS NULL OR NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=p_plan AND created_by=uid AND task_kind='work_plan' AND result->>'stage'='approved') THEN RAISE EXCEPTION 'Approved owned plan required' USING ERRCODE='22023';END IF;
 PERFORM private.validate_project_stages(p_stages);
 FOR s IN SELECT value FROM jsonb_array_elements(p_stages) LOOP
  IF jsonb_typeof(s->'task_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(s->'task_ids')>6 THEN RAISE EXCEPTION 'Invalid stage task binding' USING ERRCODE='22023';END IF;
  FOR tid IN SELECT jsonb_array_elements_text(s->'task_ids') LOOP
   IF tid=ANY(seen) OR NOT EXISTS(SELECT 1 FROM public.tasks WHERE id::text=tid AND created_by=uid AND task_kind='plan_assignment' AND input->>'plan_id'=p_plan::text) THEN RAISE EXCEPTION 'Task outside project plan or duplicated' USING ERRCODE='22023';END IF;
   seen:=array_append(seen,tid);
  END LOOP;
  clean:=clean || jsonb_build_array(jsonb_build_object('title',trim(s->>'title'),'acceptance',trim(s->>'acceptance'),'task_ids',s->'task_ids','state','pending'));
 END LOOP;
 -- No hidden plan assignments may be excluded from project acceptance.
 IF EXISTS(SELECT 1 FROM public.tasks WHERE created_by=uid AND task_kind='plan_assignment' AND input->>'plan_id'=p_plan::text AND NOT(id::text=ANY(seen))) OR cardinality(seen)=0 THEN RAISE EXCEPTION 'Map every plan assignment to exactly one stage' USING ERRCODE='22023';END IF;
 UPDATE public.company_projects SET plan_id=p_plan,stages=clean,state='active',integration_state='pending',revision=revision+1,updated_at=now() WHERE id=p.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'project.configured','project',p.id::text,jsonb_build_object('previous_revision',p.revision,'plan_id',p_plan));
 RETURN p.id;
END $$;

CREATE FUNCTION public.record_project_check(p_project uuid,p_revision integer,p_level text,p_stage integer,p_outcome text,p_evidence text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); p public.company_projects; s jsonb; tid text; assignment public.tasks; w public.tasks; i integer; evidence_tasks jsonb:='[]'; cid uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.company_projects WHERE id=p_project AND created_by=uid FOR UPDATE;
 IF p.id IS NULL THEN RAISE EXCEPTION 'Project denied' USING ERRCODE='42501';END IF;
 IF p_revision IS DISTINCT FROM p.revision THEN RAISE EXCEPTION 'Stale project' USING ERRCODE='40001';END IF;
 IF p.state IS DISTINCT FROM 'active' OR p.plan_id IS NULL THEN RAISE EXCEPTION 'Active configured project required' USING ERRCODE='22023';END IF;
 IF p_level IS NULL OR p_level NOT IN ('stage','integration','final') OR p_outcome IS NULL OR p_outcome NOT IN ('passed','failed') OR coalesce(length(trim(p_evidence)),0) NOT BETWEEN 1 AND 4000 OR (p_level='stage' AND (p_stage IS NULL OR p_stage<0 OR p_stage>=jsonb_array_length(p.stages))) OR (p_level<>'stage' AND p_stage IS NOT NULL) THEN RAISE EXCEPTION 'Invalid project check' USING ERRCODE='22023';END IF;
 IF p_outcome='passed' THEN
  IF p_level='stage' THEN
   FOR i IN 0..p_stage-1 LOOP
    IF p.stages->i->>'state' IS DISTINCT FROM 'passed' THEN RAISE EXCEPTION 'Previous stage not passed' USING ERRCODE='22023';END IF;
   END LOOP;
  ELSE
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(p.stages) x WHERE x->>'state' IS DISTINCT FROM 'passed') THEN RAISE EXCEPTION 'Stages not passed' USING ERRCODE='22023';END IF;
   IF p_level='final' AND p.integration_state IS DISTINCT FROM 'passed' THEN RAISE EXCEPTION 'End-to-end verification required' USING ERRCODE='22023';END IF;
  END IF;
 END IF;
 -- Pin task versions in evidence; completion is checked in the database, not the browser.
 FOR s IN SELECT value FROM jsonb_array_elements(p.stages) WITH ORDINALITY x(value,n) WHERE p_level<>'stage' OR n=p_stage+1 LOOP
  FOR tid IN SELECT jsonb_array_elements_text(s->'task_ids') LOOP
   SELECT * INTO assignment FROM public.tasks WHERE id::text=tid AND created_by=uid AND task_kind='plan_assignment' AND input->>'plan_id'=p.plan_id::text;
   SELECT * INTO w FROM public.tasks WHERE id=(assignment.result->>'work_order_id')::uuid AND created_by=uid AND task_kind='work_order';
   IF p_outcome='passed' AND (assignment.id IS NULL OR w.id IS NULL OR w.result->>'review_state' IS DISTINCT FROM 'accepted') THEN RAISE EXCEPTION 'Task delivery not accepted' USING ERRCODE='22023';END IF;
   evidence_tasks:=evidence_tasks || jsonb_build_array(jsonb_build_object('assignment_id',assignment.id,'work_order_id',w.id,'job_id',w.result->>'current_job_id','review_state',w.result->>'review_state'));
  END LOOP;
 END LOOP;
 INSERT INTO public.project_checks(project_id,created_by,project_revision,level,stage_index,outcome,evidence,snapshot)
 VALUES(p.id,uid,p.revision,p_level,p_stage,p_outcome,trim(p_evidence),jsonb_build_object('title',p.title,'goal',p.goal,'business_acceptance',p.acceptance,'integration_acceptance',p.integration_acceptance,'stages',p.stages,'plan_id',p.plan_id,'task_versions',evidence_tasks)) RETURNING id INTO cid;
 IF p_level='stage' THEN
  p.stages:=jsonb_set(p.stages,ARRAY[p_stage::text,'state'],to_jsonb(p_outcome));
  -- Rechecking upstream invalidates all downstream gates, preserving old reports as history.
  FOR i IN p_stage+1..jsonb_array_length(p.stages)-1 LOOP p.stages:=jsonb_set(p.stages,ARRAY[i::text,'state'],'"pending"');END LOOP;
  p.integration_state:='pending';
 ELSIF p_level='integration' THEN p.integration_state:=p_outcome;
 ELSIF p_outcome='passed' THEN p.state:='accepted';
 END IF;
 UPDATE public.company_projects SET stages=p.stages,integration_state=p.integration_state,state=p.state,revision=revision+1,updated_at=now() WHERE id=p.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'project.' || p_level || '.' || p_outcome,'project',p.id::text,jsonb_build_object('check_id',cid,'stage_index',p_stage));
 RETURN cid;
END $$;
REVOKE ALL ON FUNCTION private.validate_project_stages(jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.create_company_project(text,text,text,text,jsonb,uuid),public.plan_company_project(uuid,integer),public.configure_company_project(uuid,integer,uuid,jsonb),public.record_project_check(uuid,integer,text,integer,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.create_company_project(text,text,text,text,jsonb,uuid),public.plan_company_project(uuid,integer),public.configure_company_project(uuid,integer,uuid,jsonb),public.record_project_check(uuid,integer,text,integer,text,text) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
