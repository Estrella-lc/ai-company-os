-- Bounded company-authored SRT quality skill. Generated code runs only in a secret-free container.
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.ai_employees DROP CONSTRAINT ai_employees_role_check;
ALTER TABLE public.ai_employees ADD CONSTRAINT ai_employees_role_check CHECK(role IN ('skill_researcher','skill_executor','developer'));
CREATE TABLE public.development_jobs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),manager_agent_id uuid NOT NULL REFERENCES public.agents(id),employee_id uuid NOT NULL REFERENCES public.ai_employees(id),request_key uuid NOT NULL,
 title text NOT NULL DEFAULT '自主研发 SRT 字幕质检技能',profile text NOT NULL DEFAULT 'srt_quality_v1' CHECK(profile='srt_quality_v1'),state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','succeeded','failed')),
 execution_attempts integer NOT NULL DEFAULT 0 CHECK(execution_attempts BETWEEN 0 AND 3),runner_id text,lease_token uuid,lease_expires_at timestamptz,available_at timestamptz NOT NULL DEFAULT now(),result jsonb,last_error text,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz,
 UNIQUE(created_by,request_key),CHECK((state='running')=(lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),CHECK((state IN ('succeeded','failed'))=(finished_at IS NOT NULL)));
CREATE TABLE public.development_attempts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_id uuid NOT NULL REFERENCES public.development_jobs(id),number integer NOT NULL CHECK(number BETWEEN 1 AND 3),request_key uuid NOT NULL,generation_nonce uuid NOT NULL,
 state text NOT NULL DEFAULT 'generating' CHECK(state IN ('generating','candidate','tested','generation_failed')),source text CHECK(length(source)<=24000),source_sha256 text,model text,feedback jsonb NOT NULL DEFAULT '{}',test_report jsonb,usage jsonb,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(job_id,number),UNIQUE(job_id,request_key));
CREATE TABLE public.developed_skills(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),job_id uuid NOT NULL UNIQUE REFERENCES public.development_jobs(id),attempt_id uuid NOT NULL REFERENCES public.development_attempts(id),employee_id uuid NOT NULL REFERENCES public.ai_employees(id),
 name text NOT NULL DEFAULT 'SRT 字幕质检',profile text NOT NULL CHECK(profile='srt_quality_v1'),source text NOT NULL,source_sha256 text NOT NULL,verification jsonb NOT NULL,origin text NOT NULL DEFAULT 'company_developed' CHECK(origin='company_developed'),status text NOT NULL DEFAULT 'verified' CHECK(status IN ('verified','released')),created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.development_jobs ENABLE ROW LEVEL SECURITY;ALTER TABLE public.development_attempts ENABLE ROW LEVEL SECURITY;ALTER TABLE public.developed_skills ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.development_jobs,public.development_attempts,public.developed_skills FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.development_jobs,public.development_attempts,public.developed_skills TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public.development_jobs,public.development_attempts,public.developed_skills TO service_role;
CREATE POLICY dev_jobs_read ON public.development_jobs FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE POLICY dev_attempts_read ON public.development_attempts FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.development_jobs j WHERE j.id=job_id AND j.created_by=auth.uid() AND public.is_company_ceo(auth.uid())));
CREATE POLICY developed_skills_read ON public.developed_skills FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));

