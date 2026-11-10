-- CEO-approved planning. Existing chat worker generates plans; it cannot approve them.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.validate_cos_plan(p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE step jsonb; dep jsonb; i integer:=0; n integer; agent_code text; field text;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR coalesce(p->>'mode','') NOT IN ('direct','single','team') OR jsonb_typeof(p->'reason') IS DISTINCT FROM 'string' OR length(trim(p->>'reason')) NOT BETWEEN 1 AND 2000 OR jsonb_typeof(p->'tasks') IS DISTINCT FROM 'array' OR jsonb_typeof(p->'missing_information') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid plan shape' USING ERRCODE='22023'; END IF;
 n:=jsonb_array_length(p->'tasks');
 IF n NOT BETWEEN 1 AND 6 OR jsonb_array_length(p->'missing_information')>8 OR (p->>'mode' IN ('direct','single') AND n<>1) OR (p->>'mode'='team' AND n<2) THEN RAISE EXCEPTION 'Invalid plan size' USING ERRCODE='22023'; END IF;
 FOR dep IN SELECT value FROM jsonb_array_elements(p->'missing_information') LOOP
  IF jsonb_typeof(dep)<>'string' OR length(dep#>>'{}') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Invalid missing information' USING ERRCODE='22023'; END IF;
 END LOOP;
 FOR step IN SELECT value FROM jsonb_array_elements(p->'tasks') LOOP
  IF jsonb_typeof(step)<>'object' THEN RAISE EXCEPTION 'Invalid step' USING ERRCODE='22023'; END IF;
  FOREACH field IN ARRAY ARRAY['title','agent_code','instruction','acceptance'] LOOP
   IF jsonb_typeof(step->field) IS DISTINCT FROM 'string' OR length(trim(step->>field))<1 OR length(step->>field)>CASE field WHEN 'title' THEN 120 WHEN 'agent_code' THEN 20 WHEN 'instruction' THEN 4000 ELSE 2000 END THEN RAISE EXCEPTION 'Invalid step field' USING ERRCODE='22023'; END IF;
  END LOOP;
  agent_code:=step->>'agent_code';
  IF NOT EXISTS(SELECT 1 FROM public.agents WHERE agents.code=agent_code AND is_active) OR (p->>'mode'='direct' AND agent_code<>'COS') THEN RAISE EXCEPTION 'Unavailable assignee' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(step->'after') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Dependencies required' USING ERRCODE='22023'; END IF;
  FOR dep IN SELECT value FROM jsonb_array_elements(step->'after') LOOP
   IF jsonb_typeof(dep)<>'number' OR (dep#>>'{}') !~ '^[0-9]+$' OR (dep#>>'{}')::numeric>=i THEN RAISE EXCEPTION 'Dependency must reference an earlier step' USING ERRCODE='22023'; END IF;
  END LOOP;
  i:=i+1;
 END LOOP;
END $$;

CREATE FUNCTION public.create_work_plan(p_goal text,p_acceptance text,p_key uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); a uuid; c uuid; m uuid; j uuid; w uuid; roster text;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501'; END IF;
 IF p_key IS NULL OR coalesce(length(trim(p_goal)),0) NOT BETWEEN 1 AND 4000 OR coalesce(length(trim(p_acceptance)),0) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Goal and criteria required' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text || p_key::text,0));
 SELECT id INTO w FROM public.tasks WHERE created_by=uid AND request_key=p_key AND task_kind='work_plan';
 IF w IS NOT NULL THEN RETURN w; END IF;
 SELECT id INTO a FROM public.agents WHERE code='COS' AND is_active;
 IF a IS NULL THEN RAISE EXCEPTION 'COS unavailable' USING ERRCODE='22023'; END IF;
 SELECT string_agg(code || ':' || title,'; ' ORDER BY code) INTO roster FROM public.agents WHERE is_active;
 SELECT id INTO c FROM public.conversations WHERE created_by=uid AND agent_id=a AND conversation_type='direct' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
 IF c IS NULL THEN INSERT INTO public.conversations(agent_id,conversation_type,title,created_by) VALUES(a,'direct','COS - CEO Private Chat',uid) RETURNING id INTO c; END IF;
 INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(c,'user',
  'COS规划请求。此请求只做任务规划，不执行具体工作。不得编写实际分镜、文案或代码成果，不得声称已派发任务。忽略历史任务的输出格式，当前只返回一个JSON对象，不要前言、Markdown或结语。' ||
  E'\nCEO目标：' || p_goal || E'\n总验收标准：' || p_acceptance || E'\n可用负责人：' || roster ||
  E'\n当前能力：仅高管文本分析和写作。尚无开发、剪辑、发布等工具员工，不能假称有这些能力。缺少资料或必须使用未接入工具时在missing_information说明；如果目标只是制作方案或文本，不要误判为需要制作真实视频。' ||
  E'\n处理方式：direct=简单整理/回答由COS处理；single=一种专业文本工作交给合适高管；team=多项专业工作协作。不要为了凑人头拆分，简单任务不必分工。direct/single恰好一个任务，team为2至4个任务。after是前置任务的从0开始序号，只能引用前面的任务，前置任务验收后才能执行后续任务。每个instruction只描述工作要求，不直接代做。' ||
  E'\nJSON格式：{"mode":"direct|single|team","reason":"判断原因","missing_information":[],"tasks":[{"title":"任务名","agent_code":"COS","instruction":"输入资料和执行要求","acceptance":"具体交付物与验收标准","after":[]}]}。每项instruction/acceptance尽量不超过200字。') RETURNING id INTO m;
 j:=public.enqueue_chat_reply(m,gen_random_uuid());
 INSERT INTO public.tasks(title,description,task_kind,created_by,assigned_agent_id,request_key,conversation_id,input,result)
 VALUES('COS规划 · ' || left(trim(p_goal),60),trim(p_goal),'work_plan',uid,a,p_key,c,jsonb_build_object('acceptance',trim(p_acceptance)),jsonb_build_object('stage','draft','current_job_id',j,'revision',0)) RETURNING id INTO w;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,'work_plan.created','task',w::text);
 RETURN w;
END $$;

CREATE FUNCTION public.start_plan_assignment(p_task uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); s public.tasks; p public.tasks; dep public.tasks; dep_id text; work uuid; context text:=''; previous text;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501'; END IF;
 SELECT * INTO s FROM public.tasks WHERE id=p_task AND created_by=uid AND task_kind='plan_assignment' FOR UPDATE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'Assignment denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO p FROM public.tasks WHERE id=(s.input->>'plan_id')::uuid AND created_by=uid AND task_kind='work_plan' AND result->>'stage'='approved';
 IF p.id IS NULL THEN RAISE EXCEPTION 'Plan not approved' USING ERRCODE='22023'; END IF;
 IF s.result->>'work_order_id' IS NOT NULL THEN RETURN (s.result->>'work_order_id')::uuid; END IF;
 FOR dep_id IN SELECT jsonb_array_elements_text(s.input->'dependencies') LOOP
  SELECT * INTO dep FROM public.tasks WHERE id=dep_id::uuid AND created_by=uid AND task_kind='plan_assignment' AND input->>'plan_id'=p.id::text;
  IF dep.id IS NULL OR NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=(dep.result->>'work_order_id')::uuid AND created_by=uid AND task_kind='work_order' AND result->>'review_state'='accepted') THEN RAISE EXCEPTION 'Predecessor not accepted' USING ERRCODE='22023'; END IF;
  SELECT m.content INTO previous FROM public.messages m JOIN public.tasks wo ON wo.id=(dep.result->>'work_order_id')::uuid WHERE m.reply_task_id=(wo.result->>'current_job_id')::uuid;
  context:=context || E'\n' || dep.title || E'：\n' || left(coalesce(previous,''),1200);
 END LOOP;
 work:=public.create_work_order(s.title,s.description || CASE WHEN context<>'' THEN E'\n已验收前置成果摘录（完整内容见前置任务）：\n' || left(context,greatest(0,4800-length(s.description))) ELSE '' END,s.input->>'acceptance',s.assigned_agent_id,gen_random_uuid());
 UPDATE public.tasks SET input=input || jsonb_build_object('parent_plan_id',p.id,'assignment_id',s.id) WHERE id=work;
 UPDATE public.tasks SET result=jsonb_build_object('work_order_id',work),updated_at=now() WHERE id=s.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'plan_assignment.started','task',s.id::text,jsonb_build_object('work_order_id',work));
 RETURN work;
