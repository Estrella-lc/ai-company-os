-- Run in a disposable DB or before live runner activation; all fixtures roll back.
BEGIN;
DO $test$
DECLARE ceo uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135'; a uuid; k uuid:=gen_random_uuid(); j uuid; j2 uuid; c public.tasks; p uuid; job uuid; tok uuid:=gen_random_uuid(); report jsonb; n integer;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',ceo::text,true);
 SELECT id INTO a FROM public.agents WHERE code='COS';
 j:=public.request_skill_research(a,'测试SRT字幕合成','subtitle agent skills',k);
 IF j IS DISTINCT FROM public.request_skill_research(a,'测试SRT字幕合成','subtitle agent skills',k) THEN RAISE EXCEPTION 'Duplicate research'; END IF;
 SELECT count(*) INTO n FROM public.ai_employees WHERE created_by=ceo AND manager_agent_id=a;
 IF n<>1 THEN RAISE EXCEPTION 'Employee not recruited exactly once'; END IF;
 SELECT * INTO c FROM public.claim_skill_research('900001/1');
 IF c.id<>j OR c.attempt_count<>1 THEN RAISE EXCEPTION 'Claim failed'; END IF;
 IF c.id IS DISTINCT FROM (SELECT id FROM public.claim_skill_research('900001/1')) THEN RAISE EXCEPTION 'Duplicate claim'; END IF;
 report:=jsonb_build_object('summary','fixture','candidates',jsonb_build_array(jsonb_build_object('repository','example/skills','commit_sha',repeat('a',40),'skill_path','skills/subtitles/SKILL.md','name','subtitle-test','document',E'---\nname: subtitle-test\ndescription: test\n---\nSRT subtitles','metadata',jsonb_build_object('license','MIT'),'verification',jsonb_build_object('passed',false,'scope','static_review_only'))));
 IF public.finish_skill_research(c.id,gen_random_uuid(),'900001/1',report) THEN RAISE EXCEPTION 'Wrong lease accepted'; END IF;
 IF NOT public.finish_skill_research(c.id,c.lease_token,'900001/1',report) THEN RAISE EXCEPTION 'Finish failed'; END IF;
 IF EXISTS(SELECT 1 FROM public.agent_skills WHERE request_task_id=j AND status='verified_limited') THEN RAISE EXCEPTION 'Static review claimed runtime capability'; END IF;
 j2:=public.request_skill_research(a,'再测SRT字幕合成','subtitle agent skills',gen_random_uuid());
 SELECT * INTO c FROM public.claim_skill_research('900002/1');
 report:=jsonb_set(report,'{candidates,0,verification}','{"passed":true,"scope":"subtitle_fixture_v1"}');
 PERFORM public.finish_skill_research(c.id,c.lease_token,'900002/1',report);
 PERFORM public.finish_skill_research(c.id,c.lease_token,'900002/1',report);
 IF (SELECT count(*) FROM public.agent_skills WHERE created_by=ceo AND manager_agent_id=a)<>1 THEN RAISE EXCEPTION 'Library duplicate'; END IF;
 j:=public.request_skill_research(a,'复用已有SRT字幕合成','',gen_random_uuid());
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND execution_state='succeeded' AND result->>'reused'='true') THEN RAISE EXCEPTION 'Verified scope not reused'; END IF;
 j:=public.request_skill_research(a,'语音识别字幕','',gen_random_uuid());
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=j AND execution_state='queued') THEN RAISE EXCEPTION 'SRT test was mistaken for speech recognition'; END IF;
 SELECT * INTO c FROM public.claim_skill_research('900003/1');
 UPDATE public.tasks SET lease_expires_at=now()-interval '1 second' WHERE id=c.id;
 PERFORM public.claim_skill_research('900004/1');
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=c.id AND execution_state='queued' AND lease_token IS NULL) THEN RAISE EXCEPTION 'Interrupted worker not recovered'; END IF;
 IF EXISTS(SELECT 1 FROM public.claim_skill_research('900005/1')) THEN RAISE EXCEPTION 'Daily cap not enforced'; END IF;
 p:=public.create_work_plan('自动研究字幕工具 TEST','只规划',gen_random_uuid());
 SELECT (result->>'current_job_id')::uuid INTO job FROM public.tasks WHERE id=p;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=tok,lease_expires_at=now()+interval '90 seconds' WHERE id=job;
 PERFORM public.complete_chat_reply(job,tok,'{"missing_information":["缺少字幕处理工具"]}','[]');
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE task_kind='skill_research' AND input->>'plan_id'=p::text) THEN RAISE EXCEPTION 'Planning gap did not create research'; END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 BEGIN PERFORM public.request_skill_research(a,'Unauthorized','',gen_random_uuid()); RAISE EXCEPTION 'Non CEO request'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF has_table_privilege('authenticated','public.agent_skills','INSERT') OR has_function_privilege('authenticated','public.claim_skill_research(text)','EXECUTE') OR has_function_privilege('anon','public.request_skill_research(uuid,text,text,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'Unexpected browser privileges'; END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: recruitment, immutable evidence, leases, scope limits, reuse, recovery, automatic research and authorization; rolled back' AS checks;

