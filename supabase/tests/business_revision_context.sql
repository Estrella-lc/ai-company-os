BEGIN;
CREATE FUNCTION pg_temp.revision_complete(p_job uuid,p_body text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE token uuid:=gen_random_uuid();BEGIN
 UPDATE public.tasks SET execution_state='running',attempt_count=attempt_count+1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=p_job;
 PERFORM public.complete_chat_reply(p_job,token,p_body,'[]');
END $$;
DO $test$
DECLARE f uuid;j uuid;w uuid;next_job uuid;first_request text;revision text;next_request uuid;
BEGIN
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 f:=public.create_business_workflow('REVISION CONTEXT ROLLBACK','ROOT_SENTINEL: 公司共用3次，2MB、PDF30页、无OCR，未知预算不得编造。',NULL,gen_random_uuid(),true);
 SELECT plan_job_id INTO j FROM public.business_workflows WHERE id=f;
 PERFORM pg_temp.revision_complete(j,'{"summary":"单项合成任务","steps":[{"id":"delivery","manager_code":"CTO","assignment":"提交合成成果。","depends_on":[],"capabilities":["text"],"acceptance":["保留完整原目标"]}]}');
 PERFORM public.advance_business_workflows();
 SELECT s.work_order_id,t.id,m.content INTO w,j,first_request FROM public.business_steps s JOIN public.tasks w ON w.id=s.work_order_id JOIN public.tasks t ON t.id::text=w.result->>'current_job_id' JOIN public.messages m ON m.id=t.request_message_id WHERE s.workflow_id=f;
 PERFORM pg_temp.revision_complete(j,'合成成果。');
 PERFORM public.review_work_order(w,j,'revise','修正额度，但必须保留所有原标准。');
 SELECT t.id,t.request_message_id,m.content INTO next_job,next_request,revision FROM public.tasks ord JOIN public.tasks t ON t.id::text=ord.result->>'current_job_id' JOIN public.messages m ON m.id=t.request_message_id WHERE ord.id=w;
 IF next_job=j OR position(first_request IN revision)=0 OR position('ROOT_SENTINEL' IN revision)=0 OR position('修正额度' IN revision)=0 THEN RAISE EXCEPTION 'Revision lost original fixed context';END IF;
 IF (SELECT content FROM public.messages WHERE id=(SELECT request_message_id FROM public.tasks WHERE id=j))<>first_request THEN RAISE EXCEPTION 'Original request overwritten';END IF;
 PERFORM private.bind_business_revision_context(w,next_job);
 IF (SELECT content FROM public.messages WHERE id=next_request)<>revision THEN RAISE EXCEPTION 'Repeated bind duplicated context';END IF;
 PERFORM pg_temp.revision_complete(next_job,'合成成果。');
 IF NOT EXISTS(SELECT 1 FROM public.quality_reviews q WHERE q.source_job_id=next_job AND q.snapshot->>'execution_request'=revision) THEN RAISE EXCEPTION 'Inspector lost fixed revision basis';END IF;
 IF has_function_privilege('authenticated','private.bind_business_revision_context(uuid,uuid)','EXECUTE') OR has_function_privilege('service_role','private.bind_business_revision_context(uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'Revision helper exposed';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: original business instructions and source context retained on revision, prior messages unchanged, idempotent binding, independent fixed snapshot, private helper; rollback' AS checks;
