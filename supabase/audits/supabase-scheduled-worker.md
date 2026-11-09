# Supabase scheduled CTO Worker alternative

Render paid deployment cancelled by user on 2026-11-10. No Render running resource was created. Use existing Supabase tasks queue, leases and RPCs with a one-job-per-invocation Edge Function.

pg_cron and pg_net are available but were not installed at inspection; Vault is installed. Function handler requires a private random CTO_WORKER_TOKEN header, independent of publishable/service-role/Gemini keys. Store the trigger token in Edge Secrets and Vault. Keep built-in JWT verification on unless deployment requires a custom-token-only endpoint; disabling that gateway check is allowed only with the handler token check deployed and user confirmation. No browser can invoke the privileged worker without the secret token.

Cron checks for runnable/expired jobs before invoking, every minute. Adds up to about 60 seconds queue wait. Idle projects invoke no Edge Function; busy projects are bounded by one cron tick per minute plus explicit test calls. No self-invocation or unbounded while loop. Single invocation claims one persisted task, max model wait about 45 seconds, with bounded database fetch and heartbeat. Crashes recover through existing lease reaper and completion fencing.

Free plan currently includes 500,000 Edge Function invocations; maximum wall clock 150 seconds, CPU 2 seconds, memory 256MB. These are ceilings, not availability guarantees. Supabase Free projects can pause after inactivity. No plan upgrades or paid resources should be enabled. Gemini usage is separate and not guaranteed free.

Status: source and schedule draft prepared, not yet deployed or configured. Need secret setup, deployed Edge verification, scheduling activation, Codespaces Worker handoff, refresh/persistence and failure-recovery acceptance. Web UI still runs in Codespaces and is unavailable if that Codespace sleeps; cloud job execution is independent.

Rollback: unschedule cto-edge-worker, retain task records, and restore existing development Worker if necessary. Do not delete tasks/messages or manually mark tests succeeded.

References: https://supabase.com/docs/guides/functions/limits ; https://supabase.com/docs/guides/functions/schedule-functions ; https://supabase.com/pricing
