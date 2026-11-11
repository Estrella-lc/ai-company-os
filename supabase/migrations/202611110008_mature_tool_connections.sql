-- Mature package discovery and declarative invocation. Does not enable model-generated Python.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.company_integrations(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),request_task_id uuid NOT NULL REFERENCES public.tasks(id),
 name text NOT NULL,profile text NOT NULL CHECK(profile='subtitle_timeline_v1'),repository text NOT NULL,commit_sha text NOT NULL CHECK(commit_sha ~ '^[a-f0-9]{40}$'),
 package jsonb NOT NULL,manifest jsonb NOT NULL,verification jsonb NOT NULL,provenance jsonb NOT NULL,status text NOT NULL DEFAULT 'available' CHECK(status IN ('available','disabled')),created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.company_integrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_integrations FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.company_integrations TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public.company_integrations TO service_role;
CREATE POLICY company_integrations_read ON public.company_integrations FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE FUNCTION public.request_tool_connection(p_manager uuid,p_need text,p_key uuid,p_integration uuid DEFAULT NULL,p_srt text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); jid uuid; employee uuid; manager public.agents; shared public.company_integrations; mode text;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 IF p_key IS NULL OR coalesce(length(trim(p_need)),0) NOT BETWEEN 1 AND 4000 THEN RAISE EXCEPTION 'Invalid need' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text || ':technology',0));
 SELECT id INTO jid FROM public.tasks WHERE created_by=uid AND request_key=p_key AND task_kind='skill_research';IF jid IS NOT NULL THEN RETURN jid;END IF;
 IF p_integration IS NULL THEN SELECT id INTO jid FROM public.tasks WHERE created_by=uid AND task_kind='skill_research' AND input->>'mode'='technology_connect' AND execution_state IN ('queued','running') ORDER BY created_at LIMIT 1;IF jid IS NOT NULL THEN RETURN jid;END IF;END IF;
 SELECT * INTO manager FROM public.agents WHERE id=p_manager AND is_active;IF manager.id IS NULL THEN RAISE EXCEPTION 'Manager unavailable' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.tasks WHERE created_by=uid AND task_kind='skill_research' AND created_at>=date_trunc('day',now()))>=10 THEN RAISE EXCEPTION 'Daily request cap' USING ERRCODE='22023';END IF;
 INSERT INTO public.ai_employees(created_by,manager_agent_id,name,role) VALUES(uid,manager.id,manager.code || ' 技能研究与验证员','skill_researcher') ON CONFLICT(created_by,manager_agent_id,role) DO UPDATE SET name=excluded.name RETURNING id INTO employee;
 IF p_integration IS NOT NULL THEN
  SELECT * INTO shared FROM public.company_integrations WHERE id=p_integration AND created_by=uid AND status='available';
  IF shared.id IS NULL OR coalesce(length(p_srt),0) NOT BETWEEN 1 AND 65536 THEN RAISE EXCEPTION 'Shared skill or input unavailable' USING ERRCODE='22023';END IF;mode:='technology_execute';
 ELSE
  SELECT * INTO shared FROM public.company_integrations WHERE created_by=uid AND status='available' AND profile='subtitle_timeline_v1' ORDER BY created_at DESC LIMIT 1;mode:='technology_connect';
 END IF;
 INSERT INTO public.tasks(title,description,task_kind,created_by,assigned_agent_id,request_key,input,execution_state,finished_at,result)
 VALUES(CASE WHEN mode='technology_execute' THEN '调用公司共享技术 · ' ELSE '查找并接入成熟技术 · ' END || left(p_need,70),p_need,'skill_research',uid,manager.id,p_key,jsonb_build_object('mode',mode,'profile','subtitle_timeline_v1','query','subtitle parser language:Python','employee_id',employee,'integration_id',shared.id,'srt',CASE WHEN mode='technology_execute' THEN p_srt ELSE NULL END),CASE WHEN mode='technology_connect' AND shared.id IS NOT NULL THEN 'succeeded' ELSE 'queued' END,CASE WHEN mode='technology_connect' AND shared.id IS NOT NULL THEN now() ELSE NULL END,CASE WHEN mode='technology_connect' AND shared.id IS NOT NULL THEN jsonb_build_object('connection_status','reused','integration_id',shared.id,'summary','复用公司已验证的成熟工具连接；没有重复搜索或安装') ELSE NULL END) RETURNING id INTO jid;
 RETURN jid;
