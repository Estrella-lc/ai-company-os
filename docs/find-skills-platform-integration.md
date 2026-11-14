# Platform capability discovery policy

The user's local `find-skills` skill was confirmed readable at `C:/Users/16964/.codex/skills/find-skills/SKILL.md` on 2026-11-14. This is installed in the coding assistant, not automatically in the hosted company workers.

When a company employee identifies a capability gap, prefer the find-skills discovery workflow: check the skills.sh catalog, search relevant skills and source repositories, inspect reputation and license, pin the source version, and validate a representative task before registering a shared company capability. Installation counts and stars are discovery signals, never evidence of task quality or authority to execute scripts.

The existing `scripts/skill-discovery.mjs` already checks skills.sh before fetching fixed GitHub skill documents. The hosted `skill-runner.mjs` invokes it for queued skill-research work. This is a company adaptation, not an invocation of the user's locally installed skill or unrestricted `npx skills add`.

The lifecycle implementation in migration 016 parks a leased employee execution, enqueues one deduplicated research request per order, and handles its terminal result. Only validated limited SRT capabilities can currently resume work; other candidates report missing applicable validation rather than claiming mastery. Existing verified SRT skills can be reused across managers within the same company. Missing price/customer decisions still use manager consultation, not skill search. Results appear in the task and the skill research center. The workflow is scheduled every two hours and retains the existing three daily claims and $0 overage budget.

Keep existing runner budgets and approvals. Never install candidate scripts into production or grant credentials solely because a skill document requests it. Reuse validated capabilities across employees through the company skill/knowledge centers.
