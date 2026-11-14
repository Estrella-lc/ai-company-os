# Quality review of revised deliveries

Migration 015 pins the exact user request message bound to each delivery job alongside the goal, acceptance conditions and immutable delivery body. This includes the CEO's clarification for that version. Existing review snapshots and reports are preserved. Automatic quality rework carries this fixed execution request forward instead of dropping earlier clarifications.

Only the delivery's own request message in its own conversation is eligible. Unrelated conversations are not provided. Task details expose the pinned request and message version under the quality report, without exposing private history.

The Worker requests a JSON schema response for quality inspections only, using the Interactions API text/application-json response format. It retains strict application checks for all three criteria, verdict consistency, lengths and verbatim evidence from the delivered body. Evidence copied from the request instead of the body remains invalid. Schema output is not proof that the semantic judgment is correct.

Validation failures remain needs_human with a specific reason (JSON, shape, criteria, evidence, verdict or oversize). No raw rejected model output is logged or stored, no extra model repair calls are introduced and nothing is accepted automatically. The old generic fallback cannot reveal why a past raw response failed; this change improves future diagnostics rather than rewriting that result.

The first live recheck exposed a semantic false pass: an overlong opening paragraph contained an inline note and later offered a shorter alternative. For explicit `正文恰好一句话` plus one `N字以内` limit (1–500), a deterministic guard now counts all body characters including inline annotations, excludes whitespace, and rejects excess sentence terminators. The body is the delivery after the generated employee header and before its knowledge-reference section; multiple body paragraphs remain included. This guard can reject a model pass but cannot promote an uncertain report. Broader workflow standards still require their own evidence and human review. Failures reuse the existing single automatic quality-rework allowance.
