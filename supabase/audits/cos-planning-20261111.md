# COS planning acceptance — 2026-11-11 (Asia/Shanghai)

## Deployment

Production source a8f172b7205ad40e6c6a6b72aee830ae9d72e840, Render deploy dep-dbpl8k9srm7s73apho1g (live). Applied 202611110002_cos_planning.sql to the existing Supabase project. Worker and cron unchanged. No new paid services or secret transfers.

Added /plans and /api/work-plans. Homepage now routes business work through COS planning. The existing task center remains available for explicit direct assignments. Planning uses a distinct work_plan record and the existing durable chat reply queue. COS returns structured direct/single/team suggestions instead of producing the specialist deliverable. Drafts can be edited and saved with optimistic revision checks. CEO approval atomically creates plan_assignment records and starts only independent steps. Dependent steps require explicit start after predecessor work orders have been accepted. Start passes bounded excerpts of predecessor results to the next work order. Execution deep links open the correct task.

## Checks

- TypeScript noEmit and ESLint passed.
- Node parser tests passed (plain/fenced JSON, malformed output, unknown mode, malformed fields and invalid dependencies).
- Transactional SQL rollback suite passed: mode validation, future dependency and unknown assignee rejection, no dispatch before approval, unfinished-plan and missing-information guards, stale revision rejection, idempotent creation/approval/start, predecessor acceptance gating, result handoff, non-CEO rejection and execute privileges. Test fixtures rolled back.
- Four live planning requests: simple summary -> direct/COS; marketing copy -> single/CMO; product then marketing -> team/CPO then CMO with dependency; actual video editing/publication without assets/tools -> missing information and disabled approval. COS produced plans, not specialist deliverables.
- Confirmed all four plans had zero assignments before approval.
- Edited single-task acceptance criteria, saved, refreshed and confirmed persistence.
- Approved team test: exactly two assignments. CPO work created; CMO remained blocked until CPO result was accepted. Starting step 2 created exactly one CMO work order containing the accepted predecessor excerpt. CMO returned promotional copy.
- Final database counts: team approved, two assignments, two work orders, one accepted. CMO example deliberately left for human review, not automatically accepted. The other three examples remain draft with no execution tasks.
- Refresh and homepage planning navigation passed. Evidence screenshot: cos-planning-verified.png in the local workspace.

## Current boundaries

All plans, including direct suggestions, require CEO confirmation in this first version. Dependent steps require a manual start after predecessor acceptance. Available assignees are the existing text-capable executives; specialized tool employees and autonomous orchestration are not connected. Missing-information assertions are model suggestions editable by the CEO; they do not install or authorize tools. Quality and length constraints still require review, as generated CMO text includes commentary around the requested copy.
