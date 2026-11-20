BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.company_goals(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id),request_key uuid NOT NULL,
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 120),goal text NOT NULL CHECK(length(goal) BETWEEN 1 AND 3000),
 state text NOT NULL DEFAULT 'comparing' CHECK(state IN ('comparing','choosing','researching','reviewing','ready','blocked','accepted')),
 proposal_jobs jsonb NOT NULL DEFAULT '{}',proposals jsonb NOT NULL DEFAULT '[]',selected_job uuid REFERENCES public.tasks(id),selected_spec jsonb,
 research_job uuid REFERENCES public.tasks(id),review_jobs jsonb NOT NULL DEFAULT '{}',review jsonb,last_error text,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(created_by,request_key));
ALTER TABLE public.company_goals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_goals FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.company_goals TO authenticated,service_role;
CREATE POLICY goal_ceo_read ON public.company_goals FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('company-creative','company-creative',false,2000000,ARRAY['image/png','audio/wav']);
CREATE POLICY creative_owner_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='company-creative' AND public.is_company_ceo(auth.uid()) AND EXISTS(
 SELECT 1 FROM public.company_goals g JOIN public.tasks j ON j.id=g.research_job WHERE g.created_by=auth.uid() AND j.execution_state='succeeded' AND name IN (j.result->'assets'->>'image_path',j.result->'assets'->>'voice_path')));

CREATE FUNCTION private.goal_reply(p_owner uuid,p_code text,p_title text,p_input jsonb,p_role text DEFAULT 'text_executor') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE manager uuid;employee uuid;c uuid;m uuid;j uuid;
BEGIN
 SELECT id INTO manager FROM public.agents WHERE code=p_code AND is_active;
 IF manager IS NULL THEN RAISE EXCEPTION 'Goal manager unavailable' USING ERRCODE='22023';END IF;
 INSERT INTO public.ai_employees(created_by,manager_agent_id,name,role) VALUES(p_owner,manager,p_code||CASE WHEN p_role='quality_inspector' THEN ' 独立样例质检员' ELSE ' 方案与执行员工' END,p_role) ON CONFLICT(created_by,manager_agent_id,role) DO NOTHING;
 SELECT id INTO employee FROM public.ai_employees WHERE created_by=p_owner AND manager_agent_id=manager AND role=p_role;
 INSERT INTO public.conversations(agent_id,conversation_type,title,created_by) VALUES(manager,'direct',left(p_title,120),p_owner) RETURNING id INTO c;
 INSERT INTO public.messages(conversation_id,sender_type,content) VALUES(c,'user','按本目标固定输入完成职责范围内的提案或独立检查，不冒充实际执行，不做CEO验收。') RETURNING id INTO m;
 INSERT INTO public.tasks(title,task_kind,execution_state,created_by,assigned_agent_id,conversation_id,request_message_id,request_key,input)
 VALUES(left(p_title,120),'chat_reply','queued',p_owner,manager,c,m,gen_random_uuid(),p_input||jsonb_build_object('creative_employee_id',employee)) RETURNING id INTO j;
 RETURN j;
END $$;
CREATE FUNCTION public.create_company_goal(p_title text,p_goal text,p_key uuid,p_consent boolean) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE uid uuid:=auth.uid();g uuid;j uuid;perspective text;code text;jobs jsonb:='{}';
BEGIN
 IF uid IS NULL OR NOT public.is_company_ceo(uid) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 IF p_consent IS DISTINCT FROM true OR p_key IS NULL OR coalesce(length(trim(p_title)),0) NOT BETWEEN 1 AND 120 OR coalesce(length(trim(p_goal)),0) NOT BETWEEN 1 AND 3000 THEN RAISE EXCEPTION 'Invalid goal or consent' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(uid::text||':company_goals',0));
 SELECT id INTO g FROM public.company_goals WHERE created_by=uid AND request_key=p_key;IF g IS NOT NULL THEN RETURN g;END IF;
 IF (SELECT count(*) FROM public.company_goals WHERE created_by=uid)>=20 THEN RAISE EXCEPTION 'Goal storage cap' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.company_goals WHERE created_by=uid AND created_at>=date_trunc('day',now()))>=3 THEN RAISE EXCEPTION 'Daily goal cap' USING ERRCODE='22023';END IF;
 INSERT INTO public.company_goals(created_by,request_key,title,goal) VALUES(uid,p_key,trim(p_title),trim(p_goal)) RETURNING id INTO g;
 FOREACH perspective IN ARRAY ARRAY['creative','production','technical'] LOOP
  code:=CASE perspective WHEN 'creative' THEN 'CMO' WHEN 'production' THEN 'COO' ELSE 'CTO' END;
  j:=private.goal_reply(uid,code,'目标方案 · '||p_title,jsonb_build_object('creative_goal_id',g,'creative_perspective',perspective));jobs:=jobs||jsonb_build_object(perspective,j);
 END LOOP;
 UPDATE public.company_goals SET proposal_jobs=jobs WHERE id=g;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',uid::text,'goal.created','company_goal',g::text,'{"model_consent":true,"additional_paid_budget_usd":0,"sample_only":true}');RETURN g;
