-- Pending explicit activation: private user media is processed on the approved GitHub runner.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.subtitle_jobs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),manager_agent_id uuid NOT NULL REFERENCES public.agents(id),request_key uuid NOT NULL,
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 120),state text NOT NULL DEFAULT 'uploading' CHECK(state IN ('uploading','queued','running','succeeded','failed')),
 attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count BETWEEN 0 AND 3),runner_id text,lease_token uuid,lease_expires_at timestamptz,available_at timestamptz NOT NULL DEFAULT now(),
 output_path text,result jsonb,review jsonb,last_error text,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz,
 UNIQUE(created_by,request_key),CHECK((state='running')=(lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),CHECK((state IN ('succeeded','failed'))=(finished_at IS NOT NULL)));
ALTER TABLE public.subtitle_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.subtitle_jobs FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.subtitle_jobs TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public.subtitle_jobs TO service_role;
CREATE POLICY subtitle_ceo_read ON public.subtitle_jobs FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('company-media','company-media',false,20971520,ARRAY['video/mp4','application/x-subrip','text/plain','application/json']);
CREATE POLICY subtitle_media_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='company-media' AND public.is_company_ceo(auth.uid()) AND EXISTS(SELECT 1 FROM public.subtitle_jobs j WHERE j.created_by=auth.uid() AND (name=j.created_by::text || '/' || j.id::text || '/input.mp4' OR name=j.created_by::text || '/' || j.id::text || '/input.srt' OR (j.state='succeeded' AND name=j.output_path))));
CREATE POLICY subtitle_media_input ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='company-media' AND public.is_company_ceo(auth.uid()) AND EXISTS(SELECT 1 FROM public.subtitle_jobs j WHERE j.created_by=auth.uid() AND j.state='uploading' AND (name=j.created_by::text || '/' || j.id::text || '/input.mp4' OR name=j.created_by::text || '/' || j.id::text || '/input.srt')));

CREATE FUNCTION public.create_subtitle_job(p_manager uuid,p_title text,p_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); jid uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 IF p_key IS NULL OR coalesce(length(trim(p_title)),0) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text || ':subtitle',0));
 SELECT id INTO jid FROM public.subtitle_jobs WHERE created_by=uid AND request_key=p_key;IF jid IS NOT NULL THEN RETURN jid;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.agents a JOIN public.agent_skills s ON s.manager_agent_id=a.id WHERE a.id=p_manager AND a.is_active AND s.created_by=uid AND s.status='verified_limited' AND s.verification->>'scope'='subtitle_fixture_v1') THEN RAISE EXCEPTION 'Verified manager required' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.subtitle_jobs WHERE created_by=uid AND created_at>=now()-interval '1 day')>=5 OR (SELECT count(*) FROM public.subtitle_jobs WHERE created_by=uid)>=10 THEN RAISE EXCEPTION 'Storage/request cap reached' USING ERRCODE='22023';END IF;
 INSERT INTO public.subtitle_jobs(created_by,manager_agent_id,title,request_key) VALUES(uid,p_manager,trim(p_title),p_key) RETURNING id INTO jid;
 RETURN jid;
END $$;
CREATE FUNCTION public.queue_subtitle_job(p_task uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.subtitle_jobs; prefix text;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO j FROM public.subtitle_jobs WHERE id=p_task AND created_by=auth.uid() FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Task denied' USING ERRCODE='42501';END IF;
 IF j.state<>'uploading' THEN RETURN true;END IF;
 prefix:=j.created_by::text || '/' || j.id::text || '/';
 IF NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-media' AND name=prefix || 'input.mp4' AND (metadata->>'size')::bigint BETWEEN 1 AND 20971520) OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-media' AND name=prefix || 'input.srt' AND (metadata->>'size')::bigint BETWEEN 1 AND 65536) THEN RAISE EXCEPTION 'Input files not ready' USING ERRCODE='22023';END IF;
 UPDATE public.subtitle_jobs SET state='queued',updated_at=now() WHERE id=j.id;RETURN true;
END $$;
CREATE FUNCTION public.claim_subtitle_job(p_runner text) RETURNS SETOF public.subtitle_jobs LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE jid uuid; token uuid;
BEGIN
 IF p_runner IS NULL OR p_runner !~ '^[0-9]+/[0-9]+$' THEN RAISE EXCEPTION 'Invalid runner' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('skill_daily_claim',0));
 UPDATE public.subtitle_jobs SET state=CASE WHEN attempt_count<3 THEN 'queued' ELSE 'failed' END,lease_token=NULL,lease_expires_at=NULL,finished_at=CASE WHEN attempt_count=3 THEN now() ELSE NULL END,last_error='runner_interrupted',updated_at=now() WHERE state='running' AND lease_expires_at<=now();
 SELECT id INTO jid FROM public.subtitle_jobs WHERE state='running' AND runner_id=p_runner AND lease_expires_at>now() LIMIT 1;
 IF jid IS NOT NULL THEN RETURN QUERY SELECT * FROM public.subtitle_jobs WHERE id=jid;RETURN;END IF;
 IF (SELECT count(*) FROM public.audit_logs WHERE action IN ('skill_research.claimed','subtitle.claimed') AND created_at>=date_trunc('day',now()))>=3 THEN RETURN;END IF;
 SELECT id INTO jid FROM public.subtitle_jobs WHERE state='queued' AND available_at<=now() AND attempt_count<3 ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1;
 IF jid IS NULL THEN RETURN;END IF;
 token:=gen_random_uuid();
 UPDATE public.subtitle_jobs SET state='running',attempt_count=attempt_count+1,runner_id=p_runner,lease_token=token,lease_expires_at=now()+interval '10 minutes',output_path=created_by::text || '/' || id::text || '/' || token::text || '/subtitled.mp4',updated_at=now() WHERE id=jid;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker','subtitle.claimed','subtitle_job',jid::text);
 RETURN QUERY SELECT * FROM public.subtitle_jobs WHERE id=jid;