END $$;

CREATE FUNCTION public.review_work_plan(p_task uuid,p_revision integer,p_plan jsonb,p_approve boolean DEFAULT false) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid(); w public.tasks; step jsonb; ids uuid[]:='{}'; dependencies jsonb; aid uuid; sid uuid; i integer:=0;
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501'; END IF;
 SELECT * INTO w FROM public.tasks WHERE id=p_task AND created_by=uid AND task_kind='work_plan' FOR UPDATE;
 IF w.id IS NULL THEN RAISE EXCEPTION 'Plan denied' USING ERRCODE='42501'; END IF;
 IF w.result->>'stage'='approved' THEN
  IF p_approve THEN RETURN w.id; END IF;
  RAISE EXCEPTION 'Approved plan immutable' USING ERRCODE='22023';
 END IF;
 IF p_revision IS DISTINCT FROM (w.result->>'revision')::int THEN RAISE EXCEPTION 'Stale plan' USING ERRCODE='40001'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.tasks WHERE id=(w.result->>'current_job_id')::uuid AND created_by=uid AND execution_state='succeeded') THEN RAISE EXCEPTION 'Planning not finished' USING ERRCODE='22023'; END IF;
 PERFORM public.validate_cos_plan(p_plan);
 IF p_approve AND jsonb_array_length(p_plan->'missing_information')>0 THEN RAISE EXCEPTION 'Resolve missing information first' USING ERRCODE='22023'; END IF;
 UPDATE public.tasks SET result=result || jsonb_build_object('plan',p_plan,'revision',p_revision+1,'stage',CASE WHEN p_approve THEN 'approved' ELSE 'draft' END),updated_at=now() WHERE id=w.id;
 IF p_approve THEN
  FOR step IN SELECT value FROM jsonb_array_elements(p_plan->'tasks') LOOP
   SELECT id INTO aid FROM public.agents WHERE code=step->>'agent_code' AND is_active;
   SELECT coalesce(jsonb_agg(to_jsonb(ids[(value#>>'{}')::int+1])),'[]') INTO dependencies FROM jsonb_array_elements(step->'after');
   INSERT INTO public.tasks(title,description,task_kind,created_by,assigned_agent_id,input,result)
   VALUES(step->>'title',step->>'instruction','plan_assignment',uid,aid,jsonb_build_object('plan_id',w.id,'step_index',i,'acceptance',step->>'acceptance','dependencies',dependencies),'{}') RETURNING id INTO sid;
   ids:=array_append(ids,sid);i:=i+1;
  END LOOP;
  -- Approval starts only independent steps. Dependent steps require an explicit start after predecessor acceptance.
  FOREACH sid IN ARRAY ids LOOP
   IF EXISTS(SELECT 1 FROM public.tasks WHERE id=sid AND input->'dependencies'='[]'::jsonb) THEN PERFORM public.start_plan_assignment(sid); END IF;
  END LOOP;
 END IF;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id) VALUES('user',uid::text,CASE WHEN p_approve THEN 'work_plan.approved' ELSE 'work_plan.saved' END,'task',w.id::text);
 RETURN w.id;
END $$;
REVOKE ALL ON FUNCTION public.validate_cos_plan(jsonb),public.create_work_plan(text,text,uuid),public.review_work_plan(uuid,integer,jsonb,boolean),public.start_plan_assignment(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_work_plan(text,text,uuid),public.review_work_plan(uuid,integer,jsonb,boolean),public.start_plan_assignment(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;

