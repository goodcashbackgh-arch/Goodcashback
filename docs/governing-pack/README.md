# Governing Pack Files

This folder physically stores the current authority files used for UI/API wiring.

## Contents

- `architecture/` — governing architecture and implementation-alignment addenda, including `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md` and `VAT_RETURN_INTEGRITY_EVIDENCE_AND_ATOMIC_SAGE_POSTING_ADDENDUM_v1.md`.
- `backend/` — final locked backend pack v4 Day 2–9 v3 contents and later backend addenda.
- `accounting/` — governing accounting, settlement, funding and treasury addenda.
- `ui/` — UI wiring, role-flow and operational route contracts.
- `role-matrices/` — exact role matrix PDFs: importer v7, supervisor v7, admin v6, shipper v5.
- `SHA256SUMS.txt` — checksum proof for the original locked base files listed in that manifest. Later addenda are versioned and audited through Git history.

Rule: if a needed authority file is missing or ambiguous, stop and ask Ian before changing code. Do not guess.
