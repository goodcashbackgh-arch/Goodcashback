# Role Matrices — Machine-Readable Governing Pack Notice

Status: governing-pack control note.

## Problem this file fixes

The canonical role matrices currently exist in this folder as PDFs:

- `importer_role_stage_matrix_v7.pdf`
- `supervisor_role_stage_matrix_v7.pdf`
- `admin_role_stage_matrix_v6.pdf`
- `shipper_role_stage_matrix_v5.pdf`

These PDFs are suitable for human review, but they are not reliable as machine-readable build sources in GitHub tooling. When fetched through the repository connector, they can be returned as truncated base64 rather than searchable text.

That creates a build-risk contradiction: the project rule says governing-pack files must be checked first, but the role matrices are not reliably readable from the repo in their current PDF-only form.

## Required permanent fix

Add Markdown companions beside the PDFs:

```text
docs/governing-pack/role-matrices/importer_role_stage_matrix_v7.md
docs/governing-pack/role-matrices/supervisor_role_stage_matrix_v7.md
docs/governing-pack/role-matrices/admin_role_stage_matrix_v6.md
docs/governing-pack/role-matrices/shipper_role_stage_matrix_v5.md
```

The Markdown files should contain the full extracted text of the matching PDF, not a summary.

## Canonical usage rule after conversion

Once the Markdown companions are committed:

```text
.md = canonical machine-readable governing source for build decisions
.pdf = presentation/archive artifact
```

If there is a formatting-only difference between PDF and Markdown, use the Markdown for build work. If there is a content difference, stop and reconcile the source files before building.

## Interim rule before full conversion

Until the Markdown companions are committed, do not make role-boundary or actor-flow decisions from the PDF files alone unless the relevant matrix text has been uploaded directly into the working chat or otherwise made searchable/readable.

For invoice submission specifically, the uploaded importer matrix revision 7 confirmed:

- importer/operator submits supplier invoice evidence as a normal Day 3 action;
- tracking and invoice are independent child submissions and may arrive in either order;
- invoice upload writes to the `supplier_invoices` lane;
- invoice upload is allowed before staff funding recognition;
- once invoice exists, importer can enter the OCR/reconciliation workspace;
- importer remains blocked from DVA upload, funding reconciliation, credit application, refund approval, OCR source-line deletion, and shipper-side booking/evidence actions.

## Do not drift

Do not replace the matrices with summaries. The permanent fix is full Markdown extraction of all four role matrices.
