-- CEO review of an existing synthetic artifact; grants no new execution capability.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.review_skill_sample(p_task uuid,p_action text,p_note text DEFAULT '')
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); j public.tasks; previous jsonb; review jsonb;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501'; END IF;
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND created_by=uid AND task_kind='skill_research' FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Task denied' USING ERRCODE='42501'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('accept','revise') OR length(coalesce(p_note,''))>2000 OR (p_action='revise' AND coalesce(length(trim(p_note)),0)=0) THEN RAISE EXCEPTION 'Invalid review' USING ERRCODE='22023'; END IF;
 IF j.execution_state IS DISTINCT FROM 'succeeded' OR coalesce(j.result->>'run_url','') !~ '^https://github[.]com/Estrella-lc/ai-company-os/actions/runs/[0-9]+$' OR NOT EXISTS(
  SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(j.result->'candidates')='array' THEN j.result->'candidates' ELSE '[]'::jsonb END) c
  WHERE c->'verification'->>'passed'='true' AND c->'verification'->>'scope'='subtitle_fixture_v1' AND coalesce(c->'verification'->>'output_sha256','') ~ '^[0-9a-f]{64}$'
 ) THEN RAISE EXCEPTION 'No verified sample delivery' USING ERRCODE='22023'; END IF;
 previous:=j.result->'sample_review';
 IF previous->>'state'='accepted' THEN
  IF p_action='accept' THEN RETURN true; END IF;
  RAISE EXCEPTION 'Sample already accepted' USING ERRCODE='40001';
 END IF;
 IF previous->>'state'='changes_requested' AND p_action='revise' AND previous->>'note'=trim(p_note) THEN RETURN true; END IF;
 review:=jsonb_build_object('state',CASE WHEN p_action='accept' THEN 'accepted' ELSE 'changes_requested' END,'note',trim(coalesce(p_note,'')),'reviewed_at',now(),'reviewed_by',uid,'scope','subtitle_fixture_v1');
 UPDATE public.tasks SET result=jsonb_set(j.result,'{sample_review}',review),updated_at=now() WHERE id=j.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'skill_sample.' || p_action,'task',j.id::text,jsonb_build_object('scope','subtitle_fixture_v1'));
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.review_skill_sample(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.review_skill_sample(uuid,text,text) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
