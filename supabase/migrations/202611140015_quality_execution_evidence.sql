BEGIN;
SET LOCAL lock_timeout='5s';
DO $migration$
DECLARE definition text; marker text;
BEGIN
 definition:=replace(pg_get_functiondef('private.queue_text_quality(uuid)'::regprocedure),E'\r\n',E'\n');
 marker:='body text; context jsonb;';
 IF position(marker IN definition)=0 OR position('execution_request_message_id' IN definition)>0 THEN RAISE EXCEPTION 'Quality snapshot function changed';END IF;
 definition:=replace(definition,marker,'body text; context jsonb; execution_request text;');
 marker:='SELECT content INTO body FROM public.messages WHERE reply_task_id=source.id;';
 IF position(marker IN definition)=0 THEN RAISE EXCEPTION 'Quality delivery lookup changed';END IF;
 definition:=replace(definition,marker,marker||E'\n SELECT m.content INTO execution_request FROM public.messages m WHERE m.id=source.request_message_id AND m.conversation_id=source.conversation_id AND m.sender_type=''user'';\n IF execution_request IS NULL THEN RAISE EXCEPTION ''Missing bound execution request'' USING ERRCODE=''22023'';END IF;');
 marker:='''body'',body,''project'',context';
 IF position(marker IN definition)=0 THEN RAISE EXCEPTION 'Quality snapshot fields changed';END IF;
 EXECUTE replace(definition,marker,marker||',''execution_request'',execution_request,''execution_request_message_id'',source.request_message_id');
 definition:=replace(pg_get_functiondef('private.route_text_quality_completion()'::regprocedure),E'\r\n',E'\n');
 marker:='''任务内部返工：''||w.title||E''\n原目标：\n''||w.description||E''\n验收标准：\n''||(w.input->>''acceptance'')||E''\n''||feedback';
 IF position(marker IN definition)=0 OR position('固定执行指令' IN definition)>0 THEN RAISE EXCEPTION 'Quality repair request changed';END IF;
 EXECUTE replace(definition,marker,'''任务内部返工：''||w.title||E''\n固定执行指令（保留此前澄清）：\n''||coalesce(q.snapshot->>''execution_request'',''原目标：''||w.description||E''\n验收标准：\n''||(w.input->>''acceptance''))||E''\n''||feedback');
END $migration$;
NOTIFY pgrst,'reload schema';
COMMIT;