CREATE FUNCTION public.request_development(p_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); manager uuid; employee uuid; jid uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 IF p_key IS NULL THEN RAISE EXCEPTION 'Request key required' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text || ':development',0));
 SELECT id INTO jid FROM public.development_jobs WHERE created_by=uid AND request_key=p_key;IF jid IS NOT NULL THEN RETURN jid;END IF;
 IF (SELECT count(*) FROM public.development_jobs WHERE created_by=uid AND created_at>=now()-interval '1 day')>=3 THEN RAISE EXCEPTION 'Daily development request limit' USING ERRCODE='22023';END IF;
 SELECT id INTO manager FROM public.agents WHERE code='CTO' AND is_active;IF manager IS NULL THEN RAISE EXCEPTION 'Active CTO required' USING ERRCODE='22023';END IF;
 INSERT INTO public.ai_employees(created_by,manager_agent_id,name,role) VALUES(uid,manager,'CTO Python 技能研发员','developer') ON CONFLICT(created_by,manager_agent_id,role) DO UPDATE SET name=excluded.name RETURNING id INTO employee;
 INSERT INTO public.development_jobs(created_by,manager_agent_id,employee_id,request_key) VALUES(uid,manager,employee,p_key) RETURNING id INTO jid;RETURN jid;
END $$;
CREATE FUNCTION public.claim_development(p_runner text) RETURNS SETOF public.development_jobs LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE jid uuid;
BEGIN
 IF p_runner IS NULL OR p_runner !~ '^[0-9]+/[0-9]+$' THEN RAISE EXCEPTION 'Invalid runner' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('skill_daily_claim',0));
 UPDATE public.development_attempts SET state='generation_failed' WHERE state='generating' AND EXISTS(SELECT 1 FROM public.development_jobs j WHERE j.id=job_id AND j.state='running' AND j.lease_expires_at<=now());
 UPDATE public.development_jobs SET state=CASE WHEN execution_attempts<3 AND ((SELECT count(*) FROM public.development_attempts a WHERE a.job_id=development_jobs.id)<3 OR EXISTS(SELECT 1 FROM public.development_attempts a WHERE a.job_id=development_jobs.id AND a.state='candidate')) THEN 'queued' ELSE 'failed' END,
 finished_at=CASE WHEN execution_attempts>=3 OR ((SELECT count(*) FROM public.development_attempts a WHERE a.job_id=development_jobs.id)>=3 AND NOT EXISTS(SELECT 1 FROM public.development_attempts a WHERE a.job_id=development_jobs.id AND a.state='candidate')) THEN now() ELSE NULL END,lease_token=NULL,lease_expires_at=NULL,last_error='runner_interrupted',updated_at=now() WHERE state='running' AND lease_expires_at<=now();
 SELECT id INTO jid FROM public.development_jobs WHERE state='running' AND runner_id=p_runner AND lease_expires_at>now() LIMIT 1;
 IF jid IS NOT NULL THEN RETURN QUERY SELECT * FROM public.development_jobs WHERE id=jid;RETURN;END IF;
 IF (SELECT count(*) FROM public.audit_logs WHERE action IN ('skill_research.claimed','subtitle.claimed','development.claimed') AND created_at>=date_trunc('day',now()))>=3 THEN RETURN;END IF;
 SELECT id INTO jid FROM public.development_jobs WHERE state='queued' AND execution_attempts<3 AND available_at<=now() ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1;IF jid IS NULL THEN RETURN;END IF;
 UPDATE public.development_jobs SET state='running',runner_id=p_runner,execution_attempts=execution_attempts+1,lease_token=gen_random_uuid(),lease_expires_at=now()+interval '10 minutes',updated_at=now() WHERE id=jid;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker','development.claimed','development_job',jid::text);
 RETURN QUERY SELECT * FROM public.development_jobs WHERE id=jid;
