BEGIN;
DO $test$
DECLARE ceo uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135'; cpo uuid; cmo uuid; w uuid; source uuid; research uuid; token uuid:=gen_random_uuid(); i int; candidate jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',ceo::text,true);
 SELECT id INTO cpo FROM public.agents WHERE code='CPO';SELECT id INTO cmo FROM public.agents WHERE code='CMO';
 -- Transaction-local isolation; all existing status values are restored by ROLLBACK.
 UPDATE public.agent_skills SET status='needs_setup' WHERE created_by=ceo AND status='verified_limited' AND capability='subtitles';
 FOR i IN 1..3 LOOP
  w:=public.create_work_order('SKILL GAP ROLLBACK '||i,'已有SRT字幕烧录能力缺口','必须有适用验证',CASE WHEN i=3 THEN cmo ELSE cpo END,gen_random_uuid());
  SELECT (result->>'current_job_id')::uuid INTO source FROM public.tasks WHERE id=w;
  UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=source;
  BEGIN PERFORM public.pause_for_skill_search(source,gen_random_uuid(),'srt subtitle burn','[]');RAISE EXCEPTION 'Wrong lease allowed';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
  research:=public.pause_for_skill_search(source,token,'srt subtitle burn','[]');
  IF public.pause_for_skill_search(source,token,'srt subtitle burn','[]')<>research THEN RAISE EXCEPTION 'Duplicate research';END IF;
  IF EXISTS(SELECT 1 FROM public.messages WHERE reply_task_id=source) OR EXISTS(SELECT 1 FROM public.quality_reviews WHERE source_job_id=source) THEN RAISE EXCEPTION 'Search treated as delivery';END IF;
  IF i<3 THEN
   UPDATE public.tasks SET execution_state='running',attempt_count=1,input=input||'{"runner_id":"999/999"}'::jsonb,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=research;
   candidate:=jsonb_build_object('repository','fixture/skills','commit_sha',repeat('a',40),'skill_path','SKILL.md','name','srt-fixture','document','Synthetic skill fixture','metadata',jsonb_build_object('license','MIT'),'verification',jsonb_build_object('passed',true,'scope','subtitle_fixture_v1'));
   PERFORM public.finish_skill_research(research,token,'999/999',jsonb_build_object('candidates',CASE WHEN i=1 THEN '[]'::jsonb ELSE jsonb_build_array(candidate) END),false);
  END IF;
  IF i=1 AND NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=source AND execution_state='failed' AND last_error_code='skill_search_unverified') THEN RAISE EXCEPTION 'Unverified skill resumed work';END IF;
  IF i>1 AND NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=source AND execution_state='queued' AND available_at<now()+interval '1 minute' AND input->>'skill_search_enabled'='false' AND jsonb_array_length(input->'validated_skill_context')>0) THEN RAISE EXCEPTION 'Validated capability not reused';END IF;
  IF i=3 AND NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=research AND result->>'reused'='true') THEN RAISE EXCEPTION 'Cross-manager reuse failed';END IF;
  IF i=2 THEN
   UPDATE public.tasks SET execution_state='running',attempt_count=2,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=source;
   PERFORM public.complete_chat_reply(source,token,'已发现通过有限SRT字幕样例验证的技能，未处理用户视频。','[]');
   IF NOT EXISTS(SELECT 1 FROM public.quality_reviews WHERE source_job_id=source AND jsonb_array_length(snapshot->'validated_company_skills')>0 AND NOT (snapshot->'validated_company_skills'->0)?'document') THEN RAISE EXCEPTION 'Verified skill metadata missing from independent quality';END IF;
  END IF;
  IF (SELECT result->>'review_state' FROM public.tasks WHERE id=w)='accepted' THEN RAISE EXCEPTION 'Search accepted business task';END IF;
 END LOOP;
 IF has_function_privilege('authenticated','public.pause_for_skill_search(uuid,uuid,text,jsonb)','EXECUTE') OR has_table_privilege('authenticated','public.task_skill_requests','UPDATE') THEN RAISE EXCEPTION 'Excess access';END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
END $test$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.task_skill_requests) THEN RAISE EXCEPTION 'RLS leak';END IF;END $$;
RESET ROLE;
ROLLBACK;
SELECT 'PASS: source lease, idempotent pause, no false delivery, failed verification, verified resumption, cross-manager reuse, acceptance protection and RLS; rolled back' AS checks;
