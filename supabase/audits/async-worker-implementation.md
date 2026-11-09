# Async CTO worker implementation

Implemented enqueue, claim, heartbeat, complete, fail, cancel and expired-lease recovery RPCs. Enqueue/cancel use authenticated JWT plus explicit CEO allowlist and ownership checks; worker RPCs are service_role-only. No browser receives service credentials or lease tokens. Completion stores reply, usage and audit in the same transaction.

Validated against isolated PostgreSQL 17 rebuilt from audited schema: non-CEO and cross-owner rejection, browser denied claim, repeated enqueue idempotency, stale-token denial, heartbeat, expired-worker recovery, atomic rollback on invalid usage insert, duplicate completion, transient retry, exhausted attempts, cancellation fencing. Two concurrent service-role connections obtained exactly one lease; four concurrent submissions returned one job. These use PostgreSQL roles and auth.uid backed by request.jwt.claim.sub; hosted Supabase JWT tests still follow deployment.

Run worker from ai-company-os-web: node --env-file=.env.local scripts/chat-worker.mjs. The process is independent of Next.js HTTP requests. SIGTERM/SIGINT finishes the current task then exits. A process supervisor is needed for production; Codespaces worker stops when the Codespace stops. Lease reaper resumes jobs when worker restarts. External provider calls can be billed more than once following crash; stored assistant reply is unique per task.

Frontend posts a task then polls without holding a model HTTP request. Reload resumes polling task history; the backend continues. The old synchronous reply endpoint is retained as an operational rollback path. Restore chat-client.tsx from commit ecffa42 and stop Worker to roll back UI behavior; retain additive schema and task/message records.

Deployment order: atomic SQL bundle 001+002+003, notify PostgREST to reload schema, verify hosted auth/ACL, start Worker, then E2E CTO test with refresh while pending and after completion. Do not start Worker before migration. No secrets are part of repository files.
