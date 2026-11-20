BEGIN;
ALTER TABLE public.company_goals ADD COLUMN revision_history jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(revision_history)='array');
CREATE FUNCTION public.revise_company_goal_voice(p_goal uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.company_goals;s public.tasks;v public.tasks;i public.tasks;report jsonb;j uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO g FROM public.company_goals WHERE id=p_goal AND created_by=auth.uid() FOR UPDATE;
 IF g.id IS NULL OR g.state<>'blocked' OR jsonb_array_length(g.revision_history)<>0 THEN RETURN false;END IF;
 SELECT * INTO s FROM public.tasks WHERE id=g.research_job AND created_by=g.created_by FOR UPDATE;
 SELECT * INTO i FROM public.tasks WHERE id=(g.review_jobs->>'image')::uuid AND created_by=g.created_by;
 SELECT * INTO v FROM public.tasks WHERE id=(g.review_jobs->>'voice')::uuid AND created_by=g.created_by;
 IF s.execution_state IS DISTINCT FROM 'succeeded' OR i.execution_state IS DISTINCT FROM 'succeeded' OR v.execution_state IS DISTINCT FROM 'succeeded' OR s.input->>'mode' IS DISTINCT FROM 'creative_samples' THEN RETURN false;END IF;
 IF i.input->>'creative_source_job' IS DISTINCT FROM s.id::text OR v.input->>'creative_source_job' IS DISTINCT FROM s.id::text THEN RETURN false;END IF;
 SELECT content::jsonb INTO report FROM public.messages WHERE reply_task_id=i.id;
 IF report->>'verdict' IS DISTINCT FROM 'pass' OR jsonb_array_length(report->'checks')<>3 OR EXISTS(SELECT 1 FROM jsonb_array_elements(report->'checks') c WHERE c->>'status' IS DISTINCT FROM 'pass') THEN RETURN false;END IF;
 SELECT content::jsonb INTO report FROM public.messages WHERE reply_task_id=v.id;
 IF report->>'verdict' IS DISTINCT FROM 'revise' OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(report->'checks') c WHERE c->>'id'='fidelity' AND c->>'status'='fail') THEN RETURN false;END IF;
 INSERT INTO public.tasks(title,description,task_kind,execution_state,created_by,assigned_agent_id,request_key,max_attempts,input)
 VALUES('配音保真返工 · '||left(g.title,80),'依据独立听检修复漏字；保留已通过图像、固定台词和原质检报告。仅一次质量返工，仍受共享每日三次领取限制。','skill_research','queued',g.created_by,s.assigned_agent_id,gen_random_uuid(),1,
 jsonb_build_object('mode','creative_samples','creative_goal_id',g.id,'capability','creative_samples','query','voice fidelity correction','employee_id',s.input->>'employee_id','revision_kind','voice_only','revision_parent',s.id,'reuse_manifest',s.result->'manifest','spec',g.selected_spec||jsonb_build_object('voice_only',true,'preserved_image',s.result->'verification'->'files'->'character.png'))) RETURNING id INTO j;
 UPDATE public.company_goals SET revision_history=jsonb_build_array(jsonb_build_object('research_job',s.id,'review_jobs',g.review_jobs,'last_error',g.last_error,'at',now())),research_job=j,state='researching',last_error=NULL,updated_at=now() WHERE id=g.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',auth.uid()::text,'goal.voice_revision_requested','company_goal',g.id::text,jsonb_build_object('parent_task',s.id,'revision_task',j,'revision_max_attempts',1,'preserve_image_sha256',s.result->'assets'->'image'->>'sha256'));
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.revise_company_goal_voice(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.revise_company_goal_voice(uuid) TO authenticated;
-- Only the image with its exact original hash is reused; the new voice is independently inspected.
DO $patch$
DECLARE d text;
BEGIN
 d:=pg_get_functiondef('public.advance_company_goals()'::regprocedure);
 IF position('GOAL_VOICE_REVISION_IMAGE' in d)>0 THEN RAISE EXCEPTION 'Already patched';END IF;
 d:=replace(d,$old$   jobs:='{}';
   FOREACH kind IN ARRAY ARRAY['image','voice'] LOOP
    jid:=private.goal_reply$old$,$new$   jobs:='{}';
   FOREACH kind IN ARRAY ARRAY['image','voice'] LOOP
    -- GOAL_VOICE_REVISION_IMAGE: original passing report stays tied to the unchanged image.
    IF kind='image' AND saved.input->>'revision_kind'='voice_only' THEN
     jobs:=jobs||jsonb_build_object('image',g.review_jobs->>'image');CONTINUE;
    END IF;
    jid:=private.goal_reply$new$);
 IF position('GOAL_VOICE_REVISION_IMAGE' in d)=0 THEN RAISE EXCEPTION 'Revision patch target missing';END IF;
 EXECUTE d;
END $patch$;
NOTIFY pgrst,'reload schema';
COMMIT;
