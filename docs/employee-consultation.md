# One-shot employee blocker consultation

New delegated text work orders may ask their own executive for clarification when essential evidence is missing, acceptance conditions conflict, or an existing capability boundary is unclear. Straightforward work continues directly. Historical orders and COS direct tasks retain their existing behavior.

The employee model chooses whether to ask. This is a bounded text workflow, not a new tool permission: one consultation per work order, including CEO revisions and internal quality repairs. The manager receives only a frozen task/project/knowledge snapshot and the employee's question in an isolated conversation. No executive's private chat history is provided.

The request RPC checks the current employee, manager, order, owner and live source lease. It records model usage using the existing failure callback, clears the lease and parks the original execution at queued/infinity. This is an intentional wait, not an abandoned running lease. The question is not a delivery message and cannot trigger independent quality or acceptance. A unique work-order constraint and row locks prevent duplicate consultations; duplicate callbacks cannot add extra jobs.

The manager returns resume or needs_ceo. A transactional completion trigger stores the answer and either makes the same original execution available again, preserving attempts, or fails it with a needs-CEO reason. Resumed executions retrieve the fixed answer and cannot ask again. Missing user facts must not be invented. The completed delivery still enters independent quality and CEO review.

Manager execution failures use existing leases/retries. The CEO may retry a failed consultation up to ten recorded attempts or close it to release the paused execution into a recoverable failed state. Question, answer and retry state appear under the task's Internal collaboration section. No extra workbench is added.

Deploy the backward-compatible Worker first, apply migration 014 after rollback tests pass, then deploy the web app. Before the RPC exists the Worker disables employee consultation. Before the table exists the web API keeps returning old work orders. Existing project executive discussion remains CEO-initiated; cross-department automatic routing and generalized tool execution are future work.
