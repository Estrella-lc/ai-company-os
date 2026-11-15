BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.document_jobs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),manager_agent_id uuid NOT NULL REFERENCES public.agents(id),request_key uuid NOT NULL,
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 120),profile text NOT NULL CHECK(profile IN ('pdf_extract_v1','docx_extract_v1','docx_create_v1')),
 state text NOT NULL DEFAULT 'uploading' CHECK(state IN ('uploading','waiting_skill','queued','running','succeeded','failed')),
 research_job_id uuid REFERENCES public.tasks(id),skill_id uuid REFERENCES public.agent_skills(id),
 attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count BETWEEN 0 AND 2),runner_id text,lease_token uuid,lease_expires_at timestamptz,available_at timestamptz NOT NULL DEFAULT now(),
 output_path text,result jsonb,review jsonb,last_error text,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz,
 UNIQUE(created_by,request_key),CHECK((state='running')=(lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),CHECK((state IN ('succeeded','failed'))=(finished_at IS NOT NULL)));
ALTER TABLE public.document_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.document_jobs FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.document_jobs TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public.document_jobs TO service_role;
CREATE POLICY document_ceo_read ON public.document_jobs FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('company-documents','company-documents',false,2097152,ARRAY['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain']);
CREATE POLICY document_input ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='company-documents' AND public.is_company_ceo(auth.uid()) AND EXISTS(SELECT 1 FROM public.document_jobs j WHERE j.created_by=auth.uid() AND j.state='uploading' AND name=j.created_by::text||'/'||j.id::text||'/input'));
CREATE POLICY document_output ON storage.objects FOR SELECT TO authenticated USING(bucket_id='company-documents' AND public.is_company_ceo(auth.uid()) AND EXISTS(SELECT 1 FROM public.document_jobs j WHERE j.created_by=auth.uid() AND (name=j.created_by::text||'/'||j.id::text||'/input' OR (j.state='succeeded' AND name=j.output_path))));

