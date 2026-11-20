BEGIN;
CREATE FUNCTION pg_temp.goal_complete(p_job uuid,p_body text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE token uuid:=gen_random_uuid();BEGIN
 UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=p_job;
 PERFORM public.complete_chat_reply(p_job,token,p_body,'[]');
END $$;
DO $test$
DECLARE owner uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135';g uuid;k uuid:=gen_random_uuid();row record;proposal text;selected uuid;research uuid;token uuid:=gen_random_uuid();prefix text;report jsonb;denied boolean;before_count bigint;g2 uuid;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',owner::text,true);
 denied:=false;BEGIN PERFORM public.create_company_goal('ROLLBACK','goal',k,false);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Consent bypass';END IF;
 g:=public.create_company_goal('GOAL ROLLBACK','虚构成年角色职场反转样例',k,true);
 IF public.create_company_goal('same','same',k,true)<>g THEN RAISE EXCEPTION 'Duplicate goal';END IF;
 IF (SELECT count(DISTINCT assigned_agent_id) FROM public.tasks WHERE input->>'creative_goal_id'=g::text)<>3 THEN RAISE EXCEPTION 'Not three independently assigned employees';END IF;
 proposal:='{"title":"合成方案","concept":"职场反转","rationale":"简单可行","tradeoffs":"固定声音","character_description":"成年男性","image_prompt_en":"one fictional adult male office worker","voice_text":"这份方案每个数字我都核对过"}';
 FOR row IN SELECT * FROM public.tasks WHERE input->>'creative_goal_id'=g::text LOOP PERFORM pg_temp.goal_complete(row.id,proposal);selected:=row.id;END LOOP;
 PERFORM public.advance_company_goals();
 IF (SELECT state FROM public.company_goals WHERE id=g)<>'choosing' OR (SELECT jsonb_array_length(proposals) FROM public.company_goals WHERE id=g)<>3 THEN RAISE EXCEPTION 'Proposal comparison not ready';END IF;
 IF NOT public.select_company_goal_proposal(g,selected) OR NOT public.select_company_goal_proposal(g,selected) THEN RAISE EXCEPTION 'Selection idempotency';END IF;
 SELECT research_job INTO research FROM public.company_goals WHERE id=g;
 IF (SELECT count(*) FROM public.tasks WHERE input->>'creative_goal_id'=g::text AND input->>'mode'='creative_samples')<>1 THEN RAISE EXCEPTION 'Duplicate capability job';END IF;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,input=input||'{"runner_id":"123456789/1"}',lease_token=token,lease_expires_at=now()+interval '10 minutes' WHERE id=research;
 IF EXISTS(SELECT 1 FROM public.creative_task_context(research,gen_random_uuid(),'123456789/1')) OR EXISTS(SELECT 1 FROM public.creative_task_context(research,token,'999/1')) THEN RAISE EXCEPTION 'Forged lease';END IF;
 prefix:=owner::text||'/'||research::text||'/'||token::text||'/';
 report:=jsonb_build_object('adapter_commit',repeat('a',40),'assets',jsonb_build_object('image_path',prefix||'character.png','voice_path',prefix||'voice.wav'),'verification','{"passed":true,"isolation":{"network_disabled":true,"root_read_only":true,"unprivileged":true,"secrets_absent":true},"limitations":["rollback fixture"]}'::jsonb,'manifest','{"fixture":true}','run_url','https://github.com/Estrella-lc/ai-company-os/actions/runs/123456789');
 denied:=false;BEGIN PERFORM public.finish_creative_samples(research,token,'123456789/1',report,false);EXCEPTION WHEN invalid_parameter_value THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Missing files accepted';END IF;
 -- Metadata-only storage fixtures are transaction rollback tests, never real generation evidence.
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('company-creative',prefix||'character.png','{"size":100}'),('company-creative',prefix||'voice.wav','{"size":100}');
 IF NOT public.finish_creative_samples(research,token,'123456789/1',report,false) THEN RAISE EXCEPTION 'Valid bound callback refused';END IF;
 PERFORM public.advance_company_goals();
 IF (SELECT state FROM public.company_goals WHERE id=g)<>'reviewing' THEN RAISE EXCEPTION 'Independent review not queued';END IF;
 IF public.accept_company_goal(g,research) THEN RAISE EXCEPTION 'Premature CEO acceptance';END IF;
 SELECT count(*) INTO before_count FROM public.agent_skills WHERE request_task_id=research;
 IF before_count<>0 THEN RAISE EXCEPTION 'Unreviewed skill registered';END IF;
 FOR row IN SELECT key,value FROM public.company_goals f,LATERAL jsonb_each_text(f.review_jobs) WHERE f.id=g LOOP
  PERFORM pg_temp.goal_complete(row.value::uuid,jsonb_build_object('verdict','pass','summary','合成事务检查','transcript',CASE WHEN row.key='voice' THEN '这份方案每个数字我都核对过' ELSE '' END,'checks',(SELECT jsonb_agg(jsonb_build_object('id',x,'status','pass','evidence','仅限事务夹具','reason','测试标准通过')) FROM unnest(CASE WHEN row.key='image' THEN ARRAY['character','clarity','brief'] ELSE ARRAY['speech','fidelity','audio_quality'] END) x))::text);
 END LOOP;
 PERFORM public.advance_company_goals();
 IF (SELECT state FROM public.company_goals WHERE id=g)<>'ready' OR (SELECT count(*) FROM public.agent_skills WHERE request_task_id=research AND status='verified_limited')<>2 THEN RAISE EXCEPTION 'Verified capabilities not registered';END IF;
 g2:=public.create_company_goal('REUSE ROLLBACK','相同受限能力由其他员工复用',gen_random_uuid(),true);
 FOR row IN SELECT * FROM public.tasks WHERE input->>'creative_goal_id'=g2::text LOOP PERFORM pg_temp.goal_complete(row.id,proposal);selected:=row.id;END LOOP;
 PERFORM public.advance_company_goals();PERFORM public.select_company_goal_proposal(g2,selected);
 IF NOT EXISTS(SELECT 1 FROM public.tasks t JOIN public.company_goals f ON f.research_job=t.id WHERE f.id=g2 AND t.input->'reuse_manifest' IS NOT NULL AND t.input->'reuse_manifest'<>'null') THEN RAISE EXCEPTION 'Company-wide verified reuse missing';END IF;
 INSERT INTO public.audit_logs(actor_type,action,resource_type,resource_id) SELECT 'test','skill_research.claimed','fixture',gen_random_uuid()::text FROM generate_series(1,3);
 IF EXISTS(SELECT 1 FROM public.claim_skill_research('9999999999/1')) THEN RAISE EXCEPTION 'Creative mode bypassed shared daily claim quota';END IF;
 IF NOT public.accept_company_goal(g,research) THEN RAISE EXCEPTION 'CEO decision failed';END IF;
 IF has_function_privilege('authenticated','public.finish_creative_samples(uuid,uuid,text,jsonb,boolean)','EXECUTE') OR has_table_privilege('authenticated','public.company_goals','UPDATE') OR has_function_privilege('anon','public.create_company_goal(text,text,uuid,boolean)','EXECUTE') THEN RAISE EXCEPTION 'Excess permissions';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: consent/idempotency, three employee proposals, frozen selection, lease isolation, private file gate, separate inspection, no premature registry/acceptance and company-wide reuse; fixtures rolled back' AS checks;
