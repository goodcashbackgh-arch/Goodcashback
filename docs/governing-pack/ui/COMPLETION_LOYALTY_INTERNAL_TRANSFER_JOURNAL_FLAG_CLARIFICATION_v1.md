# Completion Loyalty Internal-Transfer Journal Flag Clarification v1

Status: locked clarification to `COMPLETION_LOYALTY_SAGE_ACCOUNTING_POSTING_ADDENDUM_v1.md` and `COMPLETION_LOYALTY_ACCOUNTING_CONTROLS_PAGE_UX_ADDENDUM_v1.md`.

This clarification resolves the distinction between the Sage API endpoint and the platform live-posting safety flag.

---

## 1. Endpoint is not new

Completion-loyalty internal-transfer posting must reuse the existing Sage journal posting primitive:

```text
POST /journals
```

This is the same Sage endpoint class already used by controlled VAT adjustment journals and bank/GL journal posting.

Do not create a new Sage endpoint, route, or external posting method for the completion-loyalty internal-transfer lane.

---

## 2. Safety flag is separate from endpoint

The live-posting environment flag is a safety gate inside the platform. It is not the Sage endpoint.

For this MVP, do not create a new Vercel environment variable per posting category.

The completion-loyalty internal-transfer lane is a controlled bank/internal-transfer GL journal posted through `POST /journals`, so it must use the existing journal-style bank/GL gate:

```text
SAGE_LIVE_BANK_GL_POSTING_ENABLED=true
```

---

## 3. Cash-posting flag must not enable this lane

This lane must not become live merely because customer/vendor cash posting is enabled.

Do not use this as the live gate for internal-transfer Sage journals:

```text
SAGE_LIVE_CASH_POSTING_ENABLED
```

That flag controls cash/customer/vendor receipt/payment-style posting paths. It must not imply permission to post completion-loyalty internal-transfer Sage journals.

---

## 4. Required implementation rule

The adapter must:

```text
reuse Sage OAuth/business context;
reuse request/response logging;
read endpoint_path from the frozen step;
fail closed unless endpoint_path = /journals;
allow SAGE_LIVE_BANK_GL_POSTING_ENABLED as the MVP live gate;
reject cash-posting flag fallback.
```

Required operator wording:

```text
Internal-transfer Sage journal batch
Endpoint: /journals
Post Sage journal batch
```