-- Extend only the first-party, fixed adapter's validation status. Downloaded skill scripts remain disabled.
DO $patch$
DECLARE definition text; old text;
BEGIN
 definition:=pg_get_functiondef('private.enqueue_skill_research(uuid,uuid,text,text,uuid,uuid)'::regprocedure);
 IF position('pdf|文档|document' IN definition)=0 THEN RAISE EXCEPTION 'Document classification changed';END IF;
 definition:=replace(definition,'pdf|文档|document','pdf|docx|文档|document');
 old:='AND agent_skills.capability=''subtitles'' AND p_need ~* ''srt|字幕烧录|字幕合成|已有字幕'' AND p_need !~* ''语音|转录|识别|transcrib|recogn''';
 IF position(old IN definition)=0 THEN RAISE EXCEPTION 'Reuse gate changed';END IF;
 EXECUTE replace(definition,old,'AND ((agent_skills.capability=''documents'' AND metadata->>''adapter''=''company_documents_v1'' AND verification->>''scope''=''document_processing_v1'' AND verification->>''passed''=''true'' AND p_need ~* ''pdf|docx|文档|document'' AND p_need !~* ''ocr|scan|layout|merge|encrypt|扫描|版式'') OR (true '||old||'))');
 definition:=pg_get_functiondef('public.pause_for_skill_search(uuid,uuid,text,jsonb)'::regprocedure);
 old:='research:=private.enqueue_skill_research';
 IF position(old IN definition)=0 THEN RAISE EXCEPTION 'Pause gate changed';END IF;
 EXECUTE replace(definition,old,'IF reuse_manager IS NULL AND p_query ~* ''pdf|docx|document'' AND p_query !~* ''ocr|scan|layout|merge|encrypt'' THEN SELECT manager_agent_id INTO reuse_manager FROM public.agent_skills WHERE created_by=j.created_by AND status=''verified_limited'' AND metadata->>''adapter''=''company_documents_v1'' AND verification->>''scope''=''document_processing_v1'' AND verification->>''passed''=''true'' ORDER BY created_at DESC LIMIT 1;END IF; '||old);
 definition:=pg_get_functiondef('public.finish_skill_research(uuid,uuid,text,jsonb,boolean)'::regprocedure);
 old:='WHEN j.input->>''capability''=''subtitles'' AND candidate->''verification''->>''passed''=''true'' AND candidate->''verification''->>''scope''=''subtitle_fixture_v1'' THEN ''verified_limited''';
 IF position(old IN definition)=0 THEN RAISE EXCEPTION 'Research verifier changed';END IF;
 EXECUTE replace(definition,old,old||' WHEN j.input->>''capability''=''documents'' AND candidate->>''repository''=''Estrella-lc/ai-company-os'' AND candidate->>''skill_path''=''skills/document-processing/SKILL.md'' AND candidate->''metadata''->>''adapter''=''company_documents_v1'' AND candidate->''verification''->>''scope''=''document_processing_v1'' AND candidate->''verification''->>''passed''=''true'' AND candidate->''verification''->>''passed_count''=''10'' AND candidate->''metadata''->>''requirements_sha256'' ~ ''^[a-f0-9]{64}$'' AND candidate->''verification''->''isolation'' @> ''{"network_disabled":true,"unprivileged":true,"root_read_only":true,"secrets_absent":true}''::jsonb AND candidate->''verification''->''profiles'' @> ''["pdf_extract_v1","docx_extract_v1","docx_create_v1"]''::jsonb THEN ''verified_limited''');
 definition:=pg_get_functiondef('private.finish_employee_skill_search()'::regprocedure);
 old:='a.capability=''subtitles'' AND a.verification->>''scope''=''subtitle_fixture_v1'' AND a.verification->>''passed''=''true''';
 IF position(old IN definition)=0 THEN RAISE EXCEPTION 'Skill lifecycle changed';END IF;
 EXECUTE replace(definition,old,'('||old||' OR (a.capability=''documents'' AND a.repository=''Estrella-lc/ai-company-os'' AND a.metadata->>''adapter''=''company_documents_v1'' AND a.verification->>''scope''=''document_processing_v1'' AND a.verification->>''passed''=''true'' AND r.query ~* ''pdf|docx|document'' AND r.query !~* ''ocr|scan|layout|merge|encrypt''))');
 FOREACH old IN ARRAY ARRAY['public.claim_skill_research(text)','public.claim_subtitle_job(text)'] LOOP
  definition:=pg_get_functiondef(old::regprocedure);
  IF position('''document.claimed''' IN definition)>0 OR position('''subtitle.claimed''' IN definition)=0 THEN RAISE EXCEPTION 'Claim budget changed';END IF;
  EXECUTE replace(definition,'''subtitle.claimed''','''subtitle.claimed'',''document.claimed''');
 END LOOP;
END $patch$;

CREATE FUNCTION public.create_document_job(p_manager uuid,p_title text,p_profile text,p_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); jid uuid;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 IF p_key IS NULL OR coalesce(length(trim(p_title)),0) NOT BETWEEN 1 AND 120 OR p_profile IS NULL OR p_profile NOT IN ('pdf_extract_v1','docx_extract_v1','docx_create_v1') OR NOT EXISTS(SELECT 1 FROM public.agents WHERE id=p_manager AND is_active AND code<>'COS') THEN RAISE EXCEPTION 'Invalid document job' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text||':documents',0));
 SELECT id INTO jid FROM public.document_jobs WHERE created_by=uid AND request_key=p_key;IF jid IS NOT NULL THEN RETURN jid;END IF;
 IF (SELECT count(*) FROM public.document_jobs WHERE created_by=uid AND created_at>=date_trunc('day',now()))>=5 OR (SELECT count(*) FROM public.document_jobs WHERE created_by=uid)>=10 THEN RAISE EXCEPTION 'Document storage cap' USING ERRCODE='22023';END IF;
 INSERT INTO public.document_jobs(created_by,manager_agent_id,title,profile,request_key) VALUES(uid,p_manager,trim(p_title),p_profile,p_key) RETURNING id INTO jid;RETURN jid;
