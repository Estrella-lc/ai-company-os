# CTO async deployment acceptance

Project mcwkkmkgfienxrmfyvfl. Deployed with explicit user approval on 2026-11-09. Applied foundation, access hardening and RPC SQL as one transaction, followed by PostgREST schema reload. SQL editor returned success.

Real CEO browser submitted ASYNC-20261109-01; task enqueue endpoint returned HTTP 202 in 576 ms. Browser was refreshed while work was pending. Independent Worker continued and persisted exactly one assistant reply. A second refresh after completion retained the reply. Task 28380286-cfb4-484b-b96a-ef8f46f867e8 succeeded on attempt 1 with cleared lease. Queue and success audit records were verified using read-only SQL. Primary model timed out, fallback succeeded. Actual measured usage: 637 input / 20 output tokens. Unknown usage/cost remains NULL. No model_usage/audit SELECT grant was added to service_role merely for verification; privileged dashboard SQL was used instead.

Live checks: anon cannot TRUNCATE tasks; authenticated cannot execute claim RPC; authenticated can execute enqueue, which independently verifies CEO and resource ownership. Non-CEO/cross-owner and stale-worker behavior was tested in isolated PostgreSQL with simulated JWT subject; no additional real user accounts were created for testing.

Worker started in original Codespace using npm run worker equivalent, process PID recorded only in /tmp/ai-company-worker.pid. This is a development deployment: when Codespaces suspends, Worker stops. Persisted jobs remain in Supabase and expired leases recover on restart. Production always-on process supervision is a separate deployment task.

Validation: TypeScript, ESLint, Worker syntax, authorization/atomic rollback/recovery SQL assertions, multi-connection claim and enqueue races passed. Temporary database fixtures were isolated and removed with the test container.
