---
name: company-document-processing
description: Bounded PDF text extraction, DOCX text extraction and DOCX creation using mature open-source libraries.
---

Use the company's document executor for `pdf_extract_v1`, `docx_extract_v1`, and `docx_create_v1`.
The executor uses pinned PyPI pypdf (BSD-3-Clause) and python-docx (MIT), with a hash-locked dependency set.
It searches skills.sh and GitHub for context before validating the fixed company adapter. It never executes downloaded skill scripts.

Limits: 2 MB input/output, 30 PDF pages, 20,000 characters for DOCX creation. Extract top-level DOCX paragraphs and tables in order. Preserve text, not original layout.
Scanned/blank PDF pages require OCR and must be reported as unsupported. Encrypted PDFs, corrupt files, external DOCX relationships and macros are not accepted. No credentials are passed into the processing container.
Downloaded documentation is not proof of capability. Only a successful sandbox fixture and its recorded profiles enable reuse. Individual jobs also require output checks; CEO acceptance remains separate.