END $$;
CREATE FUNCTION public.queue_document_job(p_task uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.document_jobs; skill uuid; research uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO j FROM public.document_jobs WHERE id=p_task AND created_by=auth.uid() FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Document denied' USING ERRCODE='42501';END IF;
 IF j.state<>'uploading' THEN RETURN true;END IF;
 IF NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-documents' AND name=j.created_by::text||'/'||j.id::text||'/input' AND (metadata->>'size')::bigint BETWEEN 1 AND 2097152) THEN RAISE EXCEPTION 'Input not uploaded' USING ERRCODE='22023';END IF;
 SELECT id INTO skill FROM public.agent_skills WHERE created_by=j.created_by AND status='verified_limited' AND metadata->>'adapter'='company_documents_v1' AND verification->>'scope'='document_processing_v1' AND verification->>'passed'='true' AND verification->'profiles' ? j.profile ORDER BY created_at DESC LIMIT 1;
 IF skill IS NULL THEN
  SELECT id INTO research FROM public.tasks WHERE created_by=j.created_by AND task_kind='skill_research' AND input->>'query'='pdf docx document processing' AND execution_state IN ('queued','running') ORDER BY created_at LIMIT 1;
  IF research IS NULL THEN research:=private.enqueue_skill_research(j.created_by,j.manager_agent_id,'文档处理能力：PDF文本提取、DOCX文本提取与生成','pdf docx document processing',NULL,j.id);END IF;
 END IF;
 UPDATE public.document_jobs SET state=CASE WHEN skill IS NULL THEN 'waiting_skill' ELSE 'queued' END,skill_id=skill,research_job_id=research,updated_at=now() WHERE id=j.id;
 RETURN true;
END $$;
CREATE FUNCTION private.resume_document_jobs() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.document_jobs; skill uuid;
BEGIN
 IF NEW.task_kind<>'skill_research' OR NEW.execution_state NOT IN ('succeeded','failed') THEN RETURN NEW;END IF;
 FOR j IN SELECT * FROM public.document_jobs WHERE research_job_id=NEW.id AND state='waiting_skill' FOR UPDATE LOOP
  SELECT id INTO skill FROM public.agent_skills WHERE created_by=j.created_by AND request_task_id=NEW.id AND status='verified_limited' AND metadata->>'adapter'='company_documents_v1' AND verification->>'scope'='document_processing_v1' AND verification->>'passed'='true' AND verification->'profiles' ? j.profile ORDER BY created_at DESC LIMIT 1;
  UPDATE public.document_jobs SET state=CASE WHEN skill IS NULL THEN 'failed' ELSE 'queued' END,skill_id=skill,last_error=CASE WHEN skill IS NULL THEN 'document_skill_unverified' ELSE NULL END,finished_at=CASE WHEN skill IS NULL THEN now() ELSE NULL END,updated_at=now() WHERE id=j.id;
 END LOOP;RETURN NEW;
END $$;
CREATE TRIGGER resume_document_jobs AFTER UPDATE OF execution_state ON public.tasks FOR EACH ROW EXECUTE FUNCTION private.resume_document_jobs();
CREATE FUNCTION public.claim_document_job(p_runner text) RETURNS SETOF public.document_jobs LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE jid uuid; token uuid;
BEGIN
 IF p_runner IS NULL OR p_runner !~ '^[0-9]+/[0-9]+$' THEN RAISE EXCEPTION 'Invalid runner' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('skill_daily_claim',0));
 UPDATE public.document_jobs SET state=CASE WHEN attempt_count<2 THEN 'queued' ELSE 'failed' END,lease_token=NULL,lease_expires_at=NULL,finished_at=CASE WHEN attempt_count=2 THEN now() ELSE NULL END,last_error='document_runner_interrupted',updated_at=now() WHERE state='running' AND lease_expires_at<=now();
 SELECT id INTO jid FROM public.document_jobs WHERE state='running' AND runner_id=p_runner AND lease_expires_at>now() LIMIT 1;
 IF jid IS NOT NULL THEN RETURN QUERY SELECT * FROM public.document_jobs WHERE id=jid;RETURN;END IF;
 IF (SELECT count(*) FROM public.audit_logs WHERE action IN ('skill_research.claimed','subtitle.claimed','document.claimed') AND created_at>=date_trunc('day',now()))>=3 THEN RETURN;END IF;
 SELECT j.id INTO jid FROM public.document_jobs j JOIN public.agent_skills s ON s.id=j.skill_id AND s.created_by=j.created_by WHERE j.state='queued' AND j.available_at<=now() AND j.attempt_count<2 AND s.status='verified_limited' AND s.metadata->>'adapter'='company_documents_v1' AND s.verification->>'passed'='true' AND s.verification->'profiles' ? j.profile ORDER BY j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
 IF jid IS NULL THEN RETURN;END IF;
 token:=gen_random_uuid();
 UPDATE public.document_jobs SET state='running',attempt_count=attempt_count+1,runner_id=p_runner,lease_token=token,lease_expires_at=now()+interval '10 minutes',output_path=created_by::text||'/'||id::text||'/'||token::text||'/result',updated_at=now() WHERE id=jid;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) VALUES('worker','document.claimed','document_job',jid::text);
 RETURN QUERY SELECT * FROM public.document_jobs WHERE id=jid;
