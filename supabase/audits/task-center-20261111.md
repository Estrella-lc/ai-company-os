# Task center acceptance — 2026-11-11 (Asia/Shanghai)

## Scope

Added /tasks and /api/work-orders. Homepage task entry now opens the task center. Business tasks reuse public.tasks with task_kind=work_order and retain the existing chat_reply execution records. Existing scheduled Edge Worker and cron did not change. No new hosting services, secrets, or tables.

create_work_order atomically saves the brief and acceptance criteria, creates a CEO message, enqueues the executive reply, and links the execution to the business task. Request-key serialization prevents duplicate creates. review_work_order locks the business row and checks the current job before accepting or creating a revision. Accepted tasks are immutable through this review RPC. Prior versions and feedback remain available. Browser responses expose selected task fields and replies, not execution leases.

## Verification

- TypeScript noEmit and ESLint passed after correcting effect initialization.
- Production Render deploy dep-dbpkh8dg1s2s73dpeue0 is live, source 9e186d4ee7425ee02cc26ce3a2bd40be49c797bf.
- Migration 202611110001_work_orders.sql applied to the existing Supabase project.
- Rollback SQL test in supabase/tests/work_orders.sql passed: idempotent creation, rejection of premature acceptance and stale review, required revision feedback, preserved revision history, repeated acceptance, non-CEO create/review rejection, and no anonymous RPC execute.
- An additional transaction under SET LOCAL ROLE authenticated successfully called create_work_order with the CEO identity, then rolled back.
- Live browser example TASK-20261111: COS prepared a short-video text plan; first two versions were returned for excessive length and unsupported capability implications. Third version met the brief and was accepted as a system test example.
- Final database check: exactly one matching work order, review_state=accepted, three versions, three saved replies.
- Refresh preserved pending work, completed review, all three deliverables and feedback. Homepage navigation to /tasks passed.

## Limits and next step

This version handles text deliverables and human review. It does not automatically split work between executives or execute editing/development tools. Acceptance criteria are reviewed by the CEO, not automatically enforced by a quality evaluator. Existing minute-based single-job invocation scheduling can cause queuing. The next increment is proposed subtasks from COS, followed by CEO-approved assignment to executives; tool-based execution comes later.
