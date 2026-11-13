# Project center, first increment

Projects group a CEO goal, business success criteria, end-to-end verification criteria and one to eight ordered acceptance stages. Criteria are specific to each project. Existing COS plans retain their approval and durable execution behavior; project creation itself makes no model calls.

A project can request COS planning, or attach one existing approved plan. Every assignment in that plan must be mapped to exactly one project stage. Independent tasks may execute in parallel according to their existing task dependencies. Stage acceptance proceeds in order and does not automatically execute other stages.

## Acceptance gates

1. A stage can pass only when all its linked work orders have been CEO accepted and all prior stages have passed. Stages without linked tasks require explicit manual evidence too.
2. End-to-end verification can pass only after every stage passes and all linked work orders are accepted. Record the actual input-to-delivery scenario, failure/recovery checks and evidence locations.
3. Final business acceptance requires the previous gates and a CEO decision with evidence.

Checks are append-only reports with criteria and work-order/job version snapshots. The actor is explicitly `ceo_manual`. These records are not autonomous AI quality inspections. Reconfiguring stage criteria or bindings resets all gates, and rechecking an upstream stage invalidates downstream gates. Prior reports remain historical. An accepted project is immutable in this increment.

## Access and recovery

CEO-scoped RLS permits reading owned records. Browser roles cannot directly write either table; dedicated RPCs enforce ownership, project/plan/assignment bindings, row locking and optimistic revisions. The service worker receives no new privileges. Request keys prevent duplicate project creation. Project-scoped task reads avoid relying only on the latest 50 standalone plans.

Migration: `202611130011_company_projects.sql`. Does not depend on unapplied migrations 006/007. Rollback verification: run the migration without its final COMMIT, followed by `supabase/tests/company_projects.sql` without its initial BEGIN; tests end in ROLLBACK. No synthetic queue records survive that test.

## Next increments

- Independent specialist quality employees producing reports bound to concrete delivery versions, with bounded internal rework before CEO final review.
- Task-scoped executive requests/replies, decision summaries, budget/round caps and an auditable event trail.
- Typed adapters for media, mature tools and product environments. The first increment links COS text work orders; it does not claim arbitrary product deployment, external operations or end-to-end automation.
- Editable/versioned project charters and pagination for larger histories.
