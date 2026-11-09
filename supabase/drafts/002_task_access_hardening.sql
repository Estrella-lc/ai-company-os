-- DRAFT ONLY. Apply separately from schema changes after access tests.
-- Do not change existing CEO policies or widen browser write access.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['agents','projects','conversations','messages','meetings','meeting_messages','tasks','approvals','tool_executions','model_usage','audit_logs'] LOOP
  EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.%I FROM anon, authenticated',t);
 END LOOP;
END $$;
-- Polling requires SELECT in addition to the existing CEO-only SELECT policy.
GRANT SELECT ON public.tasks TO authenticated;
-- Backend worker only. All API endpoints must verify CEO identity and ownership.
GRANT SELECT ON public.agents,public.conversations,public.messages,public.tasks TO service_role;
GRANT INSERT,UPDATE ON public.tasks TO service_role;
GRANT INSERT ON public.messages,public.model_usage,public.audit_logs TO service_role;
COMMIT;
