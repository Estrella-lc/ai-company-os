BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.model_usage ADD COLUMN error_kind text CHECK(error_kind IS NULL OR error_kind IN ('credentials','permission','rate_limit','model_unavailable','timeout','provider_unavailable','invalid_request','network','incomplete','unknown'));
ALTER TABLE public.model_usage ADD COLUMN http_status integer CHECK(http_status IS NULL OR http_status BETWEEN 100 AND 599);
DO $patch$
DECLARE signature text;d text;old text;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.fail_chat_reply(uuid,uuid,text,boolean,jsonb)','public.complete_chat_reply(uuid,uuid,text,jsonb)'] LOOP
  d:=pg_get_functiondef(signature::regprocedure);
  IF signature LIKE '%fail_chat_reply%' THEN
   IF position('duration_ms,call_status)' IN d)=0 OR position('u->>''status'');' IN d)=0 THEN RAISE EXCEPTION 'Failure usage writer changed';END IF;
   d:=replace(d,'duration_ms,call_status)','duration_ms,call_status,error_kind,http_status)');
   d:=replace(d,'u->>''status'');','u->>''status'',u->>''error_kind'',CASE WHEN (u->>''http_status'') ~ ''^[1-5][0-9]{2}$'' THEN (u->>''http_status'')::integer ELSE NULL END);');
  ELSE
   IF position('duration_ms,call_status,provider_request_id)' IN d)=0 OR position('u->>''request_id'');' IN d)=0 THEN RAISE EXCEPTION 'Success usage writer changed';END IF;
   d:=replace(d,'duration_ms,call_status,provider_request_id)','duration_ms,call_status,provider_request_id,error_kind,http_status)');
   d:=replace(d,'u->>''request_id'');','u->>''request_id'',u->>''error_kind'',CASE WHEN (u->>''http_status'') ~ ''^[1-5][0-9]{2}$'' THEN (u->>''http_status'')::integer ELSE NULL END);');
  END IF;
  EXECUTE d;
 END LOOP;
 d:=pg_get_functiondef('public.retry_business_workflow(uuid)'::regprocedure);
 IF position('j.attempt_count<5' IN d)=0 THEN RAISE EXCEPTION 'Recovery guard changed';END IF;
 -- One additional bounded recovery under the CEO's renewed repair request; history is retained.
 d:=replace(d,'j.attempt_count<5','j.attempt_count<6');
 EXECUTE replace(d,'''maximum_attempts'',5','''maximum_attempts'',6');
END $patch$;
NOTIFY pgrst,'reload schema';
COMMIT;
