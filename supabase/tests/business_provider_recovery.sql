BEGIN;
DO $$
DECLARE f uuid;j uuid;token uuid:=gen_random_uuid();denied boolean;
BEGIN
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 f:=public.create_business_workflow('PROVIDER RECOVERY ROLLBACK','合成恢复测试',NULL,gen_random_uuid(),true);
 SELECT plan_job_id INTO j FROM public.business_workflows WHERE id=f;
 IF public.retry_business_workflow(f) THEN RAISE EXCEPTION 'Queued job duplicated';END IF;
 UPDATE public.tasks SET execution_state='running',attempt_count=3,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.fail_chat_reply(j,token,'provider_unavailable',false,'[]');
 UPDATE public.business_workflows SET state='blocked' WHERE id=f;
 IF NOT public.retry_business_workflow(f) THEN RAISE EXCEPTION 'Provider retry refused';END IF;
 IF (SELECT execution_state FROM public.tasks WHERE id=j)<>'queued' OR (SELECT state FROM public.business_workflows WHERE id=f)<>'planning' THEN RAISE EXCEPTION 'Retry state not restored';END IF;
 IF public.retry_business_workflow(f) THEN RAISE EXCEPTION 'Duplicate retry accepted';END IF;
 UPDATE public.tasks SET execution_state='running',attempt_count=4,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.fail_chat_reply(j,token,'execution_failed',false,'[]');
 IF public.retry_business_workflow(f) THEN RAISE EXCEPTION 'Nonprovider failure retried';END IF;
 UPDATE public.tasks SET execution_state='running',attempt_count=5,max_attempts=5,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.fail_chat_reply(j,token,'provider_unavailable',false,'[]');
 IF public.retry_business_workflow(f) THEN RAISE EXCEPTION 'Unbounded provider retries';END IF;
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 denied:=false;BEGIN PERFORM public.retry_business_workflow(f);EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;IF NOT denied THEN RAISE EXCEPTION 'Foreign retry';END IF;
 IF has_function_privilege('anon','public.retry_business_workflow(uuid)','EXECUTE') OR has_function_privilege('service_role','public.retry_business_workflow(uuid)','EXECUTE') THEN RAISE EXCEPTION 'Expanded retry privilege';END IF;
END $$;
ROLLBACK;
SELECT 'PASS: same-job provider recovery, no duplicate retries, maximum five attempts, nonprovider refusal, owner authorization; fixtures rolled back' AS checks;
