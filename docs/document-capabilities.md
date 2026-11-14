# Document processing activation plan

Status: implementation prepared; production migration and private-document access are not activated until the user confirms the new file-processing access.

The company workflow searches skills.sh and GitHub, records pinned documents, and validates a first-party adapter that uses mature open-source packages. Downloaded skill scripts are never executed. The adapter itself is recorded with its repository commit, dependency lock SHA-256 and measured verification scope. Library versions are pypdf 7.1.0 (BSD-3-Clause) and python-docx 1.2.0 (MIT); all dependencies are version and wheel-hash locked. ReportLab is used only to produce synthetic PDF fixtures.

Supported profiles: PDF text-layer extraction to UTF-8 TXT; DOCX top-level paragraph/table extraction to TXT; supplied UTF-8 text to DOCX. Limits: 2 MB input/output, at most 30 PDF pages, at most 20,000 characters for DOCX creation. OCR, encryption, nested table reconstruction, source-layout fidelity and arbitrary document instructions are outside the verified scope. Generated DOCX is reopened to check text integrity. Text extraction checks cannot guarantee semantic truth or visual quality; CEO acceptance stays separate.

## Product flow

`/tasks?view=documents` remains inside the task center. It creates a private document job, uploads the source to a new private `company-documents` bucket, and queues the job. A missing company capability automatically creates a skill researcher/research task; terminal verification resumes waiting document jobs or reports failure. Validated capabilities are reusable across managers. The same skills catalog also lets ordinary text employees research and reuse document-processing instructions. An ordinary text reply does not execute a file by itself; file tasks use the dedicated bounded executor.

The existing main-branch OIDC verifier grants the current leased document job's input URL and a lease-specific result upload URL. The runtime container has no network, credentials, root write access or elevated capabilities. File bytes/previews are not sent to Gemini or written to GitHub Actions artifacts. Artifacts contain public-source research and synthetic fixture files only. Files remain private and are not automatically deleted in this first version; daily creation cap 5 and retained job cap 10 bound storage.

The existing runner checks once every two hours. Document execution, subtitle execution and skill research share three daily claims, with eight-minute workflow timeout and $0 extra paid budget. A first document may consume one research claim and one execution claim. Each document job can be claimed at most twice for lease recovery. Deterministic invalid/unsupported inputs fail without repeated parsing. Previous deferred technology research remains paused.

## Required activation

Migration `202611140017_document_capabilities.sql` adds the document job table, private bucket, owner/CEO RLS and scoped RPCs. It extends only the fixed company adapter's document verification status, preserves browser-role restrictions and adds document claims to the shared daily budget. Deploy `document-bridge.ts` plus the updated Worker entrypoint, merge the reviewed branch and deploy the existing free web service. Do not apply the declined autonomous-development migrations 006/007.

This introduces a new permission: the existing trusted GitHub executor may temporarily read documents the CEO deliberately uploads for these tasks and write their outputs to private storage. It must be confirmed at activation. No database keys are copied to GitHub, no external document service is added, and no paid service is created.

After activation, run one synthetic research/file task through the live UI, download and reopen the actual output, verify independent output checks and refresh persistence, test invalid-file failure and confirm no CEO acceptance is submitted automatically. Respect remaining daily claims; do not increase quotas to complete tests faster.

## Validation prepared before activation

Container fixtures cover English/Chinese PDF extraction, corrupt PDF rejection, blank/scanned-PDF refusal, encrypted-PDF refusal, Chinese DOCX round-trip, top-level table order, corrupt DOCX refusal, empty text and input-size limits. Isolation assertions cover network denial, unprivileged UID, read-only root and absence of application/GitHub secrets. Real file executor tests cover PDF/DOCX extraction, DOCX creation, uploaded-byte hashes, callback redaction and corrupt-input failure with a mocked storage transport.

SQL transaction tests cover automatic research, missing-upload rejection, failed verification, capability registration/resumption, cross-manager reuse, DOCX classification, lease ownership/idempotence, competing claim attempts, missing-output rejection, bounded recovery, shared quota, owner RLS and CEO review protection. All synthetic SQL changes roll back. Production-build checks include Node regressions, Deno, ESLint, TypeScript and Next.js build.