END $$;
CREATE FUNCTION public.finish_subtitle_job(p_task uuid,p_token uuid,p_runner text,p_report jsonb,p_failed boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.subtitle_jobs;
BEGIN
 SELECT * INTO j FROM public.subtitle_jobs WHERE id=p_task FOR UPDATE;
 IF j.id IS NULL OR j.runner_id IS DISTINCT FROM p_runner THEN RETURN false;END IF;
 IF j.state IN ('succeeded','failed') THEN RETURN true;END IF;
 IF j.state<>'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false;END IF;
 IF jsonb_typeof(p_report) IS DISTINCT FROM 'object' OR length(p_report::text)>10000 THEN RAISE EXCEPTION 'Invalid report' USING ERRCODE='22023';END IF;
 IF p_failed THEN
  UPDATE public.subtitle_jobs SET state=CASE WHEN attempt_count<3 THEN 'queued' ELSE 'failed' END,finished_at=CASE WHEN attempt_count=3 THEN now() ELSE NULL END,available_at=now()+interval '5 minutes',lease_token=NULL,lease_expires_at=NULL,last_error='subtitle_execution_failed',updated_at=now() WHERE id=j.id;RETURN true;
 END IF;
 IF p_report->>'scope' IS DISTINCT FROM 'subtitle_delivery_v1' OR p_report->>'passed' IS DISTINCT FROM 'true' OR coalesce(p_report->>'output_sha256','') !~ '^[0-9a-f]{64}$' OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-media' AND name=j.output_path AND (metadata->>'size')::bigint BETWEEN 1 AND 20971520) THEN RAISE EXCEPTION 'Output not verified' USING ERRCODE='22023';END IF;
 UPDATE public.subtitle_jobs SET state='succeeded',finished_at=now(),lease_token=NULL,lease_expires_at=NULL,result=p_report,last_error=NULL,updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker','subtitle.finished','subtitle_job',j.id::text);RETURN true;
END $$;
CREATE FUNCTION public.review_subtitle_job(p_task uuid,p_action text,p_note text DEFAULT '') RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.subtitle_jobs;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO j FROM public.subtitle_jobs WHERE id=p_task AND created_by=auth.uid() FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Task denied' USING ERRCODE='42501';END IF;
 IF j.state<>'succeeded' OR p_action IS NULL OR p_action NOT IN ('accept','revise') OR length(coalesce(p_note,''))>2000 OR (p_action='revise' AND coalesce(length(trim(p_note)),0)=0) THEN RAISE EXCEPTION 'Invalid review' USING ERRCODE='22023';END IF;
 IF j.review->>'state'='accepted' THEN IF p_action='accept' THEN RETURN true;END IF;RAISE EXCEPTION 'Already accepted' USING ERRCODE='40001';END IF;
 IF j.review->>'state'='changes_requested' AND p_action='revise' AND j.review->>'note'=trim(p_note) THEN RETURN true;END IF;
 UPDATE public.subtitle_jobs SET review=jsonb_build_object('state',CASE WHEN p_action='accept' THEN 'accepted' ELSE 'changes_requested' END,'note',trim(coalesce(p_note,'')),'reviewed_at',now()),updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',auth.uid()::text,'subtitle.' || p_action,'subtitle_job',j.id::text);RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.create_subtitle_job(uuid,text,uuid),public.queue_subtitle_job(uuid),public.claim_subtitle_job(text),public.finish_subtitle_job(uuid,uuid,text,jsonb,boolean),public.review_subtitle_job(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_subtitle_job(uuid,text,uuid),public.queue_subtitle_job(uuid),public.review_subtitle_job(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_subtitle_job(text),public.finish_subtitle_job(uuid,uuid,text,jsonb,boolean) TO service_role;
-- Share the existing three-claim budget across research and real media work.
DO $$ DECLARE definition text;BEGIN
 definition:=pg_get_functiondef('public.claim_skill_research(text)'::regprocedure);
 IF position('action=''skill_research.claimed''' IN definition)=0 THEN RAISE EXCEPTION 'Research claim definition changed';END IF;
 EXECUTE replace(definition,'action=''skill_research.claimed''','action IN (''skill_research.claimed'',''subtitle.claimed'')');
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
