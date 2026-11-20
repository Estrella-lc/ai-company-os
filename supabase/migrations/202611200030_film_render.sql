-- Deploy together with film-bridge.ts and the film runner. No quota increases.
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.film_workflows ADD COLUMN render_job uuid REFERENCES public.tasks(id);
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('company-films','company-films',false,20971520,ARRAY['video/mp4']);
CREATE POLICY film_output_owner ON storage.objects FOR SELECT TO authenticated USING(
 bucket_id='company-films' AND public.is_company_ceo(auth.uid()) AND EXISTS(
 SELECT 1 FROM public.film_workflows f JOIN public.tasks j ON j.id=f.render_job
 WHERE f.created_by=auth.uid() AND j.created_by=f.created_by AND j.execution_state='succeeded' AND name=j.result->>'output_path'));
CREATE FUNCTION public.request_film_render(p_goal uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE f public.film_workflows;g public.company_goals;manager uuid;j uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO f FROM public.film_workflows WHERE goal_id=p_goal AND created_by=auth.uid() FOR UPDATE;
 SELECT * INTO g FROM public.company_goals WHERE id=p_goal AND created_by=auth.uid();
 IF f.id IS NULL OR f.state<>'ready' OR g.state IS DISTINCT FROM 'accepted' OR g.research_job IS DISTINCT FROM f.source_job THEN RAISE EXCEPTION 'Approved film source required' USING ERRCODE='42501';END IF;
 IF f.render_job IS NOT NULL THEN RETURN f.render_job;END IF;
 SELECT id INTO manager FROM public.agents WHERE code='CTO' AND is_active LIMIT 1;
 IF manager IS NULL THEN RAISE EXCEPTION 'CTO unavailable';END IF;
 INSERT INTO public.tasks(title,description,task_kind,created_by,assigned_agent_id,request_key,input,execution_state,max_attempts)
 VALUES('员工剪辑 · 已审核分镜','固定 FFmpeg 适配器；技术合成不代表成片质检通过','skill_research',f.created_by,manager,gen_random_uuid(),jsonb_build_object('mode','film_render','film_workflow_id',f.id,'capability','video'), 'queued',2) RETURNING id INTO j;
 UPDATE public.film_workflows SET render_job=j WHERE id=f.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',auth.uid()::text,'film.render_requested','task',j::text);
 RETURN j;
END $$;
CREATE FUNCTION public.film_task_context(p_task uuid,p_token uuid,p_runner text) RETURNS SETOF public.film_workflows LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT f.* FROM public.film_workflows f JOIN public.tasks j ON j.id=f.render_job AND j.created_by=f.created_by
 JOIN public.company_goals g ON g.id=f.goal_id AND g.created_by=f.created_by AND g.research_job=f.source_job
 WHERE j.id=p_task AND j.task_kind='skill_research' AND j.input->>'mode'='film_render' AND j.input->>'film_workflow_id'=f.id::text
 AND f.state='ready' AND g.state='accepted' AND j.execution_state='running' AND j.lease_token=p_token AND j.lease_expires_at>now() AND j.input->>'runner_id'=p_runner;
$$;
CREATE FUNCTION public.finish_film_render(p_task uuid,p_token uuid,p_runner text,p_report jsonb,p_failed boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE f public.film_workflows;j public.tasks;path text;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task FOR UPDATE;
 SELECT * INTO f FROM public.film_task_context(p_task,p_token,p_runner);
 IF f.id IS NULL THEN RETURN false;END IF;
 path:=f.created_by::text||'/'||j.id::text||'/'||p_token::text||'/sample.mp4';
 IF NOT p_failed AND (p_report->>'technical_passed' IS DISTINCT FROM 'true' OR p_report->>'scope' IS DISTINCT FROM 'still_image_edit_v1'
 OR p_report->>'output_path' IS DISTINCT FROM path OR coalesce(p_report->>'sha256','') !~ '^[a-f0-9]{64}$'
 OR p_report->>'independent_film_review' IS DISTINCT FROM 'required' OR p_report->>'ceo_acceptance' IS DISTINCT FROM 'false'
 OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-films' AND name=path AND (metadata->>'size')::bigint BETWEEN 1 AND 20971520 AND (metadata->>'size')::bigint=(p_report->>'bytes')::bigint)) THEN RAISE EXCEPTION 'Film evidence invalid';END IF;
 UPDATE public.tasks SET execution_state=CASE WHEN p_failed AND attempt_count<max_attempts THEN 'queued' WHEN p_failed THEN 'failed' ELSE 'succeeded' END,
 available_at=now()+interval '5 minutes',finished_at=CASE WHEN p_failed AND attempt_count<max_attempts THEN NULL ELSE now() END,
 result=CASE WHEN p_failed THEN jsonb_build_object('error','film_execution_failed') ELSE p_report||jsonb_build_object('lease_token',p_token) END,
 lease_token=NULL,lease_expires_at=NULL,last_error_code=CASE WHEN p_failed THEN 'film_execution_failed' ELSE NULL END,updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker',CASE WHEN p_failed THEN 'film.execution_failed' ELSE 'film.technical_completed' END,'task',j.id::text);
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.request_film_render(uuid),public.film_task_context(uuid,uuid,text),public.finish_film_render(uuid,uuid,text,jsonb,boolean) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.request_film_render(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.film_task_context(uuid,uuid,text),public.finish_film_render(uuid,uuid,text,jsonb,boolean) TO service_role;
COMMIT;

