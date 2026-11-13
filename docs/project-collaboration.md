# Project-scoped executive collaboration

The CEO starts an agenda with two distinct project executives; plan assignees and COS are eligible. The first executive generates a question and the second replies. One round is the default and two is the maximum. Each project runs at most one active agenda. There is no ambient executive chatter, external messaging or new tool authority.

The durable chat queue handles each turn, with isolated conversations and a frozen project/accepted-delivery snapshot. Completion atomically stores the message and queues the next permitted turn. Idempotent task completion cannot duplicate turns. Failures use existing leases/retries; an explicit retry preserves attempt history up to ten attempts. A failed agenda can be closed without deleting its record.

Project text tasks may retrieve at most two short excerpts from completed discussions. References are pinned in the executing job on first retrieval and carry discussion/reply versions; retries cannot silently adopt newer answers. Discussions are advice, not approvals, accepted knowledge, executable instructions or proof of a working product. Existing results and project acceptance gates remain unchanged.

The first increment requires a CEO-created agenda. Autonomous detection of blockers and employee-initiated consultations remains future work. Stage and end-to-end verification remains manual.

Deploy the backward-compatible Worker before migration 013. When its context RPC is not yet present, old tasks continue without discussion references. Validate the migration with `supabase/tests/project_collaboration.sql` inside a rollback transaction, then publish the frontend.