END $$;
CREATE FUNCTION public.finish_document_job(p_task uuid,p_token uuid,p_runner text,p_report jsonb,p_failed boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE j public.document_jobs;
BEGIN
 SELECT * INTO j FROM public.document_jobs WHERE id=p_task FOR UPDATE;
 IF j.id IS NULL OR j.runner_id IS DISTINCT FROM p_runner OR (j.output_path IS NOT NULL AND split_part(j.output_path,'/',3) IS DISTINCT FROM p_token::text) THEN RETURN false;END IF;
 IF j.state IN ('succeeded','failed') THEN RETURN true;END IF;
 IF j.state<>'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false;END IF;
 IF jsonb_typeof(p_report) IS DISTINCT FROM 'object' OR length(p_report::text)>12000 THEN RAISE EXCEPTION 'Invalid document report' USING ERRCODE='22023';END IF;
 IF NOT p_failed AND (p_report->>'passed' IS DISTINCT FROM 'true' OR p_report->>'scope' IS DISTINCT FROM j.profile OR coalesce(p_report->>'output_sha256','') !~ '^[a-f0-9]{64}$' OR coalesce(p_report->>'input_sha256','') !~ '^[a-f0-9]{64}$' OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-documents' AND name=j.output_path AND (metadata->>'size')::bigint BETWEEN 1 AND 2097152 AND (metadata->>'size')::bigint=(p_report->>'output_bytes')::bigint)) THEN RAISE EXCEPTION 'Document output not verified' USING ERRCODE='22023';END IF;
 UPDATE public.document_jobs SET state=CASE WHEN p_failed THEN 'failed' ELSE 'succeeded' END,finished_at=now(),lease_token=NULL,lease_expires_at=NULL,result=p_report,last_error=CASE WHEN p_failed THEN 'document_processing_failed_or_unsupported' ELSE NULL END,updated_at=now() WHERE id=j.id;RETURN true;
END $$;
CREATE FUNCTION public.review_document_job(p_task uuid,p_action text,p_note text DEFAULT '') RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.document_jobs;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO j FROM public.document_jobs WHERE id=p_task AND created_by=auth.uid() FOR UPDATE;
 IF j.id IS NULL OR j.state<>'succeeded' OR p_action IS NULL OR p_action NOT IN ('accept','revise') OR length(coalesce(p_note,''))>2000 OR (p_action='revise' AND coalesce(length(trim(p_note)),0)=0) THEN RAISE EXCEPTION 'Invalid document review' USING ERRCODE='22023';END IF;
 IF j.review->>'state'='accepted' THEN IF p_action='accept' THEN RETURN true;END IF;RAISE EXCEPTION 'Already accepted' USING ERRCODE='40001';END IF;
 UPDATE public.document_jobs SET review=jsonb_build_object('state',CASE WHEN p_action='accept' THEN 'accepted' ELSE 'changes_requested' END,'note',trim(coalesce(p_note,'')),'reviewed_at',now()),updated_at=now() WHERE id=j.id;RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.create_document_job(uuid,text,text,uuid),public.queue_document_job(uuid),public.claim_document_job(text),public.finish_document_job(uuid,uuid,text,jsonb,boolean),public.review_document_job(uuid,text,text),private.resume_document_jobs() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.create_document_job(uuid,text,text,uuid),public.queue_document_job(uuid),public.review_document_job(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_document_job(text),public.finish_document_job(uuid,uuid,text,jsonb,boolean) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
