-- DRAFT: enable only after function and dedicated trigger token have been deployed.
-- Store identical CTO_WORKER_TOKEN in Edge Function Secrets and Vault as cto_worker_token.
-- Never paste a Gemini key or database service-role key into this SQL.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.invoke_cto_edge_worker() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE token text; request_id bigint;
BEGIN
 -- Avoid idle invocations and recover expired leases on a subsequent tick.
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE task_kind='chat_reply' AND
 ((execution_state='queued' AND available_at<=now()) OR
 (execution_state='running' AND lease_expires_at<=now()))) THEN RETURN NULL; END IF;
 SELECT decrypted_secret INTO token FROM vault.decrypted_secrets WHERE name='cto_worker_token';
 IF token IS NULL THEN RAISE EXCEPTION 'CTO worker trigger token is missing'; END IF;
 SELECT net.http_post(url:='https://mcwkkmkgfienxrmfyvfl.supabase.co/functions/v1/cto-task-worker',
 headers:=jsonb_build_object('Content-Type','application/json','x-worker-token',token),
 body:='{}'::jsonb,timeout_milliseconds:=110000) INTO request_id;
 RETURN request_id;
END $$;
REVOKE ALL ON FUNCTION private.invoke_cto_edge_worker() FROM PUBLIC,anon,authenticated,service_role;
-- Do not duplicate the schedule on retry.
DO $$ BEGIN IF EXISTS(SELECT 1 FROM cron.job WHERE jobname='cto-edge-worker') THEN
 PERFORM cron.unschedule('cto-edge-worker'); END IF; END $$;
SELECT cron.schedule('cto-edge-worker','* * * * *','SELECT private.invoke_cto_edge_worker();');
