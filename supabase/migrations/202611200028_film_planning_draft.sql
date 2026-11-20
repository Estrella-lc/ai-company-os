-- Requires matching film-planning Worker module.
BEGIN;
CREATE TABLE public.film_workflows (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 created_by uuid NOT NULL REFERENCES auth.users(id),
 goal_id uuid NOT NULL UNIQUE REFERENCES public.company_goals(id),
 source_job uuid NOT NULL REFERENCES public.tasks(id),
 state text NOT NULL DEFAULT 'awaiting_worker' CHECK(state IN ('awaiting_worker','planning','reviewing','blocked','ready')),
 source_snapshot jsonb NOT NULL,
 employee_jobs jsonb NOT NULL DEFAULT '{}',
 storyboard jsonb,
 capability_review jsonb,
 last_error text,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.film_workflows ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.film_workflows FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.film_workflows TO authenticated,service_role;
CREATE POLICY film_owner_read ON public.film_workflows FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.is_company_ceo(auth.uid()));
CREATE FUNCTION public.request_film_planning(p_goal uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.company_goals;s public.tasks;f uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_company_ceo(auth.uid()) THEN RAISE EXCEPTION 'CEO required' USING ERRCODE='42501';END IF;
 SELECT * INTO g FROM public.company_goals WHERE id=p_goal AND created_by=auth.uid() FOR UPDATE;
 IF g.id IS NULL OR g.state<>'accepted' THEN RAISE EXCEPTION 'Accepted sample required' USING ERRCODE='42501';END IF;
 SELECT id INTO f FROM public.film_workflows WHERE goal_id=g.id AND created_by=g.created_by;
 IF f IS NOT NULL THEN RETURN f;END IF;
 SELECT * INTO s FROM public.tasks WHERE id=g.research_job AND created_by=g.created_by;
 IF s.execution_state IS DISTINCT FROM 'succeeded' OR s.result->'assets'->'image'->>'sha256' IS NULL OR s.result->'assets'->'voice'->>'sha256' IS NULL THEN RAISE EXCEPTION 'Verified source unavailable';END IF;
 INSERT INTO public.film_workflows(created_by,goal_id,source_job,source_snapshot)
 VALUES(g.created_by,g.id,s.id,jsonb_build_object('spec',g.selected_spec,'assets',s.result->'assets','reviews',g.review_jobs,'scope','still_image_edit','additional_paid_budget_usd',0)) RETURNING id INTO f;
 UPDATE public.film_workflows SET state='planning',employee_jobs=jsonb_build_object('storyboard',private.goal_reply(g.created_by,'CMO','员工分镜规划',jsonb_build_object('film_workflow_id',f,'film_phase','storyboard'))) WHERE id=f;
 RETURN f;
END $$;
REVOKE ALL ON FUNCTION public.request_film_planning(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.request_film_planning(uuid) TO authenticated;
CREATE FUNCTION public.advance_film_planning() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE f public.film_workflows;j public.tasks;p jsonb;n integer:=0;phase text;next_phase text;manager text;
BEGIN
 FOR f IN SELECT * FROM public.film_workflows WHERE state IN ('planning','reviewing') FOR UPDATE SKIP LOCKED LOOP
 BEGIN
  phase:=CASE WHEN f.employee_jobs?'inspection' THEN 'inspection' WHEN f.employee_jobs?'capabilities' THEN 'capabilities' ELSE 'storyboard' END;
  SELECT * INTO j FROM public.tasks WHERE id=(f.employee_jobs->>phase)::uuid AND created_by=f.created_by;
  IF j.id IS NULL THEN RAISE EXCEPTION 'Missing bound planning task';END IF;
  IF j.execution_state IN ('failed','cancelled') THEN RAISE EXCEPTION 'Employee planning failed';END IF;
  IF j.execution_state<>'succeeded' THEN CONTINUE;END IF;
  SELECT content::jsonb INTO p FROM public.messages WHERE reply_task_id=j.id;
  IF phase='storyboard' THEN
   UPDATE public.film_workflows SET storyboard=p WHERE id=f.id;next_phase:='capabilities';manager:='CTO';
  ELSIF phase='capabilities' THEN
   UPDATE public.film_workflows SET capability_review=p WHERE id=f.id;
   IF p->>'status' IS DISTINCT FROM 'ready' THEN RAISE EXCEPTION 'Capability gap requires research: %',p->>'summary';END IF;
   next_phase:='inspection';manager:='COO';
  ELSE
   IF p->>'verdict' IS DISTINCT FROM 'pass' THEN RAISE EXCEPTION 'Storyboard inspection requires revision: %',p->>'summary';END IF;
   UPDATE public.film_workflows SET state='ready',last_error=NULL WHERE id=f.id;n:=n+1;CONTINUE;
  END IF;
  UPDATE public.film_workflows SET state=CASE WHEN next_phase='inspection' THEN 'reviewing' ELSE 'planning' END,employee_jobs=employee_jobs||jsonb_build_object(next_phase,private.goal_reply(f.created_by,manager,'分镜员工 · '||next_phase,jsonb_build_object('film_workflow_id',f.id,'film_phase',next_phase),CASE WHEN next_phase='inspection' THEN 'quality_inspector' ELSE 'text_executor' END)) WHERE id=f.id;
  n:=n+1;
 EXCEPTION WHEN OTHERS THEN UPDATE public.film_workflows SET state='blocked',last_error=left(SQLERRM,300) WHERE id=f.id;
 END;
 END LOOP;RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.advance_film_planning() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.advance_film_planning() TO service_role;
COMMIT;
