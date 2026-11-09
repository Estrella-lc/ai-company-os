-- Only run against isolated reconstructed database.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
GRANT USAGE ON SCHEMA auth TO authenticated,anon;
INSERT INTO auth.users(id) VALUES('b8cbf27e-2391-4fb5-b061-f1488e8c3135'),('11111111-1111-4111-8111-111111111111');
INSERT INTO public.agents(id,code,name,title) VALUES('22222222-2222-4222-8222-222222222222','CTO','CTO','CTO');
INSERT INTO public.conversations(id,created_by,agent_id) VALUES('33333333-3333-4333-8333-333333333333','b8cbf27e-2391-4fb5-b061-f1488e8c3135','22222222-2222-4222-8222-222222222222'),('33333333-3333-4333-8333-333333333334','11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
INSERT INTO public.messages(id,conversation_id,sender_type,content) VALUES('44444444-4444-4444-8444-444444444444','33333333-3333-4333-8333-333333333333','user','test'),('44444444-4444-4444-8444-444444444445','33333333-3333-4333-8333-333333333334','user','other user');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
DO $$ BEGIN BEGIN PERFORM public.enqueue_chat_reply('44444444-4444-4444-8444-444444444445',gen_random_uuid()); RAISE EXCEPTION 'non CEO accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
SELECT set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',false);
DO $$ BEGIN BEGIN PERFORM public.enqueue_chat_reply('44444444-4444-4444-8444-444444444445',gen_random_uuid()); RAISE EXCEPTION 'cross owner accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
DO $$ BEGIN BEGIN PERFORM public.claim_chat_reply(); RAISE EXCEPTION 'browser can claim'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
SELECT public.enqueue_chat_reply('44444444-4444-4444-8444-444444444444','55555555-5555-4555-8555-555555555555');
DO $$ DECLARE a uuid; b uuid; BEGIN a:=public.enqueue_chat_reply('44444444-4444-4444-8444-444444444444',gen_random_uuid()); b:=public.enqueue_chat_reply('44444444-4444-4444-8444-444444444444',gen_random_uuid()); IF a<>b THEN RAISE EXCEPTION 'not idempotent'; END IF; END $$;
RESET ROLE;
DO $$ DECLARE j public.tasks; mid uuid; BEGIN
 SELECT * INTO j FROM public.claim_chat_reply();
 BEGIN PERFORM public.complete_chat_reply(j.id,gen_random_uuid(),'stale'); RAISE EXCEPTION 'stale token accepted'; EXCEPTION WHEN serialization_failure THEN NULL; END;
 IF NOT public.heartbeat_chat_reply(j.id,j.lease_token) THEN RAISE EXCEPTION 'heartbeat failed'; END IF;
 UPDATE public.tasks SET lease_expires_at=now()-interval '1 second' WHERE id=j.id;
 PERFORM public.reap_expired_chat_replies();
 IF (SELECT execution_state FROM public.tasks WHERE id=j.id)<>'queued' THEN RAISE EXCEPTION 'crash not recovered'; END IF;
 BEGIN PERFORM public.complete_chat_reply(j.id,j.lease_token,'late'); RAISE EXCEPTION 'expired worker accepted'; EXCEPTION WHEN serialization_failure THEN NULL; END;
 UPDATE public.tasks SET available_at=now() WHERE id=j.id;
 SELECT * INTO j FROM public.claim_chat_reply();
 -- Deliberately fail usage insert: message/task writes must roll back too.
 BEGIN PERFORM public.complete_chat_reply(j.id,j.lease_token,'rollback','[{"model":null}]'); RAISE EXCEPTION 'invalid usage accepted'; EXCEPTION WHEN not_null_violation THEN NULL; END;
 IF EXISTS(SELECT 1 FROM public.messages WHERE reply_task_id=j.id) THEN RAISE EXCEPTION 'partial message committed'; END IF;
 mid:=public.complete_chat_reply(j.id,j.lease_token,'ok','[]');
 IF public.complete_chat_reply(j.id,j.lease_token,'again','[]')<>mid THEN RAISE EXCEPTION 'completion not idempotent'; END IF;
 IF (SELECT count(*) FROM public.messages WHERE reply_task_id=j.id)<>1 THEN RAISE EXCEPTION 'duplicate reply'; END IF;
 RAISE NOTICE 'PASS authorization, ownership, RPC grants, enqueue idempotency, heartbeat, crash recovery, stale token fencing, atomic rollback, completion idempotency';
END $$;