END $$;
CREATE FUNCTION public.select_company_goal_proposal(p_goal uuid,p_job uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.company_goals;p jsonb;j uuid;manager uuid;employee uuid;s public.agent_skills;reusable jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO g FROM public.company_goals WHERE id=p_goal AND created_by=auth.uid() FOR UPDATE;
 IF g.id IS NULL THEN RAISE EXCEPTION 'Goal denied' USING ERRCODE='42501';END IF;
 IF g.selected_job=p_job THEN RETURN true;END IF;
 IF g.state<>'choosing' OR g.selected_job IS NOT NULL THEN RAISE EXCEPTION 'Goal direction locked' USING ERRCODE='40001';END IF;
 SELECT value INTO p FROM jsonb_array_elements(g.proposals) WHERE value->>'job_id'=p_job::text;
 IF p IS NULL OR NOT EXISTS(SELECT 1 FROM public.tasks t JOIN public.messages m ON m.reply_task_id=t.id WHERE t.id=p_job AND t.created_by=g.created_by AND t.execution_state='succeeded' AND m.content::jsonb=p->'proposal') THEN RAISE EXCEPTION 'Stale proposal' USING ERRCODE='40001';END IF;
 SELECT id INTO manager FROM public.agents WHERE code='CTO' AND is_active;
 INSERT INTO public.ai_employees(created_by,manager_agent_id,name,role) VALUES(g.created_by,manager,'CTO 能力研究与执行员工','skill_researcher') ON CONFLICT(created_by,manager_agent_id,role) DO NOTHING;
 SELECT id INTO employee FROM public.ai_employees WHERE created_by=g.created_by AND manager_agent_id=manager AND role='skill_researcher';
 SELECT * INTO s FROM public.agent_skills WHERE created_by=g.created_by AND capability='character_reference' AND status='verified_limited' AND metadata->>'adapter'='company_creative_cpu_v1' AND verification->>'scope'='character_reference_cpu_v1' AND verification->>'passed'='true' ORDER BY created_at DESC LIMIT 1;
 IF s.id IS NOT NULL AND EXISTS(SELECT 1 FROM public.agent_skills v WHERE v.created_by=g.created_by AND v.capability='mandarin_tts' AND v.status='verified_limited' AND v.verification->>'passed'='true' AND v.metadata->'manifest'=s.metadata->'manifest') THEN reusable:=s.metadata->'manifest';END IF;
 INSERT INTO public.tasks(title,description,task_kind,execution_state,created_by,assigned_agent_id,request_key,max_attempts,input)
 VALUES('能力验证与样例 · '||left(g.title,80),'按选定方案搜索、验证并调用成熟角色图与普通话技术；样例需独立检查后才登记复用。','skill_research','queued',g.created_by,manager,gen_random_uuid(),2,
 jsonb_build_object('mode','creative_samples','creative_goal_id',g.id,'capability','creative_samples','query','image speech generation agent skills','employee_id',employee,'spec',p->'proposal','reuse_manifest',reusable)) RETURNING id INTO j;
 UPDATE public.company_goals SET selected_job=p_job,selected_spec=p->'proposal',research_job=j,state='researching',updated_at=now() WHERE id=g.id;
 INSERT INTO public.audit_logs(actor_type,actor_id,action,resource_type,resource_id,details) VALUES('user',auth.uid()::text,'goal.proposal_selected','company_goal',g.id::text,jsonb_build_object('proposal_job',p_job,'research_job',j,'reused',reusable IS NOT NULL));RETURN true;
END $$;
CREATE FUNCTION public.creative_task_context(p_task uuid,p_token uuid,p_runner text) RETURNS SETOF public.tasks LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT j.* FROM public.tasks j JOIN public.company_goals g ON g.research_job=j.id AND g.created_by=j.created_by
 WHERE j.id=p_task AND j.task_kind='skill_research' AND j.input->>'mode'='creative_samples' AND j.execution_state='running' AND j.lease_token=p_token AND j.lease_expires_at>now() AND j.input->>'runner_id'=p_runner;
$$;
CREATE FUNCTION public.finish_creative_samples(p_task uuid,p_token uuid,p_runner text,p_report jsonb,p_failed boolean DEFAULT false) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.tasks;prefix text;
BEGIN
 SELECT * INTO j FROM public.tasks WHERE id=p_task AND task_kind='skill_research' AND input->>'mode'='creative_samples' FOR UPDATE;
 IF j.id IS NULL OR j.input->>'runner_id' IS DISTINCT FROM p_runner THEN RETURN false;END IF;
 IF j.execution_state IN ('succeeded','failed') THEN RETURN j.result->>'lease_token'=p_token::text;END IF;
 IF j.execution_state<>'running' OR j.lease_token IS DISTINCT FROM p_token OR j.lease_expires_at<=now() THEN RETURN false;END IF;
 prefix:=j.created_by::text||'/'||j.id::text||'/'||p_token::text||'/';
 IF NOT p_failed AND (jsonb_typeof(p_report) IS DISTINCT FROM 'object' OR length(p_report::text)>150000 OR p_report->'assets'->>'image_path' IS DISTINCT FROM prefix||'character.png' OR p_report->'assets'->>'voice_path' IS DISTINCT FROM prefix||'voice.wav' OR coalesce(p_report->>'adapter_commit','') !~ '^[a-f0-9]{40}$' OR p_report->'verification'->>'passed' IS DISTINCT FROM 'true' OR p_report->'verification'->'isolation' IS DISTINCT FROM '{"network_disabled":true,"root_read_only":true,"unprivileged":true,"secrets_absent":true}'::jsonb OR (SELECT count(*) FROM storage.objects WHERE bucket_id='company-creative' AND name IN(prefix||'character.png',prefix||'voice.wav') AND (metadata->>'size')::bigint BETWEEN 44 AND 2000000)<>2) THEN RAISE EXCEPTION 'Creative output evidence invalid' USING ERRCODE='22023';END IF;
 UPDATE public.tasks SET execution_state=CASE WHEN p_failed THEN 'failed' ELSE 'succeeded' END,finished_at=now(),lease_token=NULL,lease_expires_at=NULL,last_error_code=CASE WHEN p_failed THEN 'creative_validation_failed' ELSE NULL END,result=p_report||jsonb_build_object('lease_token',p_token),updated_at=now() WHERE id=j.id;
 RETURN true;
END $$;
CREATE FUNCTION public.advance_company_goals() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.company_goals;j public.tasks;entry record;p jsonb;v_proposals jsonb;kind text;jid uuid;jobs jsonb;report jsonb;all_pass boolean;saved public.tasks;profile text;manager uuid;employee uuid;n integer:=0;
BEGIN
 FOR g IN SELECT * FROM public.company_goals WHERE state IN ('comparing','researching','reviewing') ORDER BY created_at LIMIT 10 FOR UPDATE SKIP LOCKED LOOP
 BEGIN
  IF g.state='comparing' THEN
   v_proposals:='[]';
   FOR entry IN SELECT * FROM jsonb_each_text(g.proposal_jobs) LOOP
    SELECT * INTO j FROM public.tasks WHERE id=entry.value::uuid AND created_by=g.created_by;
    IF j.execution_state IN ('failed','cancelled') THEN RAISE EXCEPTION '方案员工执行失败，保留记录等待恢复';END IF;
    IF j.execution_state<>'succeeded' THEN CONTINUE;END IF;
    SELECT content::jsonb INTO p FROM public.messages WHERE reply_task_id=j.id;
    IF coalesce(length(p->>'title'),0) NOT BETWEEN 1 AND 60 OR coalesce(length(p->>'image_prompt_en'),0) NOT BETWEEN 20 AND 1200 OR coalesce(length(p->>'voice_text'),0) NOT BETWEEN 8 AND 80 THEN RAISE EXCEPTION '方案结构未通过验证';END IF;
    v_proposals:=v_proposals||jsonb_build_array(jsonb_build_object('perspective',entry.key,'job_id',j.id,'employee_id',j.input->>'creative_employee_id','proposal',p));
   END LOOP;
   IF jsonb_array_length(v_proposals)=3 THEN UPDATE public.company_goals SET state='choosing',proposals=v_proposals,updated_at=now() WHERE id=g.id;END IF;
  ELSIF g.state='researching' THEN
   SELECT * INTO saved FROM public.tasks WHERE id=g.research_job AND created_by=g.created_by;
   IF saved.execution_state IN ('failed','cancelled') THEN RAISE EXCEPTION '搜索或样例执行未通过，未登记能力';END IF;
   IF saved.execution_state<>'succeeded' THEN CONTINUE;END IF;
   jobs:='{}';
   FOREACH kind IN ARRAY ARRAY['image','voice'] LOOP
    jid:=private.goal_reply(g.created_by,'COO','独立样例质检 · '||kind||' · '||g.title,jsonb_build_object('creative_goal_id',g.id,'creative_review_kind',kind,'creative_source_job',saved.id),'quality_inspector');jobs:=jobs||jsonb_build_object(kind,jid);
   END LOOP;
   UPDATE public.company_goals SET state='reviewing',review_jobs=jobs,updated_at=now() WHERE id=g.id;
  ELSE
   all_pass:=true;
   FOREACH kind IN ARRAY ARRAY['image','voice'] LOOP
    SELECT * INTO j FROM public.tasks WHERE id=(g.review_jobs->>kind)::uuid AND created_by=g.created_by;
    IF j.execution_state IN ('failed','cancelled') THEN RAISE EXCEPTION '独立样例质检调用失败';END IF;
    IF j.execution_state<>'succeeded' THEN all_pass:=false;CONTINUE;END IF;
    SELECT content::jsonb INTO report FROM public.messages WHERE reply_task_id=j.id;
    IF report->>'verdict'<>'pass' THEN RAISE EXCEPTION '独立样例检查未通过：%',kind;END IF;
    IF jsonb_array_length(report->'checks')<>3 OR EXISTS(SELECT 1 FROM jsonb_array_elements(report->'checks') c WHERE c->>'status' IS DISTINCT FROM 'pass' OR coalesce(length(c->>'evidence'),0)=0) OR (SELECT count(DISTINCT c->>'id') FROM jsonb_array_elements(report->'checks') c WHERE c->>'id'=ANY(CASE WHEN kind='image' THEN ARRAY['character','clarity','brief'] ELSE ARRAY['speech','fidelity','audio_quality'] END))<>3 THEN RAISE EXCEPTION '样例质检证据不完整';END IF;
    IF j.input->>'creative_employee_id'=(SELECT input->>'employee_id' FROM public.tasks WHERE id=g.research_job) OR j.input->>'creative_employee_id'=ANY(SELECT value->>'employee_id' FROM jsonb_array_elements(g.proposals)) THEN RAISE EXCEPTION '执行员工不得自检';END IF;
   END LOOP;
   IF all_pass THEN
    SELECT * INTO saved FROM public.tasks WHERE id=g.research_job;
    SELECT assigned_agent_id,(input->>'employee_id')::uuid INTO manager,employee FROM public.tasks WHERE id=g.research_job;
    FOREACH kind IN ARRAY ARRAY['image','voice'] LOOP
     profile:=CASE kind WHEN 'image' THEN 'character_reference_cpu_v1' ELSE 'mandarin_tts_cpu_v1' END;
     INSERT INTO public.agent_skills(created_by,manager_agent_id,employee_id,request_task_id,repository,commit_sha,skill_path,name,description,capability,status,document,metadata,verification)
     VALUES(g.created_by,manager,employee,saved.id,'Estrella-lc/ai-company-os',saved.result->>'adapter_commit','skills/creative-samples/SKILL.md',CASE kind WHEN 'image' THEN 'CPU虚构成年角色参考图' ELSE '固定普通话配音样例' END,'成熟技术隔离生成、真实文件核验与独立质检通过；仅限样例范围。',CASE kind WHEN 'image' THEN 'character_reference' ELSE 'mandarin_tts' END,'verified_limited','公司固定成熟技术适配器：角色参考图或固定普通话语音；需保留技术、来源、产物哈希和独立质检证据。',jsonb_build_object('adapter','company_creative_cpu_v1','manifest',saved.result->'manifest','license','upstream_model_terms','limitations',saved.result->'verification'->'limitations'),jsonb_build_object('scope',profile,'passed',true,'source_job',saved.id,'independent_review_job',g.review_jobs->>kind,'artifacts',saved.result->'assets','run_url',saved.result->>'run_url'))
     ON CONFLICT(created_by,manager_agent_id,repository,commit_sha,skill_path,capability) DO UPDATE SET verification=excluded.verification,metadata=excluded.metadata;
    END LOOP;
    UPDATE public.company_goals SET state='ready',last_error=NULL,updated_at=now() WHERE id=g.id;
   END IF;
  END IF;
  n:=n+1;
 EXCEPTION WHEN OTHERS THEN UPDATE public.company_goals SET state='blocked',last_error=left(SQLERRM,300),updated_at=now() WHERE id=g.id;
 END;
 END LOOP;RETURN n;
END $$;
CREATE FUNCTION public.retry_company_goal(p_goal uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.company_goals;n integer:=0;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO g FROM public.company_goals WHERE id=p_goal AND created_by=auth.uid() FOR UPDATE;
 IF g.id IS NULL OR g.state<>'blocked' THEN RETURN false;END IF;
 UPDATE public.tasks SET execution_state='queued',finished_at=NULL,available_at=now(),max_attempts=greatest(max_attempts,attempt_count+1),updated_at=now()
 WHERE created_by=g.created_by AND execution_state='failed' AND last_error_code='provider_unavailable' AND attempt_count<6 AND id IN(SELECT value::uuid FROM jsonb_each_text(g.proposal_jobs||g.review_jobs));
 GET DIAGNOSTICS n=ROW_COUNT;IF n=0 THEN RETURN false;END IF;
 UPDATE public.company_goals SET state=CASE WHEN g.selected_job IS NULL THEN 'comparing' ELSE 'reviewing' END,last_error=NULL,updated_at=now() WHERE id=g.id;RETURN true;
END $$;
CREATE FUNCTION public.accept_company_goal(p_goal uuid,p_research uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 UPDATE public.company_goals SET state='accepted',review=jsonb_build_object('state','accepted','at',now()),updated_at=now() WHERE id=p_goal AND created_by=auth.uid() AND state='ready' AND research_job=p_research;
 RETURN found;
END $$;
REVOKE ALL ON FUNCTION private.goal_reply(uuid,text,text,jsonb,text),public.create_company_goal(text,text,uuid,boolean),public.select_company_goal_proposal(uuid,uuid),public.creative_task_context(uuid,uuid,text),public.finish_creative_samples(uuid,uuid,text,jsonb,boolean),public.advance_company_goals(),public.retry_company_goal(uuid),public.accept_company_goal(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.create_company_goal(text,text,uuid,boolean),public.select_company_goal_proposal(uuid,uuid),public.retry_company_goal(uuid),public.accept_company_goal(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.creative_task_context(uuid,uuid,text),public.finish_creative_samples(uuid,uuid,text,jsonb,boolean),public.advance_company_goals() TO service_role;
DO $patch$
DECLARE d text;
BEGIN
 d:=pg_get_functiondef('private.business_dispatch_ready()'::regprocedure);
 EXECUTE replace(d,'SELECT EXISTS(','SELECT EXISTS(SELECT 1 FROM public.company_goals g WHERE (g.state=''comparing'' AND EXISTS(SELECT 1 FROM jsonb_each_text(g.proposal_jobs) p JOIN public.tasks j ON j.id=p.value::uuid WHERE j.execution_state IN (''succeeded'',''failed'',''cancelled''))) OR (g.state=''researching'' AND EXISTS(SELECT 1 FROM public.tasks j WHERE j.id=g.research_job AND j.execution_state IN (''succeeded'',''failed'',''cancelled''))) OR (g.state=''reviewing'' AND NOT EXISTS(SELECT 1 FROM jsonb_each_text(g.review_jobs) p JOIN public.tasks j ON j.id=p.value::uuid WHERE j.execution_state IN (''queued'',''running'')))) OR EXISTS(');
END $patch$;
NOTIFY pgrst,'reload schema';
COMMIT;
