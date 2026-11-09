DO $$
DECLARE j public.tasks; old_token uuid; m uuid;
BEGIN
 -- Reuse the running concurrency fixture to test retry exhaustion.
 SELECT * INTO j FROM public.tasks WHERE execution_state='running' LIMIT 1;
 old_token:=j.lease_token;
 PERFORM public.fail_chat_reply(j.id,j.lease_token,'provider_unavailable',true,'[]');
 UPDATE public.tasks SET available_at=now(),max_attempts=2 WHERE id=j.id;
 -- Temporarily defer other queued rows so the target is deterministic.
 UPDATE public.tasks SET available_at=now()+interval '1 hour' WHERE execution_state='queued' AND id<>j.id;
 SELECT * INTO j FROM public.claim_chat_reply();
 IF j.attempt_count<>2 OR j.lease_token=old_token THEN RAISE EXCEPTION 'retry lease invalid'; END IF;
 PERFORM public.fail_chat_reply(j.id,j.lease_token,'provider_unavailable',true,'[]');
 IF (SELECT execution_state FROM public.tasks WHERE id=j.id)<>'failed' THEN RAISE EXCEPTION 'attempt exhaustion not terminal'; END IF;
 -- Completion after CEO cancellation is fenced.
 UPDATE public.tasks SET available_at=now() WHERE execution_state='queued';
 SELECT * INTO j FROM public.claim_chat_reply();
 PERFORM set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',true);
 IF NOT public.cancel_chat_reply(j.id) THEN RAISE EXCEPTION 'cancel failed'; END IF;
 BEGIN PERFORM public.complete_chat_reply(j.id,j.lease_token,'late reply'); RAISE EXCEPTION 'cancelled completion accepted'; EXCEPTION WHEN serialization_failure THEN NULL; END;
 RAISE NOTICE 'PASS transient retry, new lease, attempt exhaustion, cancellation fencing';
END $$;
