BEGIN;
DO $test$
DECLARE owner uuid:='b8cbf27e-2391-4fb5-b061-f1488e8c3135';f uuid;d uuid;j uuid;token uuid:=gen_random_uuid();
BEGIN
 -- Transaction-only test isolation. Existing flows are restored by ROLLBACK; no production quota changes.
 UPDATE public.brief_workflows SET state='blocked' WHERE state IN ('planning','extracting');
 IF private.brief_workflow_ready() THEN RAISE EXCEPTION 'Idle workflow woke model';END IF;
 PERFORM set_config('request.jwt.claim.sub',owner::text,true);
 f:=public.create_brief_workflow('SCHEDULER FIXTURE','生成合成项目简报','fixture.docx','docx_extract_v1',gen_random_uuid(),true);
 SELECT document_job_id INTO d FROM public.brief_workflows WHERE id=f;
 IF private.brief_workflow_ready() THEN RAISE EXCEPTION 'Uploading workflow woke model';END IF;
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('company-documents',owner::text||'/'||d::text||'/input','{"size":100}');
 PERFORM public.submit_brief_workflow(f);SELECT plan_job_id INTO j FROM public.brief_workflows WHERE id=f;
 IF private.brief_workflow_ready() THEN RAISE EXCEPTION 'Queued COS incorrectly treated as completed';END IF;
 UPDATE public.tasks SET execution_state='running',attempt_count=1,lease_token=token,lease_expires_at=now()+interval '90 seconds' WHERE id=j;
 PERFORM public.complete_chat_reply(j,token,'{"manager_code":"COO","assignment":"员工执行","acceptance":"保留资料依据"}','[]');
 IF NOT private.brief_workflow_ready() THEN RAISE EXCEPTION 'Completed COS did not wake workflow';END IF;
 PERFORM public.advance_brief_workflow(f);
 IF private.brief_workflow_ready() THEN RAISE EXCEPTION 'Queued document caused model idle polling';END IF;
 UPDATE public.document_jobs SET state='failed',finished_at=now() WHERE id=d;
 IF NOT private.brief_workflow_ready() THEN RAISE EXCEPTION 'Failed extraction did not wake reporting';END IF;
 PERFORM public.advance_brief_workflow(f);
 IF private.brief_workflow_ready() THEN RAISE EXCEPTION 'Blocked task caused repeated wakeups';END IF;
 UPDATE public.brief_workflows SET state='extracting' WHERE id=f;
 UPDATE public.document_jobs SET state='succeeded' WHERE id=d;
 IF NOT private.brief_workflow_ready() THEN RAISE EXCEPTION 'Completed extraction did not wake writing';END IF;
 IF position('IF NOT private.brief_workflow_ready() AND NOT EXISTS(SELECT 1 FROM public.tasks WHERE' IN pg_get_functiondef('private.invoke_cto_edge_worker()'::regprocedure))=0 THEN RAISE EXCEPTION 'Scheduler still gated only by chat';END IF;
 IF has_function_privilege('authenticated','private.brief_workflow_ready()','EXECUTE') OR has_function_privilege('service_role','private.brief_workflow_ready()','EXECUTE') THEN RAISE EXCEPTION 'Private scheduler access expanded';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS: COS terminal and document terminal wakeups; uploading, queued, skill-waiting and blocked tasks remain idle; original cron transport and credentials preserved; synthetic changes rolled back' AS checks;