END $$;
CREATE FUNCTION public.technology_task_context(p_task uuid,p_token uuid,p_runner text) RETURNS SETOF public.tasks LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 RETURN QUERY SELECT * FROM public.tasks WHERE id=p_task AND task_kind='skill_research' AND input->>'mode' IN ('technology_connect','technology_execute') AND execution_state='running' AND lease_token=p_token AND lease_expires_at>now() AND input->>'runner_id'=p_runner;
END $$;
CREATE FUNCTION public.finish_technology_task(p_task uuid,p_token uuid,p_runner text,p_report jsonb,p_run_url text,p_failed boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.tasks; integration uuid; verified boolean;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='skill_research' AND input->>'mode' IN ('technology_connect','technology_execute') FOR UPDATE;
 IF j.id IS NULL OR j.input->>'runner_id' IS DISTINCT FROM p_runner THEN RETURN false;END IF;
 IF j.execution_state IN ('succeeded','failed') THEN RETURN true;END IF;
 IF j.execution_state<>'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false;END IF;
 IF jsonb_typeof(p_report) IS DISTINCT FROM 'object' OR length(p_report::text)>150000 OR coalesce(p_run_url,'') !~ '^https://github[.]com/Estrella-lc/ai-company-os/actions/runs/[0-9]+$' THEN RAISE EXCEPTION 'Invalid connection evidence' USING ERRCODE='22023';END IF;
 verified:=p_report->'verification'->>'passed'='true' AND p_report->'verification'->>'profile'='subtitle_timeline_v1' AND p_report->'verification'->>'isolation_passed'='true' AND (p_report->'verification'->>'case_count')::int>=8 AND p_report->'verification'->>'case_count'=p_report->'verification'->>'passed_count';
 IF NOT p_failed AND j.input->>'mode'='technology_connect' AND p_report->>'connection_status'='connected' THEN
  IF verified IS DISTINCT FROM true OR coalesce(p_report->>'commit_sha','') !~ '^[a-f0-9]{40}$' OR coalesce(p_report->'package'->>'sha256','') !~ '^[a-f0-9]{64}$' OR jsonb_typeof(p_report->'manifest') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Connection not verified' USING ERRCODE='22023';END IF;
  INSERT INTO public.company_integrations(created_by,request_task_id,name,profile,repository,commit_sha,package,manifest,verification,provenance) VALUES(j.created_by,j.id,left(p_report->'package'->>'name',100),'subtitle_timeline_v1',p_report->>'repository',p_report->>'commit_sha',p_report->'package',p_report->'manifest',p_report->'verification',jsonb_build_object('origin','mature_open_source','connection','employee_discovered_and_connected','license',p_report->>'license','run_url',p_run_url,'connector_built_by','Codex','planning_model',p_report->>'planning_model')) RETURNING id INTO integration;
 ELSIF NOT p_failed AND j.input->>'mode'='technology_execute' THEN
  IF NOT EXISTS(SELECT 1 FROM public.company_integrations WHERE id=(j.input->>'integration_id')::uuid AND created_by=j.created_by AND status='available') OR jsonb_typeof(p_report->'events') IS DISTINCT FROM 'array' OR jsonb_array_length(p_report->'events')>200 THEN RAISE EXCEPTION 'Invalid shared invocation' USING ERRCODE='22023';END IF;
  integration:=(j.input->>'integration_id')::uuid;
 ELSIF NOT p_failed AND p_report->>'connection_status' IS DISTINCT FROM 'blocked' THEN RAISE EXCEPTION 'Unknown connection result' USING ERRCODE='22023';END IF;
 UPDATE public.tasks SET execution_state=CASE WHEN p_failed THEN 'failed' ELSE 'succeeded' END,finished_at=now(),lease_token=NULL,lease_expires_at=NULL,result=p_report || jsonb_build_object('integration_id',integration,'run_url',p_run_url),last_error_code=CASE WHEN p_failed THEN 'technology_connection_failed' ELSE NULL END,updated_at=now() WHERE id=j.id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.request_tool_connection(uuid,text,uuid,uuid,text),public.technology_task_context(uuid,uuid,text),public.finish_technology_task(uuid,uuid,text,jsonb,text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.request_tool_connection(uuid,text,uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.technology_task_context(uuid,uuid,text),public.finish_technology_task(uuid,uuid,text,jsonb,text,boolean) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