END $$;
CREATE FUNCTION public.reserve_development_generation(p_task uuid,p_token uuid,p_runner text,p_key uuid,p_nonce uuid,p_feedback jsonb DEFAULT '{}') RETURNS SETOF public.development_attempts LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.development_jobs; aid uuid; n integer;
BEGIN
 SELECT * INTO j FROM public.development_jobs WHERE id=p_task FOR UPDATE;
 IF j.id IS NULL OR j.state<>'running' OR j.runner_id IS DISTINCT FROM p_runner OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RAISE EXCEPTION 'Lease denied' USING ERRCODE='42501';END IF;
 SELECT id INTO aid FROM public.development_attempts WHERE job_id=j.id AND request_key=p_key;IF aid IS NOT NULL THEN RETURN QUERY SELECT * FROM public.development_attempts WHERE id=aid;RETURN;END IF;
 SELECT count(*) INTO n FROM public.development_attempts WHERE job_id=j.id;
 IF n>=3 OR p_key IS NULL OR p_nonce IS NULL OR jsonb_typeof(p_feedback) IS DISTINCT FROM 'object' OR length(p_feedback::text)>6000 OR EXISTS(SELECT 1 FROM public.development_attempts WHERE job_id=j.id AND state IN ('generating','candidate')) THEN RAISE EXCEPTION 'Generation unavailable' USING ERRCODE='22023';END IF;
 INSERT INTO public.development_attempts(job_id,number,request_key,generation_nonce,feedback) VALUES(j.id,n+1,p_key,p_nonce,p_feedback) RETURNING id INTO aid;
 RETURN QUERY SELECT * FROM public.development_attempts WHERE id=aid;
END $$;
CREATE FUNCTION public.save_development_source(p_task uuid,p_attempt uuid,p_token uuid,p_runner text,p_source text,p_model text,p_usage jsonb) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.development_jobs;
BEGIN
 SELECT * INTO j FROM public.development_jobs WHERE id=p_task FOR UPDATE;
 IF j.id IS NULL OR j.state<>'running' OR j.runner_id IS DISTINCT FROM p_runner OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false;END IF;
 IF p_source IS NOT NULL AND length(p_source) NOT BETWEEN 1 AND 24000 THEN RAISE EXCEPTION 'Source size limit' USING ERRCODE='22023';END IF;
 UPDATE public.development_attempts SET state=CASE WHEN p_source IS NULL THEN 'generation_failed' ELSE 'candidate' END,source=p_source,source_sha256=CASE WHEN p_source IS NULL THEN NULL ELSE encode(sha256(convert_to(p_source,'UTF8')),'hex') END,model=left(p_model,100),usage=p_usage WHERE id=p_attempt AND job_id=j.id AND state='generating';RETURN FOUND;
END $$;
CREATE FUNCTION public.save_development_test(p_task uuid,p_attempt uuid,p_token uuid,p_runner text,p_report jsonb,p_run_url text) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.development_jobs; a public.development_attempts; passed boolean; skill uuid;
BEGIN
 SELECT * INTO j FROM public.development_jobs WHERE id=p_task FOR UPDATE;
 IF j.id IS NULL OR j.runner_id IS DISTINCT FROM p_runner THEN RETURN false;END IF;
 SELECT * INTO a FROM public.development_attempts WHERE id=p_attempt AND job_id=j.id;
 IF j.state IN ('succeeded','failed') AND a.state='tested' AND a.source_sha256=p_report->>'source_sha256' THEN RETURN true;END IF;
 IF j.state<>'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false;END IF;
 IF a.state='tested' THEN RETURN true;END IF;
 IF a.state IS DISTINCT FROM 'candidate' OR jsonb_typeof(p_report) IS DISTINCT FROM 'object' OR length(p_report::text)>15000 OR p_report->>'source_sha256' IS DISTINCT FROM a.source_sha256 OR p_report->>'harness_version' IS DISTINCT FROM 'srt_quality_v1' OR p_run_url !~ '^https://github[.]com/Estrella-lc/ai-company-os/actions/runs/[0-9]+$' THEN RAISE EXCEPTION 'Invalid test evidence' USING ERRCODE='22023';END IF;
 passed:=p_report->>'passed'='true' AND (p_report->>'case_count')::int>=22 AND (p_report->>'passed_count')::int=(p_report->>'case_count')::int AND p_report->>'isolation_passed'='true';
 UPDATE public.development_attempts SET state='tested',test_report=p_report || jsonb_build_object('run_url',p_run_url,'passed',coalesce(passed,false)) WHERE id=a.id;
 IF passed THEN
  INSERT INTO public.developed_skills(created_by,job_id,attempt_id,employee_id,profile,source,source_sha256,verification) VALUES(j.created_by,j.id,a.id,j.employee_id,j.profile,a.source,a.source_sha256,p_report || jsonb_build_object('run_url',p_run_url)) ON CONFLICT(job_id) DO NOTHING RETURNING id INTO skill;
  UPDATE public.development_jobs SET state='succeeded',finished_at=now(),lease_token=NULL,lease_expires_at=NULL,result=jsonb_build_object('summary','研发员工生成的源码通过限定SRT质检测试，等待CEO发布','skill_id',skill,'run_url',p_run_url),updated_at=now() WHERE id=j.id;
 ELSIF a.number=3 THEN
  UPDATE public.development_jobs SET state='failed',finished_at=now(),lease_token=NULL,lease_expires_at=NULL,last_error='acceptance_tests_failed',result=jsonb_build_object('run_url',p_run_url),updated_at=now() WHERE id=j.id;
 END IF;RETURN true;
