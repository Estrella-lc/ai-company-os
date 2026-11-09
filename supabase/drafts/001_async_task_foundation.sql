-- DRAFT ONLY. Audited project mcwkkmkgfienxrmfyvfl, 2026-11-09.
-- Review and test against a disposable database before promoting to migrations/.
-- Existing tasks.status and all historical rows remain unchanged.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
ALTER TABLE public.tasks
 ADD COLUMN task_kind text,
 ADD COLUMN execution_state text,
 ADD COLUMN conversation_id uuid REFERENCES public.conversations(id) ON DELETE RESTRICT,
 ADD COLUMN request_message_id uuid,
 ADD COLUMN request_key uuid,
 ADD COLUMN input jsonb NOT NULL DEFAULT '{}'::jsonb,
 ADD COLUMN result jsonb,
 ADD COLUMN attempt_count integer NOT NULL DEFAULT 0,
 ADD COLUMN max_attempts integer NOT NULL DEFAULT 3,
 ADD COLUMN available_at timestamptz NOT NULL DEFAULT now(),
 ADD COLUMN lease_token uuid,
 ADD COLUMN lease_expires_at timestamptz,
 ADD COLUMN started_at timestamptz,
 ADD COLUMN finished_at timestamptz,
 ADD COLUMN last_error_code text,
 ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
 ADD CONSTRAINT tasks_execution_state_check CHECK (execution_state IS NULL OR execution_state IN ('queued','running','succeeded','failed','cancelled')),
 ADD CONSTRAINT tasks_attempts_check CHECK (attempt_count >= 0 AND max_attempts BETWEEN 1 AND 10 AND attempt_count <= max_attempts),
 ADD CONSTRAINT tasks_lease_check CHECK ((execution_state = 'running' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL) OR (execution_state IS DISTINCT FROM 'running' AND lease_token IS NULL AND lease_expires_at IS NULL)),
 ADD CONSTRAINT tasks_async_shape_check CHECK (task_kind IS DISTINCT FROM 'chat_reply' OR (execution_state IS NOT NULL AND conversation_id IS NOT NULL AND request_message_id IS NOT NULL AND request_key IS NOT NULL AND created_by IS NOT NULL AND assigned_agent_id IS NOT NULL)),
 ADD CONSTRAINT tasks_terminal_time_check CHECK (execution_state IS NULL OR ((execution_state IN ('succeeded','failed','cancelled')) = (finished_at IS NOT NULL)));
-- Composite FK prevents pairing a request with a different conversation.
ALTER TABLE public.messages ADD CONSTRAINT messages_id_conversation_unique UNIQUE(id,conversation_id);
ALTER TABLE public.tasks ADD CONSTRAINT tasks_request_message_conversation_fk FOREIGN KEY(request_message_id,conversation_id) REFERENCES public.messages(id,conversation_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX tasks_chat_request_unique ON public.tasks(request_message_id) WHERE task_kind='chat_reply';
CREATE UNIQUE INDEX tasks_owner_request_key_unique ON public.tasks(created_by,request_key) WHERE request_key IS NOT NULL;
CREATE INDEX tasks_claim_idx ON public.tasks(available_at,created_at,id) WHERE task_kind='chat_reply' AND execution_state='queued';
CREATE INDEX tasks_expired_lease_idx ON public.tasks(lease_expires_at) WHERE execution_state='running';
CREATE INDEX tasks_owner_created_idx ON public.tasks(created_by,created_at DESC);
CREATE INDEX messages_conversation_created_idx ON public.messages(conversation_id,created_at,id);
CREATE INDEX conversations_owner_agent_idx ON public.conversations(created_by,agent_id);
-- The completion transaction inserts one assistant message per task.
ALTER TABLE public.messages ADD COLUMN reply_task_id uuid REFERENCES public.tasks(id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX messages_reply_task_unique ON public.messages(reply_task_id) WHERE reply_task_id IS NOT NULL;
ALTER TABLE public.messages ADD CONSTRAINT messages_task_sender_check CHECK(reply_task_id IS NULL OR (sender_type='assistant' AND sender_agent_id IS NOT NULL));
-- Job usage correlation; old records remain valid.
ALTER TABLE public.model_usage
 ADD COLUMN task_id uuid REFERENCES public.tasks(id) ON DELETE SET NULL,
 ADD COLUMN attempt_number integer,
 ADD COLUMN duration_ms integer,
 ADD COLUMN call_status text,
 ADD COLUMN provider_request_id text,
 ADD CONSTRAINT model_usage_attempt_check CHECK(attempt_number IS NULL OR attempt_number >= 1),
 ADD CONSTRAINT model_usage_duration_check CHECK(duration_ms IS NULL OR duration_ms >= 0);
CREATE INDEX model_usage_task_idx ON public.model_usage(task_id);
COMMIT;
