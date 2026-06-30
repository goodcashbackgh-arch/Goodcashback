# Completion Loyalty Batch Page Workbench Parity Clarification v1

Status: locked clarification to `COMPLETION_LOYALTY_ACCOUNTING_CONTROLS_PAGE_UX_ADDENDUM_v1.md`.

This clarification supersedes any wording that makes the completion-loyalty batch detail page look like a new or separate Sage posting experience.

The completion-loyalty batch detail page must feel like the existing Accounting Command Centre posting batch detail workbench.

---

## 1. Primary UI rule

The page must use the same mental model as the existing Accounting Command Centre posting batch detail page:

```text
compact posting-batch header
action buttons in the header
status/lane/count pills
batch rows table
technical audit collapsed below
retire/supersede control available but not visually dominant
```

Do not create a new visual language for completion-loyalty posting.

---

## 2. Do not expose implementation detail as page identity

The staff-facing primary UI must not lead with technical implementation details such as:

```text
endpoint_path
/journals
specific Vercel environment variable names
Sage long ledger ids
source/destination statement-line ids
raw request payloads
raw Sage response payloads
```

Those belong in the collapsed technical audit area or governing documents, not in the normal posting workflow view.

---

## 3. Internal-transfer batch labels

Use familiar posting-workbench wording:

```text
Posting batch detail
Completion loyalty
internal transfer
Approve batch
Post internal transfer to Sage
Retire local batch
Live Sage posting enabled / disabled
```

Avoid making the page feel like a new Sage endpoint or new posting product:

```text
Internal-transfer Sage journal batch
Endpoint: /journals
Post Sage journal batch
SAGE_LIVE_BANK_GL_POSTING_ENABLED: true
```

Those are true implementation facts, but they are not the primary operator-facing workflow language.

---

## 4. Batch rows

Batch rows should show operational facts only:

```text
posting status
lane
source facts
Sage target / control
amount
validation
steps
reason / error
```

For internal transfers, the source/control summary should be human-readable, for example:

```text
Main GBP bank -> Virtual GBP wallet
Internal bank movement
No customer invoice allocation
```

Do not show raw endpoint or raw Sage ledger ids on the row surface.

---

## 5. Technical audit

Frozen request payloads, Sage responses, endpoint path, ledger ids, idempotency keys, and raw step metadata remain available only in a collapsed technical audit section.

This preserves traceability without forcing normal users to learn a new posting path.
