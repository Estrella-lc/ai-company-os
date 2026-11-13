# Quality review of revised deliveries

Migration 015 pins the exact user request message bound to each delivery job alongside the goal, acceptance conditions and immutable delivery body. This includes the CEO's clarification for that version. Existing review snapshots and reports are preserved. Automatic quality rework carries this fixed execution request forward instead of dropping earlier clarifications.

Only the delivery's own request message in its own conversation is eligible. Unrelated conversations are not provided. Task details expose the pinned request and message version under the quality report, without exposing private history.

The Worker requests a JSON schema response for quality inspections only, using the Interactions API text/application-json response format. It retains strict application checks for all three criteria, verdict consistency, lengths and verbatim evidence from the delivered body. Evidence copied from the request instead of the body remains invalid. Schema output is not proof that the semantic judgment is correct.

Validation failures remain needs_human with a specific reason (JSON, shape, criteria, evidence, verdict or oversize). No raw rejected model output is logged or stored, no extra model repair calls are introduced and nothing is accepted automatically. The old generic fallback cannot reveal why a past raw response failed; this change improves future diagnostics rather than rewriting that result.
