-- Apply pending migration inside this transaction first. All metadata fixtures roll back.
BEGIN;
DO $test$
DECLARE ceo uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135'; manager uuid; j uuid; j2 uuid; c public.subtitle_jobs; prefix text; report jsonb; n integer;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',ceo::text,true);
 SELECT manager_agent_id INTO manager FROM public.agent_skills WHERE created_by=ceo AND status='verified_limited' AND verification->>'scope'='subtitle_fixture_v1' LIMIT 1;
 IF manager IS NULL THEN RAISE EXCEPTION 'Verified fixture manager missing';END IF;
 j:=public.create_subtitle_job(manager,'字幕交付回滚测试',gen_random_uuid());
 IF j IS DISTINCT FROM public.create_subtitle_job(manager,'幂等', (SELECT request_key FROM public.subtitle_jobs WHERE id=j)) THEN RAISE EXCEPTION 'Duplicate create';END IF;
 BEGIN PERFORM public.queue_subtitle_job(j);RAISE EXCEPTION 'Missing input accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 prefix:=ceo::text || '/' || j::text || '/';
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('company-media',prefix || 'input.mp4','{"size":1000}'),('company-media',prefix || 'input.srt','{"size":100}');
 PERFORM public.queue_subtitle_job(j);PERFORM public.queue_subtitle_job(j);
 -- Existing live research claims are ignored only inside this rolled-back transaction.
 UPDATE public.audit_logs SET created_at=now()-interval '2 days' WHERE action IN ('skill_research.claimed','subtitle.claimed') AND created_at>=date_trunc('day',now());
 SELECT * INTO c FROM public.claim_subtitle_job('910001/1');
 IF c.id IS DISTINCT FROM j OR c.attempt_count<>1 THEN RAISE EXCEPTION 'Claim failed';END IF;
 IF (SELECT id FROM public.claim_subtitle_job('910001/1')) IS DISTINCT FROM j OR EXISTS(SELECT 1 FROM public.claim_subtitle_job('910002/1')) THEN RAISE EXCEPTION 'Concurrent duplicate claim';END IF;
 report:=jsonb_build_object('passed',true,'scope','subtitle_delivery_v1','output_sha256',repeat('b',64),'duration',3,'subtitle_cues',2);
 IF public.finish_subtitle_job(j,gen_random_uuid(),'910001/1',report) THEN RAISE EXCEPTION 'Wrong lease accepted';END IF;
 BEGIN PERFORM public.finish_subtitle_job(j,c.lease_token,'910001/1',report);RAISE EXCEPTION 'Missing output accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('company-media',c.output_path,'{"size":1500}');
 PERFORM public.finish_subtitle_job(j,c.lease_token,'910001/1',report);PERFORM public.finish_subtitle_job(j,c.lease_token,'910001/1',report);
 PERFORM public.review_subtitle_job(j,'revise','回滚测试修改意见');PERFORM public.review_subtitle_job(j,'accept','回滚测试通过');PERFORM public.review_subtitle_job(j,'accept','重复请求');
 SELECT count(*) INTO n FROM public.audit_logs WHERE action='subtitle.accept' AND resource_id=j::text;
 IF n<>1 THEN RAISE EXCEPTION 'Duplicate review';END IF;
 j2:=public.create_subtitle_job(manager,'恢复与预算测试',gen_random_uuid());
 prefix:=ceo::text || '/' || j2::text || '/';
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('company-media',prefix || 'input.mp4','{"size":1000}'),('company-media',prefix || 'input.srt','{"size":100}');
 PERFORM public.queue_subtitle_job(j2);
 SELECT * INTO c FROM public.claim_subtitle_job('910002/1');
 UPDATE public.subtitle_jobs SET lease_expires_at=now()-interval '1 second' WHERE id=j2;
 SELECT * INTO c FROM public.claim_subtitle_job('910003/1');
 IF c.id IS DISTINCT FROM j2 OR c.attempt_count<>2 OR c.last_error<>'runner_interrupted' THEN RAISE EXCEPTION 'Recovery failed';END IF;
 IF public.finish_subtitle_job(j2,gen_random_uuid(),'910002/1',report) THEN RAISE EXCEPTION 'Stale runner accepted';END IF;
 IF EXISTS(SELECT 1 FROM public.claim_skill_research('910004/1')) THEN RAISE EXCEPTION 'Shared daily budget exceeded';END IF;
 UPDATE public.subtitle_jobs SET lease_expires_at=now()-interval '1 second',attempt_count=3 WHERE id=j2;
 PERFORM public.claim_subtitle_job('910005/1');
 IF NOT EXISTS(SELECT 1 FROM public.subtitle_jobs WHERE id=j2 AND state='failed' AND finished_at IS NOT NULL) THEN RAISE EXCEPTION 'Retry exhaustion failed';END IF;
 IF (SELECT public FROM storage.buckets WHERE id='company-media') THEN RAISE EXCEPTION 'Bucket exposed';END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 BEGIN PERFORM public.queue_subtitle_job(j);RAISE EXCEPTION 'Non CEO allowed';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 IF has_function_privilege('authenticated','public.claim_subtitle_job(text)','EXECUTE') OR has_function_privilege('anon','public.create_subtitle_job(uuid,text,uuid)','EXECUTE') OR has_table_privilege('authenticated','public.subtitle_jobs','UPDATE') THEN RAISE EXCEPTION 'Browser permissions expanded';END IF;
END $test$;
SET LOCAL ROLE authenticated;
DO $rls$
BEGIN
 IF EXISTS(SELECT 1 FROM public.subtitle_jobs) OR EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='company-media') THEN RAISE EXCEPTION 'Cross-owner RLS leak';END IF;
 BEGIN INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('company-media','other-owner/other-job/input.mp4','{"size":1}');RAISE EXCEPTION 'Cross-owner upload allowed';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 IF (SELECT count(*) FROM public.subtitle_jobs)<>2 OR (SELECT count(*) FROM storage.objects WHERE bucket_id='company-media')<>5 THEN RAISE EXCEPTION 'Owner RLS read failed';END IF;
END $rls$;
RESET ROLE;
ROLLBACK;
SELECT 'PASS: private metadata, ownership, input/output readiness, idempotency, lease recovery, stale runner rejection and shared budget; rolled back' AS checks;
