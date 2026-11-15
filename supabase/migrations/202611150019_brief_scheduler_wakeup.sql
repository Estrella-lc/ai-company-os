BEGIN;
SET LOCAL lock_timeout='5s';
-- Only wake for a transition that can actually advance. Queued/skill-waiting documents do not poll the model.
CREATE FUNCTION private.brief_workflow_ready() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(
  SELECT 1 FROM public.brief_workflows f
  LEFT JOIN public.tasks t ON t.id=f.plan_job_id AND t.created_by=f.created_by AND t.input->>'brief_plan_id'=f.id::text
  JOIN public.document_jobs d ON d.id=f.document_job_id AND d.created_by=f.created_by
  WHERE (f.state='planning' AND t.execution_state IN ('succeeded','failed','cancelled'))
     OR (f.state='extracting' AND d.state IN ('succeeded','failed'))
 );
$$;
REVOKE ALL ON FUNCTION private.brief_workflow_ready() FROM PUBLIC,anon,authenticated,service_role;
DO $patch$
DECLARE definition text;marker text:='IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE';
BEGIN
 definition:=pg_get_functiondef('private.invoke_cto_edge_worker()'::regprocedure);
 IF position(marker IN definition)=0 OR position('brief_workflow_ready' IN definition)>0 THEN RAISE EXCEPTION 'Worker wakeup guard changed';END IF;
 -- Keep the existing Vault lookup, endpoint, token header, timeout and all chat lease checks byte-for-byte.
 EXECUTE replace(definition,marker,'IF NOT private.brief_workflow_ready() AND NOT EXISTS(SELECT 1 FROM public.tasks WHERE');
END $patch$;
COMMIT;
