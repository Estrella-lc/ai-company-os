# Independent text quality

New text work orders require an independent quality report for their current delivery version before CEO acceptance. A separate `quality_inspector` employee uses an isolated conversation and the existing durable queue, models and provider fallback. It receives a fixed source text, task goal/criteria and project context when already attached. It has no execution tools and cannot validate a running application or a full business workflow. A `needs_human` report with no explicit failing checks can be accepted only with at least 20 characters of CEO-provided manual verification evidence; a definite failing report cannot use that path.

The report must contain all three checks: task goal, task acceptance and truthful execution claims. Passing checks require exact source quotes. Invalid reports or oversized text fail conservatively to `needs_human`, never pass. Reports cannot accept work orders or project gates. Only the CEO acceptance RPC can archive accepted deliveries.

A definite `revise` verdict on a new, current and unaccepted delivery queues at most one automatic internal repair per work order. The next version gets its own inspection. Further revisions require CEO input. Historical or already accepted tasks are not retroactively gated or rewritten; they can be explicitly inspected. Inspection results remain linked to their source version even if a newer delivery appears.

Retries use the existing leases, reaper and provider retry limits. An explicit CEO retry of a failed inspection increases its permitted attempt ceiling by one, up to ten total attempts; it does not reset attempt history. No extra paid service, repository write permission or generated-code execution is added.

Migration 012 must follow 011 and the worker supporting `text_quality_v1` must be deployed before enabling the migration's automatic trigger. Run `supabase/tests/independent_text_quality.sql` inside the migration transaction without COMMIT for rollback validation. Tests include separate identity, version binding, acceptance restrictions, exact evidence, leases, idempotent completion, bounded repairs, role restrictions and RLS.