END $$;
CREATE FUNCTION public.release_developed_skill(p_skill uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 UPDATE public.developed_skills SET status='released' WHERE id=p_skill AND created_by=auth.uid() AND verification->>'passed'='true';IF NOT FOUND THEN RAISE EXCEPTION 'Verified skill required' USING ERRCODE='22023';END IF;RETURN true;
END $$;
CREATE FUNCTION public.fail_development(p_task uuid,p_token uuid,p_runner text,p_terminal boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.development_jobs; terminal boolean;
BEGIN
 SELECT * INTO j FROM public.development_jobs WHERE id=p_task FOR UPDATE;
 IF j.id IS NULL OR j.state<>'running' OR j.runner_id IS DISTINCT FROM p_runner OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false;END IF;
 terminal:=p_terminal OR j.execution_attempts>=3 OR ((SELECT count(*) FROM public.development_attempts WHERE job_id=j.id)>=3 AND NOT EXISTS(SELECT 1 FROM public.development_attempts WHERE job_id=j.id AND state='candidate'));
 UPDATE public.development_attempts SET state='generation_failed' WHERE job_id=j.id AND state='generating';
 UPDATE public.development_jobs SET state=CASE WHEN terminal THEN 'failed' ELSE 'queued' END,finished_at=CASE WHEN terminal THEN now() ELSE NULL END,available_at=now()+interval '5 minutes',lease_token=NULL,lease_expires_at=NULL,last_error='development_execution_failed',updated_at=now() WHERE id=j.id;RETURN true;
END $$;
DO $$ DECLARE definition text; fn text;BEGIN
 FOREACH fn IN ARRAY ARRAY['public.claim_skill_research(text)','public.claim_subtitle_job(text)'] LOOP
  definition:=pg_get_functiondef(fn::regprocedure);
  definition:=replace(definition,'''skill_research.claimed'',''subtitle.claimed''','''skill_research.claimed'',''subtitle.claimed'',''development.claimed''');EXECUTE definition;
  IF position('''development.claimed''' IN definition)=0 THEN RAISE EXCEPTION 'Shared claim budget not updated';END IF;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.request_development(uuid),public.claim_development(text),public.reserve_development_generation(uuid,uuid,text,uuid,uuid,jsonb),public.save_development_source(uuid,uuid,uuid,text,text,text,jsonb),public.save_development_test(uuid,uuid,uuid,text,jsonb,text),public.release_developed_skill(uuid),public.fail_development(uuid,uuid,text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.request_development(uuid),public.release_developed_skill(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_development(text),public.reserve_development_generation(uuid,uuid,text,uuid,uuid,jsonb),public.save_development_source(uuid,uuid,uuid,text,text,text,jsonb),public.save_development_test(uuid,uuid,uuid,text,jsonb,text),public.fail_development(uuid,uuid,text,boolean) TO service_role;
NOTIFY pgrst,'reload schema';COMMIT;
