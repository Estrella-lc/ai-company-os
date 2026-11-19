BEGIN;
DO $$
DECLARE f uuid;j uuid;success_job uuid;message uuid;token uuid:=gen_random_uuid();
BEGIN
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 f:=public.create_business_workflow('PROVIDER DIAGNOSTICS ROLLBACK','诊断字段合成测试',NULL,gen_random_uuid(),true);
 SELECT plan_job_id INTO j FROM public.business_workflows WHERE id=f;
 UPDATE public.tasks SET execution_state='running',attempt_count=5,max_attempts=5,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.fail_chat_reply(j,token,'provider_unavailable',false,'[{"model":"synthetic","status":"failed","error_kind":"credentials","http_status":400,"duration_ms":10}]');
 IF NOT EXISTS(SELECT 1 FROM public.model_usage WHERE task_id=j AND error_kind='credentials' AND http_status=400 AND call_status='failed') THEN RAISE EXCEPTION 'Sanitized diagnostics not saved';END IF;
 IF NOT public.retry_business_workflow(f) THEN RAISE EXCEPTION 'Renewed bounded recovery refused';END IF;
 IF (SELECT attempt_count FROM public.tasks WHERE id=j)<>5 OR (SELECT max_attempts FROM public.tasks WHERE id=j)<>6 THEN RAISE EXCEPTION 'Original history overwritten';END IF;
 UPDATE public.tasks SET execution_state='running',attempt_count=6,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.fail_chat_reply(j,token,'provider_unavailable',false,'[{"model":"synthetic","status":"failed","error_kind":"provider_unavailable","http_status":503,"duration_ms":10}]');
 IF public.retry_business_workflow(f) THEN RAISE EXCEPTION 'Recovery became unbounded';END IF;
 INSERT INTO public.messages(conversation_id,sender_type,content) SELECT conversation_id,'user','合成诊断成功请求' FROM public.tasks WHERE id=j RETURNING id INTO message;
 INSERT INTO public.tasks(title,task_kind,execution_state,created_by,assigned_agent_id,conversation_id,request_message_id,request_key)
 SELECT 'DIAGNOSTICS SUCCESS FIXTURE','chat_reply','queued',created_by,assigned_agent_id,conversation_id,message,gen_random_uuid() FROM public.tasks WHERE id=j RETURNING id INTO success_job;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=success_job;
 PERFORM public.complete_chat_reply(success_job,token,'合成调用成功','[{"model":"synthetic-fallback","status":"completed","input_tokens":1,"output_tokens":1,"duration_ms":10,"request_id":"synthetic-request"},{"model":"synthetic","status":"failed","error_kind":"rate_limit","http_status":429,"duration_ms":10}]');
 IF NOT EXISTS(SELECT 1 FROM public.model_usage WHERE task_id=success_job AND http_status=429 AND error_kind='rate_limit') OR NOT EXISTS(SELECT 1 FROM public.model_usage WHERE task_id=success_job AND provider_request_id='synthetic-request') THEN RAISE EXCEPTION 'Fallback success diagnostics or request identity lost';END IF;
END $$;
ROLLBACK;
SELECT 'PASS: sanitized HTTP/error classification persisted; original attempt history retained; one renewed recovery only; fixtures rolled back' AS checks;
