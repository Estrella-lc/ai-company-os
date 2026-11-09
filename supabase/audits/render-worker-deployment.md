# Render CTO Worker deployment

The render.yaml Blueprint provisions only one continuously running background worker, no database or public web service. Compute plan 0.5c-512mb: advertised approximately USD 7/month as checked 2026-11-09, excluding provider, egress, build and other charges. Confirm actual dashboard price and billing before creation. Manual deployments prevent unrelated pushes from restarting Worker.

Required runtime secrets (set in Render, never commit): NEXT_PUBLIC_SUPABASE_URL, SUPABASE_SECRET_KEY, GEMINI_API_KEY. Keys grant Render-hosted code access to the existing database and Gemini project; transfer only with user approval. Keep the worker service private with no HTTP endpoint. Start command uses injected environment, not .env.local.

Handoff: deploy and confirm WORKER_STARTED; stop only the known Codespaces Worker process after Render successfully polls. Keep Next.js running for UI checks, submit one uniquely marked CTO message, verify completion using Render logs and Supabase task/reply records. To prove independence, queue an authorized test before stopping Codespace and inspect completion in Supabase. A Codespaces-hosted Next.js UI itself is unavailable while Codespace sleeps; always-available UI hosting is separate from this Worker deployment.

Recovery acceptance: restart or redeploy Render Worker during one test job. Confirm persisted task recovers with a fresh lease after expiry and stores exactly one reply. Never reset task state manually to manufacture success. Restore Codespaces Worker only if Render has been stopped and service rollback is necessary. Provider calls can incur duplicate billing after crashes although persisted reply is unique.

Outstanding: Render account connection, repository access, user approval of final charges and secret transfer, real deployment, Codespaces-independent execution and recovery acceptance. Do not claim deployment from configuration alone.
